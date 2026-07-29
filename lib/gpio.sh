#!/usr/bin/env bash
# =============================================================================
#  Sentinel · control de luces (Arduino)
#
#  Cadena completa:  backoffice → API → daemon Python → puerto serie → Arduino
# =============================================================================
[ -n "${SENTINEL_GPIO_LOADED:-}" ] && return 0
SENTINEL_GPIO_LOADED=1

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

gpio_port() { env_get GPIO_PORT 8765; }

gpio_send() {
  local frame="$1" port; port="$(gpio_port)"
  command -v nc >/dev/null 2>&1 || { echo "sin-nc"; return 1; }
  echo "$frame" | timeout 5 nc -q2 127.0.0.1 "$port" 2>/dev/null || true
}

gpio_diagnose() {
  local do_fix="${1:-0}" problems=0 device="" daemon_answers=0
  local fixes=()

  banner "DIAGNÓSTICO · control de luces"

  step "1 · Configuración"
  local enabled; enabled="$(env_get GPIO_ENABLED true)"
  if [ "${enabled,,}" = "true" ] || [ "$enabled" = "1" ]; then
    ok "GPIO_ENABLED=true"
  else
    err "GPIO_ENABLED=$enabled — apagado en .env"
    problems=$((problems+1))
    fixes+=("sed -i 's/^GPIO_ENABLED=.*/GPIO_ENABLED=true/' $ENV_FILE && pm2 restart sentinel")
  fi
  info "Puerto del daemon: $(gpio_port)"

  step "2 · pyserial"
  if python3 -c "import serial" 2>/dev/null; then
    ok "pyserial $(python3 -c 'import serial; print(serial.__version__)' 2>/dev/null)"
  else
    err "pyserial NO está instalado"
    problems=$((problems+1))
    fixes+=("sudo apt install -y python3-serial")
  fi

  step "3 · Puerto serie"
  local devices; devices="$(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || true)"
  if [ -n "$devices" ]; then
    local d
    for d in $devices; do
      ok "$d $(ls -l "$d" | awk '{print "("$3":"$4" "$1")"}')"
      [ -z "$device" ] && device="$d"
    done
  else
    err "No hay ningún /dev/ttyACM* ni /dev/ttyUSB*"
    problems=$((problems+1))
    info "Revisá el cable USB (que sea de datos, no sólo de carga) y que el"
    info "Arduino tenga el LED de alimentación encendido."
    lsusb 2>/dev/null | sed 's/^/      /' || true
  fi

  step "4 · Permisos"
  if groups | grep -qw dialout; then
    ok "$(whoami) está en el grupo dialout"
  else
    err "$(whoami) NO está en el grupo dialout"
    problems=$((problems+1))
    fixes+=("sudo usermod -aG dialout $(whoami)   # y reiniciar")
  fi

  # Lo que más veces rompe esto: pm2 hereda los grupos de la sesión que lo
  # arrancó. Si pm2 ya estaba levantado antes del usermod, el daemon no tiene
  # dialout aunque tu shell actual sí lo tenga, y un `pm2 restart` no alcanza.
  if pm2_exists sentinel-gpio; then
    local pid gid pgroups
    pid="$(pm2 jlist 2>/dev/null | node -e '
      let d=""; process.stdin.on("data",c=>d+=c).on("end",()=>{
        try { const p=JSON.parse(d).find(x=>x.name==="sentinel-gpio"); process.stdout.write(String(p&&p.pid||"")); }
        catch(e){ process.stdout.write(""); }});' 2>/dev/null)"
    if [ -n "$pid" ] && [ -r "/proc/$pid/status" ]; then
      pgroups="$(grep '^Groups:' "/proc/$pid/status" 2>/dev/null | cut -f2-)"
      gid="$(getent group dialout | cut -d: -f3)"
      if echo " $pgroups " | grep -q " $gid "; then
        ok "El daemon tiene el grupo dialout"
      else
        err "El daemon corre SIN el grupo dialout"
        info "pm2 quedó levantado desde antes de agregar el usuario al grupo."
        problems=$((problems+1))
        fixes+=("pm2 kill && pm2 resurrect   # o: sudo reboot")
      fi
    fi
  fi

  step "5 · Daemon"
  local st; st="$(pm2_status sentinel-gpio)"
  case "$st" in
    online)    ok "sentinel-gpio online" ;;
    no-existe) err "El servicio sentinel-gpio no existe en pm2"
               problems=$((problems+1))
               fixes+=("pm2 start $APP_DIR/scripts/gpio_daemon.py --name sentinel-gpio --interpreter python3 && pm2 save") ;;
    sin-pm2)   warn "pm2 no disponible" ;;
    *)         err "sentinel-gpio en estado '$st'"
               problems=$((problems+1))
               fixes+=("pm2 restart sentinel-gpio && pm2 logs sentinel-gpio --lines 30") ;;
  esac

  step "6 · Respuesta del daemon"
  local resp; resp="$(gpio_send PING)"
  if [ -n "$resp" ] && [ "$resp" != "sin-nc" ]; then
    daemon_answers=1
    case "$resp" in
      *connected*)    ok "Responde: $resp ${G}(puerto serie abierto)${N}" ;;
      *disconnected*) err "Responde: $resp"
                      info "El daemon vive pero no pudo abrir el puerto serie."
                      problems=$((problems+1)) ;;
      *)              warn "Respuesta inesperada: $resp" ;;
    esac
  else
    err "El daemon no responde en 127.0.0.1:$(gpio_port)"
    problems=$((problems+1))
  fi

  step "7 · Escritura directa al puerto"
  if python3 -c "import serial" 2>/dev/null && [ -n "$device" ]; then
    local result
    result="$(python3 - "$device" <<'PY' 2>&1
