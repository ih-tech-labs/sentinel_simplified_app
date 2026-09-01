#!/usr/bin/env bash
# =============================================================================
#  SENTINEL · MIGRACIÓN
#
#      ./deploy.sh --check              ¿está todo listo? No toca NADA
#      ./deploy.sh                      migra, verifica, y vuelve solo si falla
#      ./deploy.sh --rollback           volver al estado anterior
#      ./deploy.sh --old-dir <ruta>     indicar dónde está la versión anterior
#
#  EL TÚNEL DE CLOUDFLARE NO SE TOCA. Ni en la migración ni en el rollback.
#  Es lo único que no se puede reconstruir desde el equipo: si se rompe, el
#  sitio se queda sin alarmas de Verkada. Se hereda tal cual y se verifica.
#
#  Para limpiar la versión vieja y los túneles que sobren, DESPUÉS de que todo
#  esté confirmado, hay un script aparte:  ./cleanup_old.sh
# =============================================================================
set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/checks.sh
. "$APP_DIR/lib/checks.sh"
# shellcheck source=lib/deploy.sh
. "$APP_DIR/lib/deploy.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/sentinel-backup-$STAMP.tar.gz"
LOG="$HOME/sentinel-deploy-$STAMP.log"

MODE=migrate; OLD_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--preflight) MODE=check ;;
    --dry-run)           MODE=check ;;
    --rollback)          MODE=rollback ;;
    --old-dir)           shift; OLD_DIR="$(sanitize "${1:-}")" ;;
    --old-dir=*)         OLD_DIR="$(sanitize "${1#*=}")" ;;
    -h|--help)           sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                   die "Opción desconocida: $1" ;;
  esac
  shift
done

require_not_root
require_app_dir

# ---------------------------------------------------------------------------
# Dónde vive la versión anterior
# ---------------------------------------------------------------------------
find_old_install() {
  local c
  for c in "$@"; do
    [ -n "$c" ] || continue
    [ "$(cd "$c" 2>/dev/null && pwd)" = "$APP_DIR" ] && continue
    [ -f "$c/src/server.js" ] && [ -f "$c/package.json" ] && { echo "$c"; return 0; }
  done
  return 1
}

if [ -z "$OLD_DIR" ]; then
  OLD_DIR="$(find_old_install \
    "$(dirname "$APP_DIR")" \
    "$HOME/sentinel_simplified_app" \
    "$HOME/sentinel_ce/sentinel_simplified_app" \
    "$HOME/sentinel_v5" || true)"
fi
[ -n "$OLD_DIR" ] && OLD_DIR="$(cd "$OLD_DIR" 2>/dev/null && pwd || echo "$OLD_DIR")"

# ===========================================================================
#  ROLLBACK
# ===========================================================================
if [ "$MODE" = "rollback" ]; then
  deploy_restore "pedido manual"
  exit 0
fi

# ===========================================================================
#  PREFLIGHT
# ===========================================================================
if [ "$MODE" = "check" ]; then
  fix_line_endings >/dev/null 2>&1
  deploy_preflight "$OLD_DIR"
  exit $?
fi

# ===========================================================================
#  MIGRACIÓN
# ===========================================================================
exec > >(tee -a "$LOG") 2>&1

echo -e "${B}${BOLD}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║   SENTINEL · MIGRACIÓN                                   ║
  ║   con vuelta atrás automática si algo falla              ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${N}"

fix_line_endings

# --- 1. Preflight obligatorio ---------------------------------------------
if ! deploy_preflight "$OLD_DIR"; then
  echo ""
  die "El preflight encontró problemas. No se migró nada.
    Resolvelos y volvé a intentar."
fi

echo ""
confirm "¿Migro ahora?" "s" || die "Cancelado. No se tocó nada."
keep_sudo_alive

TUNNEL_DOMAIN="$(current_tunnel_domain 2>/dev/null || true)"

# --- 2. Snapshot -----------------------------------------------------------
step "1/7 · Fotografiando el estado actual"
deploy_snapshot "$OLD_DIR"

# --- 3. Backup -------------------------------------------------------------
step "2/7 · Backup"
if [ -n "$OLD_DIR" ] && [ -d "$OLD_DIR" ]; then
  tar --exclude='node_modules' --exclude='.git' -czf "$BACKUP" \
      -C "$(dirname "$OLD_DIR")" "$(basename "$OLD_DIR")" 2>/dev/null \
    && ok "Backup: $BACKUP ($(du -h "$BACKUP" | cut -f1))" \
    || die "Falló el backup. Se aborta por seguridad."
