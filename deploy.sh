#!/usr/bin/env bash
# =============================================================================
#  SENTINEL · MIGRACIÓN CON AUTO-ROLLBACK
#
#  Para un equipo que ya tiene la versión anterior corriendo — Costa Esmeralda
#  y su túnel sentinel.ihtechlabs.com.
#
#      ./deploy.sh                    migra, verifica, y si algo falla vuelve solo
#      ./deploy.sh --dry-run          simula: dice qué haría, sin tocar nada
#      ./deploy.sh --rollback         vuelve a la versión anterior a mano
#      ./deploy.sh --old-dir <ruta>   indicar dónde está la versión anterior
#
#  QUÉ HACE
#    1. Verifica requisitos y detecta la instalación anterior
#    2. Backup completo, con fecha
#    3. Hereda .env, cámaras y el túnel existente
#    4. Para la versión vieja y levanta la nueva
#    5. Verifica de punta a punta, incluido el túnel
#    6. Si algo falla → vuelve sola a la versión anterior
#
#  Pensado para correr por SSH: si falla no te deja el sitio caído.
# =============================================================================
set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/checks.sh
. "$APP_DIR/lib/checks.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/sentinel-backup-$STAMP.tar.gz"
STATE="$APP_DIR/.deploy_state"
LOG="$HOME/sentinel-deploy-$STAMP.log"

DRY_RUN=0; DO_ROLLBACK=0; OLD_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --rollback) DO_ROLLBACK=1 ;;
    --old-dir)  shift; OLD_DIR="$(sanitize "${1:-}")" ;;
    --old-dir=*) OLD_DIR="$(sanitize "${1#*=}")" ;;
    -h|--help)  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "Opción desconocida: $1" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Dónde está la instalación anterior.
#
# Ya no se asume que sea la carpeta de arriba: esta versión vive sola en su
# repositorio y se puede clonar en cualquier lado. Se buscan los lugares
# habituales y, si no aparece, se pregunta.
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
    "$HOME/sentinel" \
    "$HOME/Sentinel" || true)"
fi

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------
rollback() {
  local reason="${1:-solicitado}"
  echo ""
  echo -e "${Y}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║   ROLLBACK · volviendo a la versión anterior             ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${N}"
  warn "Motivo: $reason"
  echo ""

  pm2 stop sentinel        >/dev/null 2>&1 && ok "Servicio nuevo detenido" || true
  pm2 delete sentinel      >/dev/null 2>&1 || true
  pm2 delete sentinel-gpio >/dev/null 2>&1 || true
  pkill -f "$APP_DIR/src/server.js" 2>/dev/null || true
  pkill -f "gpio_daemon.py" 2>/dev/null || true
  pkill -f "mpeg1video" 2>/dev/null || true
  sleep 2

  local pids; pids="$(sudo lsof -ti :"$(app_port)" 2>/dev/null || true)"
  [ -n "$pids" ] && { echo "$pids" | xargs -r sudo kill -TERM 2>/dev/null; sleep 1; }

  # Restaurar el autostart del kiosko
  local a="$HOME/.config/autostart"
  rm -f "$a/sentinel-kiosk.desktop" 2>/dev/null || true
  local bak; bak="$(ls -t "$a"/sentinel.desktop.pre-deploy-* 2>/dev/null | head -1)"
  [ -n "$bak" ] && { mv "$bak" "$a/sentinel.desktop"; ok "Autostart anterior restaurado"; }

  # Volver a levantar la versión vieja
  if pm2_exists sentinel-server; then
    pm2 restart sentinel-server >/dev/null 2>&1 && ok "sentinel-server reiniciado"
  elif [ -n "$OLD_DIR" ] && [ -f "$OLD_DIR/src/server.js" ]; then
    pm2 start "$OLD_DIR/src/server.js" --name sentinel-server --cwd "$OLD_DIR" >/dev/null 2>&1 \
      && ok "sentinel-server iniciado"
  else
    err "No encuentro la instalación anterior${OLD_DIR:+ en $OLD_DIR}"
  fi
  pm2 save >/dev/null 2>&1 || true

  echo ""
  if wait_for_http "$(app_url)/" 20; then
    ok "La versión anterior está respondiendo"
    echo ""
    echo -e "  ${G}Rollback completo. El sitio volvió a como estaba.${N}"
    echo -e "  ${D}Los kioskos se reconectan solos en unos segundos.${N}"
  else
    err "La versión anterior no respondió"
    echo ""
    echo -e "  ${R}${BOLD}ATENCIÓN: revisá manualmente.${N}"
    echo -e "    pm2 logs sentinel-server"
    echo -e "    cd $OLD_DIR && node src/server.js"
    echo -e "\n  Backup completo en: ${B}$BACKUP${N}"
  fi
  echo ""
  echo -e "  Log de este deploy: ${B}$LOG${N}"
  echo ""
}

