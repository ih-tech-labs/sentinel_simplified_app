#!/usr/bin/env bash
# =============================================================================
#  Sentinel · preflight, snapshot y restauración
#
#  Tres piezas que hacen que una migración remota sea reversible:
#
#    preflight  — verifica TODO sin tocar nada. Si algo falta, te enterás
#                 antes de haber movido un solo archivo.
#    snapshot   — fotografía el estado exacto de antes: qué corría en pm2,
#                 qué autostart había, a qué apuntaba el túnel.
#    restore    — devuelve el equipo a esa foto, sin depender de suposiciones.
#
#  La regla que atraviesa todo esto: EL TÚNEL NO SE TOCA. Es lo único que no
#  se puede reconstruir desde el equipo — si se rompe, el sitio se queda sin
#  alarmas de Verkada y no hay forma de arreglarlo sin volver a Cloudflare.
# =============================================================================
[ -n "${SENTINEL_DEPLOY_LOADED:-}" ] && return 0
SENTINEL_DEPLOY_LOADED=1

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=tunnel.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tunnel.sh"

SNAPSHOT_DIR="$APP_DIR/.snapshot"

# Rutas parametrizables para poder probar la restauración del túnel sin root.
# En producción valen lo de siempre; los tests las apuntan a un directorio
# temporal. Sin esto, la parte más crítica del rollback sería la única que
# nunca se ejecuta antes de llegar a un equipo de cliente.
CF_DIR="${SENTINEL_CF_DIR:-/etc/cloudflared}"
CF_SUDO="${SENTINEL_SUDO-sudo}"

# ---------------------------------------------------------------------------
# Lee el dominio del túnel activo sin modificar nada
# ---------------------------------------------------------------------------
current_tunnel_domain() {
  [ -f "$CF_DIR/config.yml" ] || return 1
  $CF_SUDO grep -m1 'hostname:' "$CF_DIR/config.yml" 2>/dev/null | awk '{print $NF}'
}
current_tunnel_uuid() {
  [ -f "$CF_DIR/config.yml" ] || return 1
  $CF_SUDO grep -m1 '^tunnel:' "$CF_DIR/config.yml" 2>/dev/null | awk '{print $2}'
}
current_tunnel_port() {
  [ -f "$CF_DIR/config.yml" ] || return 1
  $CF_SUDO grep -m1 'service: http' "$CF_DIR/config.yml" 2>/dev/null | grep -oE '[0-9]+$'
}