else
  warn "Sin versión anterior que respaldar"
fi
[ -d /etc/cloudflared ] && sudo tar -czf "$HOME/cloudflared-backup-$STAMP.tar.gz" \
    -C /etc cloudflared 2>/dev/null && ok "Config del túnel respaldada (por las dudas)"

# --- 4. Heredar configuración ---------------------------------------------
step "3/7 · Heredando configuración"
mkdir -p "$CONFIG_DIR" "$DATA_DIR"

if [ ! -f "$ENV_FILE" ]; then
  cp "$APP_DIR/.env.example" "$ENV_FILE" || die "Falta .env.example"
  if [ -n "$OLD_DIR" ] && [ -f "$OLD_DIR/.env" ]; then
    OLD_SECRET="$(grep -m1 '^VERKADA_SHARED_SECRET=' "$OLD_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
    OLD_PORT="$(grep -m1 '^PORT=' "$OLD_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
    [ -n "${OLD_SECRET:-}" ] && sed -i "s|^VERKADA_SHARED_SECRET=.*|VERKADA_SHARED_SECRET=$OLD_SECRET|" "$ENV_FILE" \
      && ok "Secret de Verkada heredado"
    [ -n "${OLD_PORT:-}" ] && sed -i "s|^PORT=.*|PORT=$OLD_PORT|" "$ENV_FILE" \
      && ok "Puerto heredado: $OLD_PORT"
  fi
  SS="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
  sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=$SS|" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok ".env creado"
else
  ok ".env ya existe: se conserva"
fi

[ -z "$(env_get VERKADA_SHARED_SECRET)" ] && \
  warn "VERKADA_SHARED_SECRET vacío: cargalo o el webhook rechaza todo"

[ -f "$CAMERAS_JSON" ] && ok "cameras.json existente: se conserva" \
                       || info "Sin cameras.json: se usan las cámaras por defecto del código"

# Apariencia del kiosko: como cameras.json, es config del sitio y se hereda
if [ ! -f "$CONFIG_DIR/appearance.json" ] && [ -n "$OLD_DIR" ] && [ -f "$OLD_DIR/config/appearance.json" ]; then
  cp "$OLD_DIR/config/appearance.json" "$CONFIG_DIR/appearance.json" \
    && ok "Apariencia del kiosko heredada"
fi

# --- 5. Dependencias -------------------------------------------------------
step "4/7 · Dependencias"
cd "$APP_DIR"
npm install --omit=dev --no-audit --no-fund 2>&1 | tail -3 || {
  err "Falló npm install"
  deploy_restore "npm install falló"
  exit 1
}
ok "Paquetes instalados"

# --- 6. Cambio de servicio -------------------------------------------------
step "5/7 · Deteniendo la versión anterior"
if pm2_exists sentinel-server; then
  pm2 stop sentinel-server >/dev/null 2>&1
  ok "sentinel-server detenido ${D}(no borrado: el rollback lo revive)${N}"
fi

PORT="$(app_port)"
for P in "$PORT" 9998 9999; do
  PIDS="$(sudo lsof -ti :"$P" 2>/dev/null || true)"
  [ -n "$PIDS" ] && { echo "$PIDS" | xargs -r sudo kill -TERM 2>/dev/null; sleep 1; warn "Puerto $P liberado"; }
done
pkill -f "node-rtsp-stream" 2>/dev/null && warn "ffmpeg huérfanos terminados" || true

step "6/7 · Levantando la versión nueva"
pm2 delete sentinel sentinel-v5 sentinel-gpio >/dev/null 2>&1 || true

if [ "$(env_get GPIO_ENABLED true)" = "true" ] && python3 -c "import serial" 2>/dev/null; then
  pm2 start "$APP_DIR/scripts/gpio_daemon.py" --name sentinel-gpio \
    --interpreter python3 --restart-delay 5000 >/dev/null 2>&1 \
    && ok "Daemon de luces activo" || warn "No arrancó el daemon de luces"
fi

pm2 start "$APP_DIR/src/server.js" --name sentinel --cwd "$APP_DIR" \
  --max-memory-restart 400M --restart-delay 3000 --time >/dev/null 2>&1 || {
  deploy_restore "no se pudo iniciar el servidor"
  exit 1
}
ok "Servidor iniciado"

# --- 7. Verificación -------------------------------------------------------
step "7/7 · Verificación"
checks_reset
check_services
check_endpoints