if [ "$DO_ROLLBACK" -eq 1 ]; then
  require_not_root
  rollback "pedido manual"
  exit 0
fi

# ---------------------------------------------------------------------------
exec > >(tee -a "$LOG") 2>&1

echo -e "${B}${BOLD}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║   SENTINEL · MIGRACIÓN                                   ║
  ║   con vuelta atrás automática si algo falla              ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${N}"
[ "$DRY_RUN" -eq 1 ] && { warn "MODO SIMULACIÓN: no se modifica nada"; echo ""; }

# ===========================================================================
step "1/8 · Verificaciones previas"
# ===========================================================================
require_not_root
require_app_dir
fix_line_endings
ok "Versión nueva : $APP_DIR"

OLD_FOUND=0
if [ -n "$OLD_DIR" ] && [ -f "$OLD_DIR/src/server.js" ]; then
  OLD_FOUND=1
  OLD_DIR="$(cd "$OLD_DIR" && pwd)"
  ok "Versión anterior: $OLD_DIR"
else
  warn "No encontré automáticamente la instalación anterior"
  info "Busqué en la carpeta de arriba, ~/sentinel_simplified_app y similares."
  echo ""
  if confirm "¿Está en otra ruta?" "s"; then
    while true; do
      ask OLD_DIR "Ruta de la instalación anterior" "$HOME/sentinel_simplified_app"
      if [ -f "$OLD_DIR/src/server.js" ]; then
        OLD_DIR="$(cd "$OLD_DIR" && pwd)"; OLD_FOUND=1
        ok "Versión anterior: $OLD_DIR"
        break
      fi
      err "No hay un src/server.js en \"$OLD_DIR\""
      confirm "¿Probar otra ruta?" "s" || break
    done
  fi
  if [ "$OLD_FOUND" -eq 0 ]; then
    warn "Sin instalación anterior: no va a haber backup ni vuelta atrás a una versión previa."
    info "Si este equipo está limpio, conviene usar ./install.sh"
    confirm "¿Seguir igual?" "n" || die "Cancelado."
  fi
fi

pm2_exists sentinel-server && ok "Servicio anterior 'sentinel-server' detectado" \
                           || warn "No hay un pm2 'sentinel-server' corriendo"

checks_reset
check_dependencies
[ "$CHECKS_FAILED" -gt 0 ] && die "Faltan requisitos. Instalalos y volvé a correr esto."

# --- Túnel existente: se hereda, no se toca ---
TUNNEL_DOMAIN=""
if [ -f /etc/cloudflared/config.yml ]; then
  TUNNEL_DOMAIN="$(sudo grep -m1 'hostname:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $NF}')"
  TUNNEL_PORT="$(sudo grep -m1 'service: http' /etc/cloudflared/config.yml 2>/dev/null | grep -oE '[0-9]+$')"
  ok "Túnel existente: $TUNNEL_DOMAIN → puerto ${TUNNEL_PORT:-?}"
  info "Se conserva tal cual. La versión nueva usa el mismo puerto."
else
  warn "Sin túnel configurado en este equipo"
fi

# ===========================================================================
step "2/8 · Backup"
# ===========================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  info "[simulación] Backup de $OLD_DIR en $BACKUP"
else
  if [ "$OLD_FOUND" -eq 1 ]; then
    tar --exclude='node_modules' --exclude='.git' \
        -czf "$BACKUP" -C "$(dirname "$OLD_DIR")" "$(basename "$OLD_DIR")" 2>/dev/null \
      && ok "Backup: $BACKUP ($(du -h "$BACKUP" | cut -f1))" \
      || die "Falló el backup. Se aborta por seguridad."
  fi
  # También la config de cloudflared, por si hay que reconstruirla
  [ -d /etc/cloudflared ] && sudo tar -czf "$HOME/cloudflared-backup-$STAMP.tar.gz" \
      -C /etc cloudflared 2>/dev/null && ok "Backup del túnel guardado"