# ---------------------------------------------------------------------------
# PREFLIGHT · ¿está todo listo? No modifica nada.
# ---------------------------------------------------------------------------
# deploy_preflight <old_dir>   -> 0 si se puede migrar
deploy_preflight() {
  local old_dir="${1:-}"
  local problems=0 warnings=0

  banner "PREFLIGHT · ¿se puede migrar?"
  echo -e "  ${D}Este chequeo NO modifica nada. Sólo mira y reporta.${N}"

  # --- Requisitos -----------------------------------------------------------
  step "Requisitos del sistema"
  local major
  if command -v node >/dev/null 2>&1; then
    major="$(node -v | sed 's/v\([0-9]*\).*/\1/')"
    [ "$major" -ge 18 ] && ok "Node.js $(node -v)" \
      || { err "Node.js $(node -v) — se necesita 18+"; problems=$((problems+1)); }
  else
    err "Node.js no está instalado"; problems=$((problems+1))
  fi
  command -v ffmpeg >/dev/null 2>&1 && ok "ffmpeg" || { err "ffmpeg falta"; problems=$((problems+1)); }
  has_pm2 && ok "pm2 $(pm2 -v 2>/dev/null)" || { err "pm2 falta"; problems=$((problems+1)); }
  command -v git >/dev/null 2>&1 && ok "git" || warn "git no está (no es imprescindible)"
  python3 -c "import serial" 2>/dev/null && ok "pyserial" \
    || { warn "pyserial falta: sin control de luces"; warnings=$((warnings+1)); }

  # --- Espacio y recursos ---------------------------------------------------
  step "Recursos"
  local free_mb; free_mb="$(df -Pm "$APP_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ "${free_mb:-0}" -lt 500 ]; then
    err "Sólo ${free_mb}MB libres — el backup y npm install necesitan más"
    problems=$((problems+1))
  else
    ok "${free_mb}MB libres en disco"
  fi
  local temp; temp="$(awk '{printf "%.0f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
  [ -n "$temp" ] && { [ "$temp" -lt 75 ] && ok "Temperatura ${temp}°C" \
    || { warn "Temperatura ${temp}°C — alta"; warnings=$((warnings+1)); }; }

  # --- Conectividad ---------------------------------------------------------
  step "Conectividad"
  # Lo que importa es llegar a npm por HTTPS, no que responda el ping: muchas
  # redes de cliente bloquean ICMP y el ping fallaría dando un falso bloqueo.
  if curl -sS -m 10 -o /dev/null https://registry.npmjs.org/ 2>/dev/null; then
    ok "registry.npmjs.org alcanzable"
  else
    err "No se llega a npm — npm install va a fallar"
    ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 \
      && info "Hay red, pero HTTPS a npm está bloqueado (¿proxy o firewall?)" \
      || info "Este equipo no tiene salida a internet"
    problems=$((problems+1))
  fi
  curl -sS -m 10 -o /dev/null https://api.cloudflare.com/ 2>/dev/null \
    && ok "Cloudflare alcanzable" \
    || { warn "No se llega a Cloudflare: el túnel podría no reconectar"; warnings=$((warnings+1)); }

  # --- Versión nueva --------------------------------------------------------
  step "Versión nueva"
  ok "Carpeta: $APP_DIR"
  local f miss=0
  for f in src/server.js sentinel lib/common.sh public/backoffice/index.html package.json; do
    [ -e "$APP_DIR/$f" ] || { err "Falta $f"; miss=1; }
  done
  [ "$miss" -eq 0 ] && ok "Archivos completos" || problems=$((problems+1))

  for f in "$APP_DIR"/src/*.js; do
    node --check "$f" 2>/dev/null || { err "Sintaxis: $(basename "$f")"; problems=$((problems+1)); }
  done
  for f in "$APP_DIR"/*.sh "$APP_DIR"/sentinel "$APP_DIR"/lib/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null || { err "Sintaxis: $(basename "$f")"; problems=$((problems+1)); }
  done
  ok "Código verificado"

  if [ -f "$APP_DIR/public/assets/background.mp4" ]; then
    local mb; mb="$(du -m "$APP_DIR/public/assets/background.mp4" | cut -f1)"
    [ "$mb" -le 20 ] && ok "Video de fondo optimizado (${mb}MB)" \
      || { warn "background.mp4 pesa ${mb}MB"; warnings=$((warnings+1)); }
  fi

  # --- Versión anterior -----------------------------------------------------
  step "Versión anterior"
  if [ -n "$old_dir" ] && [ -f "$old_dir/src/server.js" ]; then
    ok "Encontrada en $old_dir"
    [ -f "$old_dir/.env" ] && ok "Tiene .env (se hereda el secret de Verkada)" \
                           || warn "Sin .env: vas a tener que cargar el secret a mano"
  else
    err "No se encontró la instalación anterior"
    info "Indicala con: ./deploy.sh --old-dir <ruta>"
    problems=$((problems+1))
  fi

  local st; st="$(pm2_status sentinel-server)"
  case "$st" in
    online)    ok "Servicio actual 'sentinel-server' corriendo" ;;
    no-existe) warn "No hay 'sentinel-server' en pm2"; warnings=$((warnings+1)) ;;
    *)         warn "'sentinel-server' en estado '$st'"; warnings=$((warnings+1)) ;;
  esac

  # --- Puerto ---------------------------------------------------------------
  step "Puerto"
  local port; port="$(app_port)"
  local tport; tport="$(current_tunnel_port 2>/dev/null)"
  ok "La versión nueva va a usar el puerto $port"
  if [ -n "$tport" ]; then
    [ "$tport" = "$port" ] && ok "El túnel ya apunta al $tport — coincide" \
      || { err "El túnel apunta al $tport y la nueva usa el $port"
           info "Igualalos en .env (PORT=$tport) antes de migrar."
           problems=$((problems+1)); }
  fi

  # --- Túnel: sólo se mira -------------------------------------------------
  step "Túnel de Cloudflare"
  local domain uuid
  domain="$(current_tunnel_domain 2>/dev/null)"
  uuid="$(current_tunnel_uuid 2>/dev/null)"
  if [ -z "$domain" ]; then
    warn "No hay túnel configurado en este equipo"; warnings=$((warnings+1))
  else
    ok "Dominio : $domain"
    ok "Túnel   : $uuid"
    systemctl is-active --quiet cloudflared 2>/dev/null && ok "cloudflared corriendo" \
      || { err "cloudflared no está corriendo"; problems=$((problems+1)); }

    # Acá se mide si el TÚNEL llega al origen, no qué versión corre del otro
    # lado. Un 404 significa que Express contestó: la versión anterior no
    # tiene /healthz, esa ruta se agregó en la nueva. Marcarlo como problema
    # sería un falso positivo justo en el chequeo previo a migrar.
    local code; code="$(http_code "https://$domain/healthz" 12)"
    case "$code" in
      200) ok "Responde desde internet (HTTP 200)" ;;
      000) err "No responde desde internet: el túnel no está llegando"
           problems=$((problems+1)) ;;
      530|502|503)
           err "HTTP $code — Cloudflare no alcanza el origen"
           problems=$((problems+1)) ;;
      *)   ok "El túnel llega al origen (HTTP $code)"
           info "La versión anterior no tiene /healthz; después de migrar da 200." ;;
    esac
  fi

  # --- Qué se toca y qué no -------------------------------------------------
  step "Qué va a pasar"
  hr
  echo -e "  ${G}${BOLD}NO se toca:${N}"
  echo -e "    · El túnel de Cloudflare  ${D}($([ -n "$domain" ] && echo "$domain" || echo "ninguno"))${N}"
  echo -e "    · El registro DNS"
  echo -e "    · La URL del webhook en Verkada"
  echo -e "    · La carpeta de la versión anterior  ${D}($old_dir)${N}"
  echo ""
  echo -e "  ${Y}${BOLD}Sí cambia:${N}"
  echo -e "    · El servicio pm2 pasa de 'sentinel-server' a 'sentinel'"
  echo -e "    · El autostart del kiosko apunta a la carpeta nueva"
  echo -e "    · El puerto $port lo sirve la versión nueva"
  echo ""
  echo -e "  ${B}${BOLD}Reversible con:${N}  ./deploy.sh --rollback"
  hr

  # --- Veredicto ------------------------------------------------------------
  echo ""
  hr
  if [ "$problems" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    echo -e "  ${G}${BOLD}TODO LISTO. Se puede migrar.${N}"
    echo -e "\n    ${B}./deploy.sh${N}"
  elif [ "$problems" -eq 0 ]; then
    echo -e "  ${G}${BOLD}SE PUEDE MIGRAR${N} ${Y}· $warnings advertencia(s)${N}"
    echo -e "  ${D}Las advertencias no bloquean, pero convenía saberlas.${N}"
    echo -e "\n    ${B}./deploy.sh${N}"
  else
    echo -e "  ${R}${BOLD}NO MIGRAR TODAVÍA · $problems problema(s)${N}"
    echo -e "  ${D}Resolvelos y volvé a correr ./deploy.sh --check${N}"
  fi
  hr
  echo ""
  return "$problems"
}

# ---------------------------------------------------------------------------
# SNAPSHOT · fotografía del estado antes de tocar nada
# ---------------------------------------------------------------------------
deploy_snapshot() {
  local old_dir="${1:-}"
  rm -rf "$SNAPSHOT_DIR"
  mkdir -p "$SNAPSHOT_DIR"

  {
    echo "STAMP=$(date +%Y%m%d-%H%M%S)"
    echo "OLD_DIR=$old_dir"
    echo "PORT=$(app_port)"
    echo "TUNNEL_DOMAIN=$(current_tunnel_domain 2>/dev/null)"
    echo "TUNNEL_UUID=$(current_tunnel_uuid 2>/dev/null)"
    echo "PM2_OLD=$(pm2_status sentinel-server)"
    echo "PM2_NEW=$(pm2_status sentinel)"
  } > "$SNAPSHOT_DIR/state"

  # Lista de procesos de pm2 tal como estaba
  pm2 jlist > "$SNAPSHOT_DIR/pm2.json" 2>/dev/null || true
  [ -f "$HOME/.pm2/dump.pm2" ] && cp "$HOME/.pm2/dump.pm2" "$SNAPSHOT_DIR/dump.pm2" 2>/dev/null || true

  # Autostart del kiosko
  mkdir -p "$SNAPSHOT_DIR/autostart"
  cp "$HOME/.config/autostart"/sentinel*.desktop "$SNAPSHOT_DIR/autostart/" 2>/dev/null || true

  # Túnel COMPLETO: config.yml, credenciales y cert. Con esto se puede
  # devolver el equipo a su túnel original aunque en el medio se haya
  # configurado otro distinto.
  if [ -d "$CF_DIR" ]; then
    $CF_SUDO tar -czf "$SNAPSHOT_DIR/cloudflared.tar.gz" \
      -C "$(dirname "$CF_DIR")" "$(basename "$CF_DIR")" 2>/dev/null \
      && $CF_SUDO chown "$(id -u):$(id -g)" "$SNAPSHOT_DIR/cloudflared.tar.gz" 2>/dev/null
    local tname; tname="$(tunnel_name_of "$(current_tunnel_uuid 2>/dev/null)" 2>/dev/null || true)"
    echo "TUNNEL_NAME=$tname" >> "$SNAPSHOT_DIR/state"
    ok "Túnel fotografiado ${D}($tname → $(current_tunnel_domain 2>/dev/null))${N}"
  else
    echo "TUNNEL_NAME=" >> "$SNAPSHOT_DIR/state"
  fi

  chmod -R 700 "$SNAPSHOT_DIR" 2>/dev/null || true
  ok "Estado anterior fotografiado en .snapshot/"
}

# ---------------------------------------------------------------------------
# RESTORE · volver exactamente a la foto
# ---------------------------------------------------------------------------
deploy_restore() {
  local reason="${1:-pedido manual}"

  echo -e "${Y}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║   ROLLBACK · volviendo al estado anterior                ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${N}"
  warn "Motivo: $reason"
  echo ""

  local OLD_DIR="" PORT=3000 TUNNEL_DOMAIN=""
  if [ -f "$SNAPSHOT_DIR/state" ]; then
    # shellcheck disable=SC1090
    . "$SNAPSHOT_DIR/state"
    ok "Snapshot encontrado ($STAMP)"
  else
    warn "Sin snapshot: se restaura con los valores por defecto"
  fi

  step "1/5 · Apagando la versión nueva"
  pm2 stop sentinel        >/dev/null 2>&1 && ok "sentinel detenido" || true
  pm2 delete sentinel      >/dev/null 2>&1 || true
  pm2 delete sentinel-gpio >/dev/null 2>&1 || true
  pkill -f "$APP_DIR/src/server.js" 2>/dev/null || true
  pkill -f "gpio_daemon.py" 2>/dev/null || true
  pkill -f "mpeg1video" 2>/dev/null || true
  sleep 2
  local pids; pids="$(sudo lsof -ti :"${PORT:-3000}" 2>/dev/null || true)"
  [ -n "$pids" ] && { echo "$pids" | xargs -r sudo kill -TERM 2>/dev/null; sleep 1; }

  step "2/5 · Restaurando el autostart"
  rm -f "$HOME/.config/autostart"/sentinel-kiosk.desktop 2>/dev/null || true
  if [ -d "$SNAPSHOT_DIR/autostart" ] && ls "$SNAPSHOT_DIR/autostart"/*.desktop >/dev/null 2>&1; then
    mkdir -p "$HOME/.config/autostart"
    cp "$SNAPSHOT_DIR/autostart"/*.desktop "$HOME/.config/autostart/" 2>/dev/null
    ok "Autostart anterior restaurado"
  else
    info "No había autostart previo que restaurar"
  fi

  step "3/5 · Levantando la versión anterior"
  if pm2_exists sentinel-server; then
    pm2 restart sentinel-server >/dev/null 2>&1 && ok "sentinel-server reiniciado"
  elif [ -n "${OLD_DIR:-}" ] && [ -f "$OLD_DIR/src/server.js" ]; then
    pm2 start "$OLD_DIR/src/server.js" --name sentinel-server --cwd "$OLD_DIR" >/dev/null 2>&1 \
      && ok "sentinel-server iniciado desde $OLD_DIR"
  else
    err "No encuentro la instalación anterior${OLD_DIR:+ en $OLD_DIR}"
  fi
  pm2 save >/dev/null 2>&1 || true

  step "4/5 · Restaurando el túnel"
  deploy_restore_tunnel

  step "5/5 · Verificando"

  if wait_for_http "http://localhost:${PORT:-3000}/" 25; then
    ok "La versión anterior responde"
    [ -n "${TUNNEL_DOMAIN:-}" ] && {
      local code; code="$(http_code "https://$TUNNEL_DOMAIN/" 12)"
      [ "$code" != "000" ] && ok "$TUNNEL_DOMAIN responde (HTTP $code)" \
                           || warn "$TUNNEL_DOMAIN no responde"
    }
    echo ""
    echo -e "  ${G}${BOLD}Rollback completo. El equipo volvió a como estaba.${N}"
    echo -e "  ${D}Los kioskos se reconectan solos en unos segundos.${N}"
  else
    err "La versión anterior no respondió"
    echo ""
    echo -e "  ${R}Revisá a mano:${N}"
    echo -e "    pm2 logs sentinel-server"
    [ -n "${OLD_DIR:-}" ] && echo -e "    cd $OLD_DIR && node src/server.js"
  fi
  echo ""
}


# ---------------------------------------------------------------------------
# deploy_restore_tunnel · devolver el túnel exactamente a como estaba
#
# Si entre el snapshot y ahora se configuró OTRO túnel, hay dos cosas que
# arreglar y las dos importan:
#
#   1. /etc/cloudflared apunta al túnel nuevo  → se restaura del snapshot
#   2. El DNS puede haber quedado tomado por el túnel nuevo, si se reusó el
#      mismo hostname → se vuelve a apuntar al viejo
#
# Sin el punto 2, el túnel original quedaría corriendo pero sin nadie que le
# mande tráfico: el sitio seguiría sin webhook y el rollback sería una
# ilusión.
# ---------------------------------------------------------------------------
deploy_restore_tunnel() {
  local snap="$SNAPSHOT_DIR/cloudflared.tar.gz"

  if [ ! -f "$snap" ]; then
    info "No hay túnel en el snapshot: no había ninguno configurado antes"
    return 0
  fi

  # shellcheck disable=SC1090
  [ -f "$SNAPSHOT_DIR/state" ] && . "$SNAPSHOT_DIR/state"

  local cur_uuid; cur_uuid="$(current_tunnel_uuid 2>/dev/null || true)"
  if [ "$cur_uuid" = "${TUNNEL_UUID:-}" ]; then
    ok "El túnel ya es el original ${D}(${TUNNEL_NAME:-?})${N}"
  else
    warn "El túnel actual ($cur_uuid) no es el original (${TUNNEL_UUID:-?})"
    $CF_SUDO systemctl stop cloudflared >/dev/null 2>&1 || true

    # Guardamos lo que hay ahora, por si hiciera falta volver a mirarlo
    [ -d "$CF_DIR" ] && $CF_SUDO mv "$CF_DIR" "${CF_DIR}.reemplazado-$(date +%Y%m%d-%H%M%S)" 2>/dev/null

    if $CF_SUDO tar -xzf "$snap" -C "$(dirname "$CF_DIR")" 2>/dev/null; then
      ok "$CF_DIR restaurado del snapshot"
    else
      err "No se pudo restaurar $CF_DIR"
      return 1
    fi

    $CF_SUDO cloudflared service uninstall >/dev/null 2>&1 || true
    $CF_SUDO cloudflared service install   >/dev/null 2>&1 || true
    $CF_SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    $CF_SUDO systemctl enable cloudflared  >/dev/null 2>&1 || true
    $CF_SUDO systemctl restart cloudflared >/dev/null 2>&1 || true
    sleep 5
  fi

  if [ -n "$CF_SUDO" ]; then
    systemctl is-active --quiet cloudflared 2>/dev/null && ok "cloudflared corriendo" \
      || { err "cloudflared no arrancó"; info "sudo journalctl -u cloudflared -n 30"; }
  fi

  # El DNS: ¿sigue apuntando al túnel original?
  if [ -n "${TUNNEL_DOMAIN:-}" ] && [ -n "${TUNNEL_UUID:-}" ]; then
    local dns_uuid; dns_uuid="$(tunnel_dns_uuid "$TUNNEL_DOMAIN" 2>/dev/null || true)"
    if [ -z "$dns_uuid" ]; then
      info "No pude verificar el DNS (falta dig/host)"
    elif [ "$dns_uuid" = "$TUNNEL_UUID" ]; then
      ok "$TUNNEL_DOMAIN sigue apuntando al túnel original"
    else
      warn "$TUNNEL_DOMAIN quedó apuntando a otro túnel ($dns_uuid)"

      # Si el snapshot no llegó a guardar el nombre —porque en ese momento no
      # se pudo consultar la cuenta— lo resolvemos ahora a partir del UUID.
      # Sin nombre no hay forma de re-apuntar el DNS, y el rollback quedaría
      # a medias: el túnel viejo corriendo pero sin tráfico.
      local tname="${TUNNEL_NAME:-}"
      [ -z "$tname" ] && tname="$(tunnel_name_of "$TUNNEL_UUID" 2>/dev/null || true)"

      if [ -n "$tname" ]; then
        info "Devolviéndolo a '$tname'..."
        cloudflared tunnel route dns -f "$tname" "$TUNNEL_DOMAIN" >/dev/null 2>&1 \
          && ok "DNS devuelto al túnel original" \
          || { err "No se pudo re-apuntar el DNS"
               info "Hacelo a mano: cloudflared tunnel route dns -f $tname $TUNNEL_DOMAIN"; }
      else
        err "No pude resolver el nombre del túnel original ($TUNNEL_UUID)"
        info "Re-apuntá el DNS a mano en Cloudflare → DNS → Records:"
        info "  CNAME $(echo "$TUNNEL_DOMAIN" | cut -d. -f1) → $TUNNEL_UUID.cfargotunnel.com"
      fi
    fi
  fi
  return 0
}