# El túnel es lo que trae las alarmas: si dejó de responder, el sitio queda
# ciego aunque el servidor local esté perfecto. Cuenta como fallo.
if [ -n "$TUNNEL_DOMAIN" ]; then
  step "Túnel (no se modificó)"
  systemctl is-active --quiet cloudflared 2>/dev/null && ok "cloudflared corriendo" \
    || { sudo systemctl restart cloudflared >/dev/null 2>&1; sleep 5; }

  CODE="$(http_code "https://$TUNNEL_DOMAIN/healthz" 15)"
  [ "$CODE" = "200" ] && check_pass "El túnel sigue funcionando" "https://$TUNNEL_DOMAIN" \
                      || check_fail "El túnel no responde" "HTTP $CODE"

  WH="$(http_code_post "https://$TUNNEL_DOMAIN/verkada-webhook" 15)"
  [ "$WH" = "400" ] && check_pass "Webhook accesible desde internet" \
                    || check_warn "El webhook devolvió HTTP $WH"
fi

checks_summary || true

if [ "$CHECKS_FAILED" -gt 0 ]; then
  echo ""
  err "$CHECKS_FAILED verificación(es) fallaron."
  echo -e "  ${Y}Volviendo solo al estado anterior para no dejar el sitio caído.${N}"
  echo ""
  sleep 3
  deploy_restore "fallaron $CHECKS_FAILED verificaciones"
  echo -e "  ${D}Log completo: $LOG${N}\n"
  exit 1
fi

# --- 8. Fijar --------------------------------------------------------------
step "Fijando la versión nueva"
pm2 save >/dev/null 2>&1
ok "Lista de pm2 guardada ${D}(sentinel-server queda detenido, no borrado)${N}"

STARTUP="$(pm2 startup 2>/dev/null | grep -E '^sudo ' | tail -1)"
if [ -n "$STARTUP" ]; then
  eval "$STARTUP" >/dev/null 2>&1 && { pm2 save >/dev/null 2>&1; ok "Arranque automático configurado"; } \
    || { warn "Ejecutá a mano:"; echo -e "       ${Y}$STARTUP${N}"; }
fi

KIOSK_ID="$(first_kiosk)"
chmod +x "$APP_DIR"/*.sh "$APP_DIR/sentinel" 2>/dev/null || true
AUTOSTART="$HOME/.config/autostart"; mkdir -p "$AUTOSTART"
for OLD in "$AUTOSTART"/sentinel.desktop; do
  [ -f "$OLD" ] && mv "$OLD" "$OLD.pre-deploy-$STAMP"
done
cat > "$AUTOSTART/sentinel-kiosk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Sentinel Kiosk
Exec=$APP_DIR/sentinel kiosk $KIOSK_ID
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=10
EOF
chmod +x "$AUTOSTART/sentinel-kiosk.desktop"
ok "Autostart del kiosko actualizado (puesto: $KIOSK_ID)"

REPORT="$HOME/sentinel-deploy-$(hostname)-$STAMP.txt"
write_report "$REPORT" "Reporte de migración"

# ===========================================================================
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; IP="${IP:-localhost}"
echo ""
echo -e "${G}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║              MIGRACIÓN COMPLETA                          ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${N}"
hr
echo -e "  Tablero    ${B}http://$IP:$PORT/backoffice/${N}"
[ -n "$TUNNEL_DOMAIN" ] && echo -e "  Remoto     ${B}https://$TUNNEL_DOMAIN/backoffice/${N}"
echo -e "  Kiosko     ${B}http://$IP:$PORT/kiosk/?id=$KIOSK_ID${N}"
[ -n "$TUNNEL_DOMAIN" ] && {
  echo ""
  echo -e "  ${BOLD}Webhook de Verkada — SIN CAMBIOS:${N}"
  echo -e "    ${B}https://$TUNNEL_DOMAIN/verkada-webhook${N}"
}
hr
echo ""
echo -e "  Backup    ${D}$BACKUP${N}"
echo -e "  Reporte   ${D}$REPORT${N}"
echo -e "  Log       ${D}$LOG${N}"
[ -n "$OLD_DIR" ] && echo -e "  Anterior  ${D}$OLD_DIR  (intacta)${N}"
echo ""
echo -e "  ${BOLD}Si algo se ve mal, en cualquier momento:${N}"
echo -e "    ${B}./deploy.sh --rollback${N}"
echo ""
echo -e "  ${BOLD}Cuando confirmes que todo anda bien:${N}"
echo -e "    ${B}./cleanup_old.sh${N}   ${D}borra la versión vieja y los túneles que sobren${N}"
echo ""
echo -e "  ${Y}Reiniciá para validar el arranque automático:${N} ${B}sudo reboot${N}"
echo ""