fi

# ===========================================================================
step "3/8 · Heredando configuración"
# ===========================================================================
mkdir -p "$CONFIG_DIR" "$DATA_DIR"

# .env
if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$OLD_DIR/.env" ]; then
    info "Tomando valores del .env anterior..."
    OLD_SECRET="$(grep -m1 '^VERKADA_SHARED_SECRET=' "$OLD_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
    OLD_PORT="$(grep -m1 '^PORT=' "$OLD_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    cp "$APP_DIR/.env.example" "$ENV_FILE" 2>/dev/null || die "Falta .env.example"
    [ -n "${OLD_SECRET:-}" ] && sed -i "s|^VERKADA_SHARED_SECRET=.*|VERKADA_SHARED_SECRET=$OLD_SECRET|" "$ENV_FILE"
    [ -n "${OLD_PORT:-}" ]   && sed -i "s|^PORT=.*|PORT=$OLD_PORT|" "$ENV_FILE"
    SS="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
    sed -i "s|^SESSION_SECRET=.*|SESSION_SECRET=$SS|" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok ".env creado$( [ -n "${OLD_SECRET:-}" ] && echo ' (secret de Verkada heredado)' )"
  else
    info "[simulación] Se crearía .env heredando el secret de Verkada"
  fi
else
  ok ".env ya existe: se conserva"
fi

[ -z "$(env_get VERKADA_SHARED_SECRET)" ] && \
  warn "VERKADA_SHARED_SECRET vacío: cargalo en .env o el webhook rechaza todo"

# cameras.json: si no hay, el código usa los valores por defecto del sitio
if [ -f "$CAMERAS_JSON" ]; then
  ok "cameras.json ya existe: se conserva"
else
  info "Sin cameras.json: se usan las cámaras por defecto del código"
  info "Para verlas o cambiarlas: sentinel cameras"
fi

# ===========================================================================
step "4/8 · Dependencias"
# ===========================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  info "[simulación] npm install --omit=dev"
else
  cd "$APP_DIR"
  npm install --omit=dev --no-audit --no-fund 2>&1 | tail -3 || die "Falló npm install"
  ok "Paquetes instalados"
fi

checks_reset
check_syntax
[ "$CHECKS_FAILED" -gt 0 ] && die "El código tiene errores de sintaxis. No se migra."

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  hr
  echo -e "  ${G}${BOLD}Simulación completa. Todo listo para migrar.${N}"
  echo ""
  info "Cuando quieras hacerlo de verdad:  ./deploy.sh"
  hr
  echo ""
  exit 0
fi

# ===========================================================================
step "5/8 · Deteniendo la versión anterior"
# ===========================================================================
echo "STAMP=$STAMP" > "$STATE"
if pm2_exists sentinel-server; then
  pm2 stop sentinel-server >/dev/null 2>&1
  echo "OLD_PM2=sentinel-server" >> "$STATE"
  ok "sentinel-server detenido ${D}(no borrado: la vuelta atrás lo reinicia)${N}"
fi

for P in $(app_port) 9998 9999; do
  PIDS="$(sudo lsof -ti :"$P" 2>/dev/null || true)"
  [ -n "$PIDS" ] && { echo "$PIDS" | xargs -r sudo kill -TERM 2>/dev/null; sleep 1; warn "Puerto $P liberado"; }
done
pkill -f "node-rtsp-stream" 2>/dev/null && warn "ffmpeg huérfanos terminados" || true

# Archivar el autostart viejo para poder restaurarlo en un rollback
AUTOSTART="$HOME/.config/autostart"
if [ -f "$AUTOSTART/sentinel.desktop" ]; then
  mv "$AUTOSTART/sentinel.desktop" "$AUTOSTART/sentinel.desktop.pre-deploy-$STAMP"
  ok "Autostart anterior archivado"
fi

# ===========================================================================
step "6/8 · Levantando la versión nueva"
# ===========================================================================
pm2 delete sentinel sentinel-v5 sentinel-gpio >/dev/null 2>&1 || true

if [ "$(env_get GPIO_ENABLED true)" = "true" ] && python3 -c "import serial" 2>/dev/null; then
  pm2 start "$APP_DIR/scripts/gpio_daemon.py" --name sentinel-gpio \
    --interpreter python3 --restart-delay 5000 >/dev/null 2>&1 \
    && ok "Daemon de luces activo" || warn "No arrancó el daemon de luces"
