#!/usr/bin/env bash
# =============================================================================
#  Sentinel · recuperación y monitor
#
#  Dos cosas distintas que comparten los mismos chequeos:
#
#    wd_recover   una pasada: mira qué está caído, lo levanta y verifica.
#    wd_run       lo mismo pero pensado para correr solo cada pocos minutos.
#
#  REGLA: reiniciar sólo lo que está roto. Un "restart all" a ciegas corta el
#  video de quien esté mirando y borra la evidencia de qué había fallado.
# =============================================================================
[ -n "${SENTINEL_WATCHDOG_LOADED:-}" ] && return 0
SENTINEL_WATCHDOG_LOADED=1

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WD_LOG="${SENTINEL_WD_LOG:-$HOME/sentinel-watchdog.log}"
WD_SERVICE="${SENTINEL_WD_SERVICE:-/etc/systemd/system/sentinel-watchdog.service}"
WD_TIMER="${SENTINEL_WD_TIMER:-/etc/systemd/system/sentinel-watchdog.timer}"
WD_SUDO="${SENTINEL_SUDO-sudo}"

# printf '%-10s' cuenta bytes, no caracteres: con acentos la columna se corre.
wd_pad() {
  local t="$1" n="${2:-10}" out="$1"
  while [ "${#out}" -lt "$n" ]; do out="$out "; done
  printf '%s' "$out"
}

wd_log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$WD_LOG" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Chequeos. Cada uno imprime "<nombre>|<ok|fallo>|<detalle>"
# ---------------------------------------------------------------------------

wd_check_server() {
  local port url code
  port="$(app_port)"; url="http://localhost:$port/healthz"
  code="$(http_code "$url" 5)"
  if [ "$code" = "200" ]; then echo "servidor|ok|responde en el puerto $port"; return 0; fi
  if pm2 describe sentinel >/dev/null 2>&1; then
    echo "servidor|fallo|pm2 lo tiene cargado pero no responde (HTTP $code)"
  else
    echo "servidor|fallo|no está en pm2"
  fi
  return 1
}

wd_check_gpio() {
  # Sólo aplica si el equipo tiene Arduino configurado
  pm2 describe sentinel-gpio >/dev/null 2>&1 || { echo "arduino|ok|no configurado en este equipo"; return 0; }
  local st
  st="$(pm2 jlist 2>/dev/null | tr ',' '\n' | grep -A2 'sentinel-gpio' | grep -o '"status":"[a-z]*"' | head -1 | cut -d'"' -f4)"
  [ "$st" = "online" ] && { echo "arduino|ok|online"; return 0; }
  echo "arduino|fallo|pm2 lo reporta '${st:-desconocido}'"
  return 1
}

wd_check_tunnel() {
  [ -f /etc/cloudflared/config.yml ] || { echo "túnel|ok|no configurado en este equipo"; return 0; }
  systemctl is-active --quiet cloudflared 2>/dev/null \
    || { echo "túnel|fallo|cloudflared no está corriendo"; return 1; }
  local domain code
  domain="$($WD_SUDO grep -m1 'hostname:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $NF}')"
  [ -z "$domain" ] && { echo "túnel|ok|corriendo"; return 0; }
  code="$(http_code "https://$domain/healthz" 10)"
  case "$code" in
    200) echo "túnel|ok|$domain responde" ;;
    000|530|502|503) echo "túnel|fallo|$domain devuelve $code"; return 1 ;;
    *)   echo "túnel|ok|$domain responde ($code)" ;;
  esac
  return 0
}

