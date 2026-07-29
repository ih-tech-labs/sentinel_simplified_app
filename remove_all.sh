#!/usr/bin/env bash
# =============================================================================
#  SENTINEL · DESINSTALACIÓN COMPLETA
#
#      ./remove_all.sh              asistente con confirmación
#      ./remove_all.sh --keep-code  borra config, datos y servicios; deja el código
#      ./remove_all.sh --purge      además desinstala ffmpeg, pm2, node
#      ./remove_all.sh --yes        sin preguntas
#      ./remove_all.sh --force      ignora la protección de equipo en producción
#
#  ⚠️  ESTO BORRA. No restaura nada.
#      Para volver de la versión nueva a la anterior:  ./deploy.sh --rollback
# =============================================================================
set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"

PARENT_DIR="$(dirname "$APP_DIR")"
KEEP_CODE=0; PURGE=0; ASSUME_YES=0; FORCE=0

for arg in "$@"; do
  case "$arg" in
    --keep-code) KEEP_CODE=1 ;;
    --purge)     PURGE=1 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    --force)     FORCE=1 ;;
    -h|--help)   sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "Opción desconocida: $arg" ;;
  esac
done
export ASSUME_YES

echo -e "${R}${BOLD}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║        SENTINEL · DESINSTALACIÓN COMPLETA                ║
  ║        Esto BORRA. No restaura nada.                     ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${N}"
require_not_root

# ===========================================================================
step "Verificando dónde estoy parado"
# ===========================================================================
DANGER=0; REASONS=()

# Señal 1: instalación anterior al lado (migración escalonada)
[ -f "$PARENT_DIR/src/server.js" ] && [ -f "$PARENT_DIR/package.json" ] && {
  DANGER=1; REASONS+=("hay otra instalación de Sentinel en $PARENT_DIR"); }

# Señal 2: el servicio de la versión anterior sigue en pm2
pm2_exists sentinel-server && { DANGER=1; REASONS+=("pm2 tiene 'sentinel-server' (versión anterior)"); }

# Señal 3: este equipo sirve el túnel de producción
if [ -f /etc/cloudflared/config.yml ]; then
  DOM="$(sudo grep -m1 'hostname:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $NF}')"
  case "$DOM" in
    sentinel.ihtechlabs.com)
      DANGER=1; REASONS+=("este equipo sirve el túnel de PRODUCCIÓN ($DOM)") ;;
  esac
fi

if [ "$DANGER" -eq 1 ]; then
  echo ""
  err "ESTE EQUIPO PARECE ESTAR EN PRODUCCIÓN"
  echo ""
  for r in "${REASONS[@]}"; do info "· $r"; done
  echo ""
  echo -e "  ${Y}Si querés volver a la versión anterior, no borres:${N}"
  echo -e "  ${B}$APP_DIR/deploy.sh --rollback${N}"
  echo ""
  [ "$FORCE" -eq 0 ] && die "Abortado por seguridad.
    Si de verdad querés borrar acá, repetí con --force"
  warn "Continuando por --force."
  echo ""
else
  ok "No detecto una instalación en producción"
fi

# ===========================================================================
step "Esto es lo que voy a borrar"
# ===========================================================================
hr
FOUND=0

SERVICES=()
for svc in sentinel sentinel-v5 sentinel-gpio; do
  pm2_exists "$svc" && { SERVICES+=("$svc"); FOUND=1; }
done
if [ "${#SERVICES[@]}" -gt 0 ]; then
  echo -e "  ${BOLD}Servicios pm2${N}"
  for s in "${SERVICES[@]}"; do echo -e "    ${R}·${N} $s"; done
else
  echo -e "  ${D}Servicios pm2: ninguno${N}"
fi

AUTOSTART="$HOME/.config/autostart"
AUTO_FILES=()
[ -d "$AUTOSTART" ] && while IFS= read -r f; do
  [ -n "$f" ] && AUTO_FILES+=("$f") && FOUND=1
done < <(find "$AUTOSTART" -maxdepth 1 -name 'sentinel*' 2>/dev/null)
[ "${#AUTO_FILES[@]}" -gt 0 ] && {
  echo -e "  ${BOLD}Autostart${N}"
  for f in "${AUTO_FILES[@]}"; do echo -e "    ${R}·${N} $(basename "$f")"; done
}

echo -e "  ${BOLD}Configuración y datos${N}"
for item in .env .session_secret .screen_rotation .deploy_state config data; do
  [ -e "$APP_DIR/$item" ] && {
    echo -e "    ${R}·${N} $item ${D}($(du -sh "$APP_DIR/$item" 2>/dev/null | cut -f1))${N}"; FOUND=1; }
done

[ -f "$DATA_DIR/events.jsonl" ] && \
  warn "Se pierden $(wc -l < "$DATA_DIR/events.jsonl" 2>/dev/null || echo 0) evento(s) del historial"