fi

pm2 start "$APP_DIR/src/server.js" --name sentinel --cwd "$APP_DIR" \
  --max-memory-restart 400M --restart-delay 3000 --time >/dev/null 2>&1 \
  || { rollback "no se pudo iniciar el servidor"; exit 1; }
ok "Servidor iniciado"

# ===========================================================================
step "7/8 · Verificación"
# ===========================================================================
checks_reset
check_services
check_endpoints

# El túnel es lo que trae las alarmas de Verkada: si se rompió, el sitio queda
# ciego aunque el servidor local responda. Por eso cuenta como fallo.
if [ -n "$TUNNEL_DOMAIN" ]; then
  step "Túnel"
  systemctl is-active --quiet cloudflared 2>/dev/null && ok "cloudflared corriendo" \
    || { sudo systemctl restart cloudflared >/dev/null 2>&1; sleep 5; }
  CODE="$(http_code "https://$TUNNEL_DOMAIN/healthz" 15)"
  if [ "$CODE" = "200" ]; then
    check_pass "El túnel sigue funcionando" "https://$TUNNEL_DOMAIN"
  else
    check_fail "El túnel no responde" "HTTP $CODE"
  fi
  WH="$(http_code_post "https://$TUNNEL_DOMAIN/verkada-webhook" 15)"
  [ "$WH" = "400" ] && check_pass "Webhook accesible desde internet" \
                    || check_warn "El webhook devolvió HTTP $WH"
fi

checks_summary || true

# ===========================================================================
if [ "$CHECKS_FAILED" -gt 0 ]; then
  echo ""
  err "$CHECKS_FAILED verificación(es) fallaron."
  echo ""
  echo -e "  ${Y}Volviendo automáticamente a la versión anterior para no dejar${N}"
  echo -e "  ${Y}el sitio caído. Nada se perdió: el backup está guardado.${N}"
  echo ""
  sleep 3
  rollback "fallaron $CHECKS_FAILED verificaciones"
  echo -e "  ${D}Revisá el log y volvé a intentar: ${N}$LOG"
  echo ""
  exit 1
fi

# ===========================================================================
step "8/8 · Fijando la versión nueva"
# ===========================================================================
pm2 delete sentinel-server >/dev/null 2>&1 && ok "Servicio anterior quitado de pm2" || true
pm2 save >/dev/null 2>&1
ok "Lista de procesos guardada"

STARTUP="$(pm2 startup 2>/dev/null | grep -E '^sudo ' | tail -1)"
if [ -n "$STARTUP" ]; then
  eval "$STARTUP" >/dev/null 2>&1 && { pm2 save >/dev/null 2>&1; ok "Arranque automático configurado"; } \
    || { warn "Ejecutá a mano:"; echo -e "       ${Y}$STARTUP${N}"; }
else
  ok "pm2 ya arranca con el sistema"
fi

KIOSK_ID="$(first_kiosk)"
chmod +x "$APP_DIR"/*.sh "$APP_DIR/sentinel" 2>/dev/null || true
mkdir -p "$AUTOSTART"
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
echo -e "  Backoffice   ${B}http://$IP:$(app_port)/backoffice/${N}"
[ -n "$TUNNEL_DOMAIN" ] && echo -e "  Remoto       ${B}https://$TUNNEL_DOMAIN/backoffice/${N}"
echo -e "  Kiosko       ${B}http://$IP:$(app_port)/kiosk/?id=$KIOSK_ID${N}"
[ -n "$TUNNEL_DOMAIN" ] && {
  echo ""
  echo -e "  ${BOLD}Webhook de Verkada (sin cambios):${N}"
  echo -e "    ${B}https://$TUNNEL_DOMAIN/verkada-webhook${N}"
}
hr
echo ""
echo -e "  Backup   ${D}$BACKUP${N}"
echo -e "  Reporte  ${D}$REPORT${N}"
echo -e "  Log      ${D}$LOG${N}"
echo -e "  Anterior ${D}$OLD_DIR  (sigue ahí, borrala cuando quieras)${N}"
echo ""
echo -e "  ${BOLD}Si algo se ve mal en las próximas horas:${N}"
echo -e "    ${B}./deploy.sh --rollback${N}   ${D}vuelve a la versión anterior${N}"
echo ""
echo -e "  ${Y}Reiniciá para validar el arranque automático:${N} ${B}sudo reboot${N}"
echo ""