# El stream es on-demand: sin espectadores está 'idle' y eso es correcto.
# Sólo es fallo si hay alguien mirando y no arranca, o si la fuente falla.
wd_check_stream() {
  local port j; port="$(app_port)"
  j="$(curl -sS -m5 "http://localhost:$port/healthz/streams" 2>/dev/null)"
  [ -z "$j" ] && { echo "video|fallo|el servidor no informa estado"; return 1; }
  local out
  out="$(echo "$j" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("fallo|respuesta ilegible"); raise SystemExit
malos = []
for s in d.get("streams", []):
    st, v = s.get("status"), s.get("viewers") or 0
    if st in ("error", "retrying"):
        malos.append("%s en estado %s" % (s.get("id"), st))
    elif v > 0 and st != "live":
        malos.append("%s: hay %d mirando y no arranca" % (s.get("id"), v))
print(("fallo|" + "; ".join(malos)) if malos else "ok|sin problemas")
' 2>/dev/null)"
  [ -z "$out" ] && { echo "video|ok|sin datos"; return 0; }
  echo "video|${out}"
  [ "${out%%|*}" = "fallo" ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Reparaciones
# ---------------------------------------------------------------------------

wd_fix_server() {
  pm2 restart sentinel --update-env >/dev/null 2>&1 || pm2 start "$APP_DIR/src/server.js" --name sentinel >/dev/null 2>&1
  local port i; port="$(app_port)"
  for i in $(seq 1 15); do
    [ "$(http_code "http://localhost:$port/healthz" 3)" = "200" ] && return 0
    sleep 1
  done
  return 1
}

wd_fix_gpio()   { pm2 restart sentinel-gpio >/dev/null 2>&1 && sleep 2; }
wd_fix_tunnel() { $WD_SUDO systemctl restart cloudflared >/dev/null 2>&1 && sleep 6; }
# El video depende del servidor: se repara con la MISMA funcion, asi la
# deduplicacion la reconoce y no lo reinicia dos veces en la misma pasada.

# ---------------------------------------------------------------------------
# wd_recover [--auto|--yes]
# ---------------------------------------------------------------------------
wd_recover() {
  local auto=0
  case "${1:-}" in --auto|--yes|-y) auto=1 ;; esac

  banner "RECUPERAR SENTINEL"
  local checks=(wd_check_server wd_check_gpio wd_check_tunnel wd_check_stream)
  local fixes=(wd_fix_server wd_fix_gpio wd_fix_tunnel wd_fix_server)
  local roto=() roto_fix=() i res nombre estado detalle

  step "Revisando"
  for i in "${!checks[@]}"; do
    res="$(${checks[$i]})"
    nombre="${res%%|*}"; res="${res#*|}"
    estado="${res%%|*}"; detalle="${res#*|}"
    if [ "$estado" = "ok" ]; then
      ok "$(wd_pad "$nombre") $detalle"
    else
      err "$(wd_pad "$nombre") $detalle"
      roto+=("$nombre"); roto_fix+=("${fixes[$i]}")
    fi
  done

  if [ "${#roto[@]}" -eq 0 ]; then
    echo ""; hr
    echo -e "  ${G}${BOLD}Todo en orden. No hay nada que reiniciar.${N}"
    hr; echo ""
    return 0
  fi

  echo ""
  warn "Hay que reiniciar: ${roto[*]}"
  if [ "$auto" -eq 0 ]; then
    echo ""
    printf "  ¿Reinicio? [S/n]: "
    local r; read -r r </dev/tty || r="s"
    case "$(echo "${r:-s}" | tr '[:upper:]' '[:lower:]')" in
      n|no) info "No se tocó nada."; return 1 ;;
    esac
  fi

  step "Reiniciando"
  local aplicados=""
  for i in "${!roto[@]}"; do
    # Si ya reiniciamos el servidor, no repetirlo por el video
    case " $aplicados " in *" ${roto_fix[$i]} "*) continue ;; esac
    aplicados="$aplicados ${roto_fix[$i]}"
    info "${roto[$i]}..."
    if ${roto_fix[$i]}; then ok "${roto[$i]} reiniciado"; else err "${roto[$i]} no levantó"; fi
  done

  step "Verificando"
  local quedan=0
  for i in "${!checks[@]}"; do
    res="$(${checks[$i]})"
    nombre="${res%%|*}"; res="${res#*|}"
    estado="${res%%|*}"; detalle="${res#*|}"
    if [ "$estado" = "ok" ]; then ok "$(wd_pad "$nombre") $detalle"
    else err "$(wd_pad "$nombre") $detalle"; quedan=$((quedan+1)); fi
  done

  echo ""; hr
  if [ "$quedan" -eq 0 ]; then
    echo -e "  ${G}${BOLD}Recuperado.${N}"
    wd_log "RECUPERADO tras reiniciar: ${roto[*]}"
  else
    echo -e "  ${R}${BOLD}Quedan $quedan problema(s).${N}"
    echo -e "\n  ${B}sentinel diagnose${N}   para ver el detalle"
    echo -e "  ${B}sentinel logs server 40${N}"
    wd_log "SIN RESOLVER tras reiniciar: ${roto[*]} ($quedan pendientes)"
  fi
  hr; echo ""
  [ "$quedan" -eq 0 ]
}

