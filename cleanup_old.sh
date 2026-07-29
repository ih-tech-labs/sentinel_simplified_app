#!/usr/bin/env bash
# =============================================================================
#  SENTINEL · LIMPIEZA POSTERIOR A LA MIGRACIÓN
#
#  Corré esto SÓLO cuando ya confirmaste que la versión nueva anda bien.
#  Después de esto, el rollback deja de estar disponible.
#
#      ./cleanup_old.sh              asistente, pregunta cada cosa
#      ./cleanup_old.sh --tunnels    sólo la parte de túneles
#      ./cleanup_old.sh --code       sólo la carpeta y el servicio viejos
#      ./cleanup_old.sh --list       ver qué hay para limpiar, sin borrar
#
#  Nada se borra sin confirmación explícita, y el túnel EN USO está protegido:
#  hay que escribir su nombre completo para que se pueda tocar.
# =============================================================================
set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/tunnel.sh
. "$APP_DIR/lib/tunnel.sh"
# shellcheck source=lib/deploy.sh
. "$APP_DIR/lib/deploy.sh"

DO_TUNNELS=1; DO_CODE=1; LIST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --tunnels) DO_CODE=0 ;;
    --code)    DO_TUNNELS=0 ;;
    --list)    LIST_ONLY=1 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "Opción desconocida: $arg" ;;
  esac
done

require_not_root
require_app_dir

banner "LIMPIEZA POSTERIOR A LA MIGRACIÓN"

# ===========================================================================
step "Verificando que la versión nueva esté sana"
# ===========================================================================
# Si la nueva no está funcionando, borrar la vieja te deja sin nada.
HEALTHY=1
if [ "$(pm2_status sentinel)" = "online" ]; then
  ok "Servicio 'sentinel' online"
else
  err "El servicio 'sentinel' NO está online"; HEALTHY=0
fi

if curl -sS -m5 -o /dev/null "$(app_url)/healthz" 2>/dev/null; then
  ok "El servidor responde en $(app_url)"
else
  err "El servidor no responde"; HEALTHY=0
fi

TUNNEL_DOMAIN="$(current_tunnel_domain 2>/dev/null || true)"
LOCAL_UUID="$(current_tunnel_uuid 2>/dev/null || true)"
if [ -n "$TUNNEL_DOMAIN" ]; then
  CODE="$(http_code "https://$TUNNEL_DOMAIN/healthz" 12)"
  [ "$CODE" = "200" ] && ok "$TUNNEL_DOMAIN responde desde internet" \
                      || { err "$TUNNEL_DOMAIN devolvió HTTP $CODE"; HEALTHY=0; }
fi

if [ "$HEALTHY" -eq 0 ]; then
  echo ""
  err "La versión nueva no está sana. NO es momento de limpiar."
  info "Arreglala primero, o volvé atrás con: ./deploy.sh --rollback"
  echo ""
  [ "$LIST_ONLY" -eq 0 ] && exit 1
fi

# ===========================================================================
step "Qué hay para limpiar"
# ===========================================================================
hr

# --- Servicio y carpeta viejos --------------------------------------------
OLD_DIR=""
[ -f "$APP_DIR/.snapshot/state" ] && OLD_DIR="$(grep -m1 '^OLD_DIR=' "$APP_DIR/.snapshot/state" | cut -d= -f2-)"

HAS_OLD_SVC=0; HAS_OLD_DIR=0
if pm2_exists sentinel-server; then
  HAS_OLD_SVC=1
  echo -e "  ${BOLD}Servicio pm2 viejo${N}"
  echo -e "    · sentinel-server ${D}($(pm2_status sentinel-server))${N}"
fi
if [ -n "$OLD_DIR" ] && [ -d "$OLD_DIR" ]; then
  HAS_OLD_DIR=1
  echo -e "  ${BOLD}Carpeta de la versión anterior${N}"
  echo -e "    · $OLD_DIR ${D}($(du -sh "$OLD_DIR" 2>/dev/null | cut -f1))${N}"
fi

# --- Túneles ---------------------------------------------------------------
ROWS=""
if command -v cloudflared >/dev/null 2>&1 && tunnel_logged_in; then
  ROWS="$(tunnel_rows)"
  if [ -n "$ROWS" ]; then
    echo -e "  ${BOLD}Túneles en la cuenta de Cloudflare${N}"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      U="$(echo "$line" | awk '{print $1}')"
      NAME="$(echo "$line" | awk '{print $2}')"
      CONN="$(echo "$line" | awk '{print $4}')"
      if [ "$U" = "$LOCAL_UUID" ]; then
        echo -e "    ${G}· $NAME${N}  ${G}EN USO POR ESTE EQUIPO — protegido${N}"
      elif [ -z "$CONN" ]; then
        echo -e "    ${Y}· $NAME${N}  ${D}(sin conexiones)${N}"
      else
        echo -e "    · $NAME  ${D}(conectado desde otro equipo)${N}"
      fi
    done <<< "$ROWS"
  fi
fi

# --- Backups ---------------------------------------------------------------
BACKUPS="$(ls -1 "$HOME"/sentinel-backup-*.tar.gz "$HOME"/cloudflared-backup-*.tar.gz 2>/dev/null || true)"
if [ -n "$BACKUPS" ]; then
  echo -e "  ${BOLD}Backups${N}"
  echo "$BACKUPS" | while IFS= read -r b; do
    echo -e "    · $(basename "$b") ${D}($(du -h "$b" | cut -f1))${N}"
  done
fi
hr