import sys, time
from serial import Serial
try:
    s = Serial(sys.argv[1], 9600, timeout=1, write_timeout=2)
    time.sleep(2)
    s.write(b"0,0,0,255,0,0,0,0\n"); s.flush(); s.close()
    print("OK")
except PermissionError as e:
    print("PERM:%s" % e)
except Exception as e:
    print("ERR:%s" % e)
PY
)"
    case "$result" in
      OK*)   ok "Escritura directa exitosa"
             info "Si las luces no prendieron, el problema es del Arduino para"
             info "adentro: firmware, cableado o alimentación de las tiras." ;;
      PERM*) err "Permiso denegado sobre $device"; problems=$((problems+1)) ;;
      ERR*)  if echo "$result" | grep -qi "busy"; then
               ok "El puerto está ocupado por el daemon — es lo esperado"
             else
               err "No se pudo escribir: ${result#ERR:}"; problems=$((problems+1))
             fi ;;
    esac
  else
    info "Se omite (falta pyserial o no hay puerto serie)"
  fi

  step "8 · API"
  local base; base="$(app_url)"
  if curl -sS -m3 -o /dev/null "$base/healthz" 2>/dev/null; then
    ok "El servidor responde"
    local code; code="$(http_code_post "$base/api/devices/preset/white" 5)"
    case "$code" in
      401) ok "Endpoint de luces protegido (401 sin sesión) — correcto" ;;
      502) err "HTTP 502: el servidor no pudo hablar con el Arduino"; problems=$((problems+1)) ;;
      *)   info "El endpoint devolvió HTTP $code" ;;
    esac
  else
    err "El servidor no responde en $base"
    problems=$((problems+1))
  fi

  echo ""
  hr
  if [ "$problems" -eq 0 ]; then
    echo -e "  ${G}${BOLD}Todo en orden en la cadena de software.${N}"
    echo ""
    info "Si las luces siguen sin responder, mirá el hardware: firmware del"
    info "Arduino, alimentación de las tiras (el USB no alcanza) y cableado."
  else
    echo -e "  ${R}${BOLD}$problems problema(s).${N}"
    if [ "${#fixes[@]}" -gt 0 ]; then
      echo ""
      echo -e "  ${BOLD}Comandos sugeridos, en orden:${N}\n"
      local f; for f in "${fixes[@]}"; do echo -e "    ${B}$f${N}"; done
    fi
  fi
  hr

  if [ "$do_fix" = "1" ] && [ "$problems" -gt 0 ]; then
    step "Reparando"
    python3 -c "import serial" 2>/dev/null || {
      sudo apt-get install -y -qq python3-serial >/dev/null 2>&1 && ok "pyserial instalado"
    }
    groups | grep -qw dialout || {
      sudo usermod -aG dialout "$(whoami)" && ok "Usuario agregado a dialout"
      warn "Hay que reiniciar para que tome efecto"
    }
    if has_pm2; then
      if pm2_exists sentinel-gpio; then
        pm2 restart sentinel-gpio >/dev/null 2>&1 && ok "Daemon reiniciado"
      else
        pm2 start "$APP_DIR/scripts/gpio_daemon.py" --name sentinel-gpio \
          --interpreter python3 --restart-delay 5000 >/dev/null 2>&1 && ok "Daemon creado"
      fi
      pm2 save >/dev/null 2>&1
    fi
    echo ""
    info "Volvé a correr: sentinel diagnose gpio"
  fi

  echo ""
  [ "$daemon_answers" -eq 1 ] || return 1
  return 0
}

gpio_test() {
  local port; port="$(gpio_port)"
  banner "PRUEBA DE LUCES"
  [ -z "$(gpio_send PING)" ] && { err "El daemon no responde"; info "sentinel diagnose gpio"; return 1; }

  info "Mirá las luces mientras corre esto:"
  echo ""
  local seq=("255,0,0,0,0,0,0,0|rojo" "0,255,0,0,0,0,0,0|verde" "0,0,255,0,0,0,0,0|azul" \
             "0,0,0,255,0,0,0,0|blanco" "0,0,0,0,0,0,0,0|apagar")
  local s frame label
  for s in "${seq[@]}"; do
    frame="${s%%|*}"; label="${s#*|}"
    echo "  → $label"
    gpio_send "$frame" | sed 's/^/     /'
    sleep 1.5
  done
  echo ""
  info "¿Viste los cambios? El software está bien."
  info "¿No pasó nada? El problema está en el Arduino o el cableado."
  echo ""
}