# ---------------------------------------------------------------------------
# wd_run — pensado para el timer: silencioso salvo que haya algo que decir
# ---------------------------------------------------------------------------
wd_run() {
  local checks=(wd_check_server wd_check_gpio wd_check_tunnel wd_check_stream)
  local fixes=(wd_fix_server wd_fix_gpio wd_fix_tunnel wd_fix_server)
  local i res nombre estado detalle roto=() aplicados=""

  for i in "${!checks[@]}"; do
    res="$(${checks[$i]})"
    nombre="${res%%|*}"; res="${res#*|}"
    estado="${res%%|*}"; detalle="${res#*|}"
    [ "$estado" = "ok" ] && continue
    roto+=("$nombre")
    wd_log "CAIDO  $nombre: $detalle"
    case " $aplicados " in *" ${fixes[$i]} "*) continue ;; esac
    aplicados="$aplicados ${fixes[$i]}"
    if ${fixes[$i]}; then wd_log "REINICIADO  $nombre"; else wd_log "FALLO al reiniciar $nombre"; fi
  done

  [ "${#roto[@]}" -eq 0 ] && return 0

  local quedan=0
  for i in "${!checks[@]}"; do
    res="$(${checks[$i]})"; res="${res#*|}"
    [ "${res%%|*}" != "ok" ] && quedan=$((quedan+1))
  done
  if [ "$quedan" -eq 0 ]; then wd_log "OK  todo recuperado"
  else wd_log "ALERTA  quedan $quedan problema(s) sin resolver"; fi
  return 0
}

# ---------------------------------------------------------------------------
# Instalación del timer
# ---------------------------------------------------------------------------
wd_install() {
  local mins="${1:-5}"
  echo "$mins" | grep -qE '^[0-9]+$' || { err "Intervalo inválido: $mins"; return 1; }
  [ "$mins" -lt 1 ] && { err "El intervalo mínimo es 1 minuto"; return 1; }

  banner "MONITOR AUTOMÁTICO"
  echo -e "  Revisa cada ${BOLD}${mins} minuto(s)${N} y reinicia sólo lo que esté caído."
  echo -e "  Registro: ${BOLD}$WD_LOG${N}"
  echo ""

  $WD_SUDO tee "$WD_SERVICE" >/dev/null <<EOF
[Unit]
Description=Sentinel · monitor de servicios
After=network-online.target

[Service]
Type=oneshot
User=$(id -un)
Environment=HOME=$HOME
Environment=PATH=$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$APP_DIR/sentinel watchdog run
EOF

  $WD_SUDO tee "$WD_TIMER" >/dev/null <<EOF
[Unit]
Description=Sentinel · monitor cada ${mins} minuto(s)

[Timer]
OnBootSec=2min
OnUnitActiveSec=${mins}min
AccuracySec=30s
Unit=sentinel-watchdog.service

[Install]
WantedBy=timers.target
EOF

  $WD_SUDO systemctl daemon-reload >/dev/null 2>&1
  $WD_SUDO systemctl enable --now sentinel-watchdog.timer >/dev/null 2>&1 \
    && ok "Monitor activado" || { err "No se pudo activar el timer"; return 1; }
  echo ""
  info "Ver estado : sentinel watchdog status"
  info "Ver log    : sentinel watchdog log"
  info "Desactivar : sentinel watchdog off"
  echo ""
}

wd_uninstall() {
  banner "DESACTIVAR EL MONITOR"
  $WD_SUDO systemctl disable --now sentinel-watchdog.timer >/dev/null 2>&1 || true
  $WD_SUDO rm -f "$WD_TIMER" "$WD_SERVICE" 2>/dev/null || true
  $WD_SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Monitor desactivado"
  info "El registro queda en $WD_LOG"
  echo ""
}

wd_status() {
  banner "MONITOR AUTOMÁTICO"
  if [ ! -f "$WD_TIMER" ]; then
    warn "No está instalado"
    info "Activarlo:  sentinel watchdog on [minutos]"
    echo ""; return 0
  fi
  if systemctl is-active --quiet sentinel-watchdog.timer 2>/dev/null; then
    ok "Activo"
  else
    err "Instalado pero detenido"
    info "sudo systemctl start sentinel-watchdog.timer"
  fi
  systemctl list-timers sentinel-watchdog.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/    /'
  echo ""
  if [ -s "$WD_LOG" ]; then
    info "Últimas intervenciones:"
    tail -8 "$WD_LOG" | sed 's/^/    /'
  else
    info "Todavía no tuvo que intervenir."
  fi
  echo ""
}