if [ "$LIST_ONLY" -eq 1 ]; then
  echo ""
  info "Modo lista: no se borró nada."
  info "Para limpiar: ./cleanup_old.sh"
  echo ""
  exit 0
fi

echo ""
echo -e "  ${Y}${BOLD}Después de limpiar, ./deploy.sh --rollback deja de funcionar.${N}"
echo ""

# ===========================================================================
#  1. SERVICIO Y CARPETA VIEJOS
# ===========================================================================
if [ "$DO_CODE" -eq 1 ] && { [ "$HAS_OLD_SVC" -eq 1 ] || [ "$HAS_OLD_DIR" -eq 1 ]; }; then
  step "Versión anterior"

  if [ "$HAS_OLD_SVC" -eq 1 ] && confirm "¿Quitar el servicio pm2 'sentinel-server'?" "s"; then
    pm2 delete sentinel-server >/dev/null 2>&1 && ok "sentinel-server eliminado de pm2"
    pm2 save >/dev/null 2>&1
  fi

  if [ "$HAS_OLD_DIR" -eq 1 ]; then
    echo ""
    info "Carpeta: $OLD_DIR"
    info "Tenés el backup en ~/sentinel-backup-*.tar.gz"
    if confirm "¿Borrar la carpeta de la versión anterior?" "n"; then
      require_typed BORRAR "Escribí"
      rm -rf "${OLD_DIR:?}" && ok "Carpeta borrada" || err "No se pudo borrar"
    else
      info "Se conserva"
    fi
  fi

  # Entradas de autostart archivadas
  A="$HOME/.config/autostart"
  OLD_AUTO="$(ls -1 "$A"/sentinel.desktop.pre-deploy-* "$A"/*.bak-* 2>/dev/null || true)"
  if [ -n "$OLD_AUTO" ] && confirm "¿Borrar los autostart viejos archivados?" "s"; then
    echo "$OLD_AUTO" | xargs -r rm -f && ok "Autostart viejos borrados"
  fi
fi

# ===========================================================================
#  2. TÚNELES
# ===========================================================================
if [ "$DO_TUNNELS" -eq 1 ] && [ -n "$ROWS" ]; then
  step "Túneles de Cloudflare"

  echo -e "  ${G}El túnel de este equipo está protegido:${N}"
  echo -e "    $(tunnel_name_of "$LOCAL_UUID")  →  $TUNNEL_DOMAIN"
  echo ""
  info "Sólo se ofrecen para borrar los que NO usa este equipo."
  echo ""

  CANDIDATES="$(echo "$ROWS" | awk -v u="$LOCAL_UUID" '$1 != u {print $2}')"
  if [ -z "$CANDIDATES" ]; then
    ok "No hay túneles de sobra"
  else
    while IFS= read -r NAME; do
      [ -z "$NAME" ] && continue
      echo ""
      echo -e "  ${BOLD}$NAME${N}"

      # ¿Alguien lo está usando? Un túnel conectado casi seguro sirve otro sitio.
      UUID_C="$(tunnel_uuid_of "$NAME")"
      CONN="$(echo "$ROWS" | awk -v n="$NAME" '$2 == n {print $4}')"
      if [ -n "$CONN" ]; then
        warn "Tiene conexiones activas: lo está usando OTRO equipo."
        info "Borrarlo deja ese sitio sin webhook."
      else
        info "Sin conexiones activas."
      fi

      if confirm "¿Borrar el túnel '$NAME'?" "n"; then
        require_typed "$NAME" "Para confirmar, escribí el nombre completo"
        if cloudflared tunnel delete -f "$NAME" 2>&1 | sed 's/^/      /'; then
          ok "'$NAME' borrado"
          info "Acordate de sacar el CNAME huérfano en Cloudflare → DNS → Records"
        else
          err "No se pudo borrar '$NAME'"
          info "Un túnel con conexiones activas no se deja borrar."
          info "Hay que parar cloudflared en el equipo que lo usa."
        fi
      else
        info "Se conserva"
      fi
    done <<< "$CANDIDATES"
  fi
fi

# ===========================================================================
#  3. BACKUPS
# ===========================================================================
if [ -n "$BACKUPS" ]; then
  step "Backups"
  info "Son tu red de seguridad. Borralos sólo si ya pasó tiempo suficiente."
  if confirm "¿Borrar los backups de migraciones anteriores?" "n"; then
    echo "$BACKUPS" | xargs -r rm -f && ok "Backups borrados"
  else
    info "Se conservan"
  fi
fi

# ===========================================================================
step "Estado final"
# ===========================================================================
checks_pass=0
pm2 list --no-color 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/  /'
echo ""
if command -v cloudflared >/dev/null 2>&1 && tunnel_logged_in; then
  echo -e "  ${BOLD}Túneles restantes:${N}"
  tunnel_rows | awk '{printf "    %-34s %s\n", $2, ($4 == "" ? "(sin conexiones)" : "conectado")}'
  echo ""
fi

# El snapshot ya no sirve: la vuelta atrás dejó de ser posible
if [ -d "$APP_DIR/.snapshot" ] && [ "$HAS_OLD_DIR" -eq 1 ] && [ ! -d "${OLD_DIR:-/nonexistent}" ]; then
  rm -rf "$APP_DIR/.snapshot"
  info "Snapshot de rollback eliminado (ya no hay a dónde volver)"
fi

echo ""
hr
echo -e "  ${G}${BOLD}Limpieza terminada.${N}"
hr
echo ""
echo -e "  ${B}./sentinel status${N}    ${D}confirmar que todo sigue bien${N}"
echo ""