if [ -f /etc/cloudflared/config.yml ]; then
  echo -e "  ${BOLD}Túnel${N}"
  echo -e "    ${R}·${N} config local de cloudflared ${D}(el túnel de la cuenta NO se borra)${N}"
  FOUND=1
fi

if [ "$KEEP_CODE" -eq 0 ]; then
  echo -e "  ${BOLD}Carpeta completa${N}"
  echo -e "    ${R}·${N} $APP_DIR ${D}($(du -sh "$APP_DIR" 2>/dev/null | cut -f1))${N}"
else
  echo -e "  ${BOLD}Código${N}"
  echo -e "    ${G}·${N} se conserva ${D}(--keep-code)${N}"
  [ -d "$APP_DIR/node_modules" ] && echo -e "    ${R}·${N} node_modules ${D}($(du -sh "$APP_DIR/node_modules" 2>/dev/null | cut -f1))${N}"
fi

[ -d /tmp/sentinel-chromium-cache ] && echo -e "  ${BOLD}Caché${N}\n    ${R}·${N} /tmp/sentinel-chromium-cache"

[ "$PURGE" -eq 1 ] && {
  echo -e "  ${BOLD}${R}Paquetes del sistema (--purge)${N}"
  echo -e "    ${R}·${N} pm2, unclutter, python3-serial, netcat, dnsutils"
  warn "Otros programas del equipo pueden estar usándolos"
}
hr

[ "$FOUND" -eq 0 ] && [ "$KEEP_CODE" -eq 1 ] && { echo ""; ok "Nada para borrar."; echo ""; exit 0; }

# ===========================================================================
BACKUP=""
if [ "$ASSUME_YES" -eq 0 ] && confirm "¿Hago un backup antes de borrar?" "s"; then
  BACKUP="$HOME/sentinel-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  echo -n "  Comprimiendo"
  if tar --exclude='node_modules' --exclude='.git' -czf "$BACKUP" \
        -C "$PARENT_DIR" "$(basename "$APP_DIR")" 2>/dev/null; then
    echo ""; ok "Backup: $BACKUP ${D}($(du -h "$BACKUP" | cut -f1))${N}"
  else
    echo ""; warn "No se pudo crear el backup"
    confirm "¿Seguir igual?" "n" || die "Cancelado."
  fi
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  echo ""
  echo -e "  ${R}${BOLD}Última oportunidad.${N}"
  [ "$KEEP_CODE" -eq 0 ] && echo -e "  ${R}Se borra la carpeta completa: $APP_DIR${N}"
  echo ""
  require_typed BORRAR "Escribí"
fi

sudo -v 2>/dev/null || warn "Sin sudo: algunos pasos pueden fallar"

# ===========================================================================
#  Todo dentro de una función: bash la tiene entera en memoria antes de
#  empezar, así que puede borrar la carpeta donde vive este mismo script sin
#  quedarse sin nada que leer a mitad de camino.
# ===========================================================================
run_removal() {

  step "1/6 · Servicios"
  if has_pm2; then
    for svc in sentinel sentinel-v5 sentinel-gpio; do
      pm2_exists "$svc" && { pm2 stop "$svc" >/dev/null 2>&1; pm2 delete "$svc" >/dev/null 2>&1; ok "$svc eliminado"; }
    done
    pm2 save --force >/dev/null 2>&1 || true
    if [ "$PURGE" -eq 1 ]; then
      pm2 unstartup >/dev/null 2>&1 && ok "Arranque automático de pm2 desactivado" || true
      pm2 kill >/dev/null 2>&1 || true
    else
      info "El arranque automático de pm2 se deja como está ${D}(--purge lo quita)${N}"
    fi
  else
    info "pm2 no está instalado"
  fi

  step "2/6 · Procesos"
  KILLED=0
  for pat in "$APP_DIR/src/server.js" "gpio_daemon.py" "mpeg1video" "chromium.*kiosk"; do
    pkill -f "$pat" 2>/dev/null && KILLED=1
  done
  [ "$KILLED" -eq 1 ] && ok "Procesos terminados" || info "No había procesos corriendo"
  sleep 1

  PORT="$(app_port)"
  PIDS="$(sudo lsof -ti :"$PORT" 2>/dev/null || true)"
  [ -n "$PIDS" ] && { echo "$PIDS" | xargs -r sudo kill -TERM 2>/dev/null; ok "Puerto $PORT liberado"; }

  step "3/6 · Autostart y pantalla"
  REMOVED=0
  [ -d "$AUTOSTART" ] && while IFS= read -r f; do
    [ -n "$f" ] && rm -f "$f" && ok "$(basename "$f")" && REMOVED=1
  done < <(find "$AUTOSTART" -maxdepth 1 -name 'sentinel*' 2>/dev/null)
  [ "$REMOVED" -eq 0 ] && info "No había entradas de autostart"

  if [ -f "$HOME/.config/labwc/autostart" ] && grep -q "sentinel-rotation" "$HOME/.config/labwc/autostart" 2>/dev/null; then
    sed -i '/# sentinel-rotation/d' "$HOME/.config/labwc/autostart"
    ok "Rotación quitada de labwc"
  fi
  [ -f "$HOME/.config/wayfire.ini" ] && grep -q "^transform" "$HOME/.config/wayfire.ini" 2>/dev/null && \
    warn "La rotación quedó en ~/.config/wayfire.ini — quitala a mano si querés volver a horizontal"

  LX="$HOME/.config/lxsession/LXDE-pi/autostart"
  [ -f "$LX" ] && grep -q "xset s off" "$LX" 2>/dev/null && {
    sed -i '/^@xset s off$/d; /^@xset -dpms$/d; /^@xset s noblank$/d' "$LX"
    ok "Ajustes de pantalla revertidos"
  }

  step "4/6 · Túnel"
  if [ -f /etc/cloudflared/config.yml ]; then
    sudo systemctl stop cloudflared 2>/dev/null && ok "cloudflared detenido" || true
    sudo systemctl disable cloudflared >/dev/null 2>&1 || true
    sudo cloudflared service uninstall >/dev/null 2>&1 || true
    STAMP2="$(date +%Y%m%d-%H%M%S)"
    sudo mkdir -p "/etc/cloudflared.bak-$STAMP2"
    sudo cp -a /etc/cloudflared/. "/etc/cloudflared.bak-$STAMP2/" 2>/dev/null || true
    sudo rm -f /etc/cloudflared/config.yml /etc/cloudflared/*.json 2>/dev/null
    ok "Config local del túnel borrada ${D}(backup en /etc/cloudflared.bak-$STAMP2)${N}"
    info "El túnel en tu cuenta de Cloudflare NO se tocó."
    info "Para borrarlo: cloudflared tunnel delete <nombre>"
  else
    info "Sin túnel configurado"
  fi

  step "5/6 · Caché y datos"
  [ -d /tmp/sentinel-chromium-cache ] && { rm -rf /tmp/sentinel-chromium-cache; ok "Caché de Chromium"; }
  rm -f /tmp/sentinel-bg-*.mp4 2>/dev/null || true

  if [ "$KEEP_CODE" -eq 1 ]; then
    for item in .env .session_secret .screen_rotation .deploy_state config data node_modules package-lock.json; do
      [ -e "$APP_DIR/$item" ] && rm -rf "${APP_DIR:?}/$item" && ok "$item"
    done
    find "$APP_DIR" -maxdepth 2 -name '*.bak-*' -delete 2>/dev/null || true
    ok "Código conservado en $APP_DIR"
  else
    info "Se borra junto con la carpeta en el paso siguiente"
  fi

  step "6/6 · Paquetes"
  if [ "$PURGE" -eq 1 ]; then
    command -v npm >/dev/null 2>&1 && { sudo npm uninstall -g pm2 >/dev/null 2>&1 && ok "pm2 desinstalado"; }
    for pkg in unclutter python3-serial netcat-openbsd dnsutils wlr-randr; do
      dpkg -s "$pkg" >/dev/null 2>&1 && sudo apt-get remove -y -qq "$pkg" >/dev/null 2>&1 && ok "$pkg"
    done
    confirm "¿Desinstalar ffmpeg? (lo usan otros programas)" "n" && \
      sudo apt-get remove -y -qq ffmpeg >/dev/null 2>&1 && ok "ffmpeg desinstalado"
    confirm "¿Desinstalar Node.js?" "n" && {
      sudo apt-get remove -y -qq nodejs >/dev/null 2>&1 && ok "Node.js desinstalado"
      sudo rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
    }
    sudo apt-get autoremove -y -qq >/dev/null 2>&1 || true
  else
    info "Los paquetes del sistema quedan intactos ${D}(--purge los quita)${N}"
  fi

  # --- Resumen ANTES de borrar la carpeta: después este script no existe ---
  echo ""
  echo -e "${G}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║              DESINSTALACIÓN COMPLETA                     ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${N}"

  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] && {
    echo -e "  Backup:  ${B}$BACKUP${N}"
    echo -e "  ${D}Restaurar: tar -xzf $BACKUP -C ~/${N}"
    echo ""
  }

  if [ "$KEEP_CODE" -eq 1 ]; then
    echo -e "  El código quedó en ${B}$APP_DIR${N}"
    echo -e "  ${D}Reinstalar: ./install.sh${N}"
  else
    echo -e "  ${Y}Borrando la carpeta...${N}"
  fi
  echo ""

  if [ "$KEEP_CODE" -eq 0 ]; then
    cd /tmp || cd /
    if rm -rf "${APP_DIR:?}"; then
      echo -e "  ${G}✔${N} $APP_DIR borrado"
    else
      echo -e "  ${R}✘${N} No se pudo borrar $APP_DIR — probá con sudo"
    fi
    echo ""
    echo -e "  ${D}Reiniciá para confirmar que no arranca nada:${N} ${B}sudo reboot${N}"
    echo ""
  fi
}

run_removal
