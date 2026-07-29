#!/usr/bin/env bash
# =============================================================================
#  SENTINEL · INSTALACIÓN DESDE CERO
#
#  Para una Raspberry Pi 5 recién formateada con Raspberry Pi OS (Bookworm).
#
#      ./install.sh                 asistente completo
#      ./install.sh --reconfigure   sólo el asistente, sin tocar paquetes
#      ./install.sh --skip-apt      no instalar paquetes del sistema
#
#  Para migrar un equipo que ya tiene la versión anterior, usá ./deploy.sh
# =============================================================================
set -uo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$APP_DIR/lib/common.sh"
# shellcheck source=lib/checks.sh
. "$APP_DIR/lib/checks.sh"

SKIP_APT=0; RECONFIGURE=0
for arg in "$@"; do
  case "$arg" in
    --skip-apt)    SKIP_APT=1 ;;
    --reconfigure) RECONFIGURE=1; SKIP_APT=1 ;;
    -h|--help)     sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "Opción desconocida: $arg" ;;
  esac
done

# Defaults: el script corre con `set -u`, así que toda variable usada en el
# resumen tiene que existir aunque se saltee su sección.
SITE_NAME=""; SITE_SLUG=""; DEFAULT_DOMAIN=""; APP_PORT=3000; AUTH_USER=Bunker; AUTH_PASSWORD=""
VERKADA_SECRET=""; TUNNEL_ENABLED=0; TUNNEL_DOMAIN=""; TUNNEL_NAME=""; TUNNEL_OK=0
KIOSK_ENABLED=0; KIOSK_ID=""; SCREEN_ROTATION=0; ROT_LABEL="sin rotación"
GPIO_ENABLED=false
CAM_IDS=(); CAM_NAMES=(); CAM_ZONES=(); CAM_URLS=(); CAM_DEVICES=()

clear 2>/dev/null || true
echo -e "${B}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║                                                          ║
  ║     ███████ ███████ ███    ██ ████████ ██ ███    ██      ║
  ║     ██      ██      ████   ██    ██    ██ ████   ██      ║
  ║     ███████ █████   ██ ██  ██    ██    ██ ██ ██  ██      ║
  ║          ██ ██      ██  ██ ██    ██    ██ ██  ██ ██      ║
  ║     ███████ ███████ ██   ████    ██    ██ ██   ████      ║
  ║                                                          ║
  ║              Instalación desde cero                      ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${N}"

# ===========================================================================
step "Verificaciones previas"
# ===========================================================================
require_not_root
require_app_dir
ok "Carpeta: $APP_DIR"
ok "Usuario: $(whoami)"
fix_line_endings

if [ -f /etc/os-release ]; then . /etc/os-release; ok "Sistema: ${PRETTY_NAME:-?}"; fi
is_raspberry_pi && ok "Hardware: $(pi_model)" \
                || warn "No parece una Raspberry Pi. Los flags de Chromium están afinados para RPi."

command -v apt-get >/dev/null 2>&1 || die "Se necesita un sistema con apt (Debian / Raspberry Pi OS)."

ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 deb.debian.org >/dev/null 2>&1 \
  && ok "Conexión a internet" || warn "Sin internet. Si faltan paquetes, va a fallar."

echo ""
info "Se necesita sudo para instalar paquetes del sistema."
keep_sudo_alive

# ===========================================================================
if [ "$SKIP_APT" -eq 0 ]; then
step "Paquetes del sistema"
info "Puede tardar varios minutos la primera vez."
echo ""
sudo apt-get update -qq 2>&1 | tail -2

PACKAGES=(
  ffmpeg            # transcodificación RTSP
  curl ca-certificates git
  python3 python3-pip
  python3-serial    # comunicación con el Arduino
  lsof              # detección de puertos ocupados
  netcat-openbsd    # ping al daemon de luces
  dnsutils          # dig, para verificar el DNS del túnel
  unclutter         # ocultar el cursor en el kiosko
  x11-xserver-utils # xset
  wlr-randr         # rotación de pantalla en Wayland
  fonts-dejavu-core # tipografías (funciona sin internet)
)
for pkg in "${PACKAGES[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "$pkg ${D}(ya estaba)${N}"
  else
    printf "  … %s" "$pkg"
    sudo apt-get install -y -qq "$pkg" >/dev/null 2>&1 \
      && printf "\r  ${G}✔${N} %s%*s\n" "$pkg" 24 "" \
      || printf "\r  ${Y}!${N} %s (no se pudo)%*s\n" "$pkg" 14 ""
  fi
done

if command -v chromium-browser >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1; then
  ok "chromium ${D}(ya estaba)${N}"
else
  for p in chromium-browser chromium; do
    sudo apt-get install -y -qq "$p" >/dev/null 2>&1 && { ok "$p"; break; }
  done
fi

step "Node.js"
NEED_NODE=1
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -v | sed 's/v\([0-9]*\).*/\1/')"
  [ "$NODE_MAJOR" -ge 18 ] && { ok "Node.js $(node -v)"; NEED_NODE=0; } \
                           || warn "Node.js $(node -v) es muy viejo, se actualiza"
fi
if [ "$NEED_NODE" -eq 1 ]; then
  info "Instalando Node.js 20 LTS..."
  if curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1 \
     && sudo apt-get install -y -qq nodejs >/dev/null 2>&1; then
    ok "Node.js $(node -v)"
  else
    sudo apt-get install -y -qq nodejs npm >/dev/null 2>&1
    command -v node >/dev/null 2>&1 || die "No se pudo instalar Node.js."
    [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -ge 18 ] || die "La distro trae Node $(node -v), muy viejo.
    Instalá Node 20 desde https://nodejs.org y volvé a correr esto."
    ok "Node.js $(node -v)"
  fi
fi

step "pm2"
has_pm2 && ok "pm2 $(pm2 -v 2>/dev/null)" || {
  sudo npm install -g pm2 --silent >/dev/null 2>&1 && ok "pm2 $(pm2 -v 2>/dev/null)" \
    || die "No se pudo instalar pm2. Probá: sudo npm install -g pm2"
}
fi  # SKIP_APT

# ===========================================================================
step "Asistente de configuración"
# ===========================================================================
hr
info "Contestá las preguntas. Enter acepta el valor entre corchetes."
hr
echo ""

# ---------------------------------------------------------------------------
# UN SOLO NOMBRE
#
# Antes esto preguntaba cinco nombres distintos (sitio, cámara, identificador,
# dominio, túnel) y era imposible saber cuál era cuál. Ahora se pregunta uno y
# se deriva el resto: en el 99% de los casos son todos lo mismo escrito de
# formas distintas.
# ---------------------------------------------------------------------------
echo -e "  ${BOLD}¿Cómo se llama este equipo?${N}"
info "Es lo que vas a ver en el tablero. Ej: Catamarca · Costa Esmeralda · Planta Baja"
echo ""
while true; do
  ask SITE_NAME "Nombre"
  SITE_SLUG="$(slugify "$SITE_NAME")"
  [ -n "$SITE_SLUG" ] && break
  err "Necesito al menos una letra o número."
done

DEFAULT_DOMAIN="sentinel-${SITE_SLUG}.ihtechlabs.com"

echo ""
info "Con ese nombre configuro:"
echo ""
printf "    %-26s ${BOLD}%s${N}\n" "En el tablero se ve"  "$SITE_NAME"
printf "    %-26s ${BOLD}%s${N}\n" "Identificador interno" "$SITE_SLUG"
printf "    %-26s ${BOLD}%s${N}\n" "Dominio para el túnel"  "$DEFAULT_DOMAIN"
echo ""
info "El identificador interno va en la URL del kiosko y no conviene cambiarlo"
info "después. El nombre visible sí lo podés cambiar cuando quieras."
echo ""

# Puerto: si el 3000 está libre no molestamos con la pregunta
APP_PORT=3000
OCCUPANT="$(sudo lsof -ti :3000 2>/dev/null | head -1)"
if [ -n "$OCCUPANT" ]; then
  echo ""
  warn "El puerto 3000 está ocupado por PID $OCCUPANT ($(ps -p "$OCCUPANT" -o comm= 2>/dev/null))"
  if ! confirm "¿Usarlo igual? (se libera más adelante)" "s"; then
    while true; do
      ask APP_PORT "Puerto alternativo" "3001"
      valid_port "$APP_PORT" || { err "Entre 1024 y 65535."; continue; }
      break
    done
  fi
fi

echo ""
hr; echo -e "  ${BOLD}Acceso al tablero${N}"; hr
ask AUTH_USER "Usuario" "Bunker"
info "Contraseña sugerida: !BunkerCE2026 (mínimo 8 caracteres)"
ask_secret AUTH_PASSWORD "Contraseña" "!BunkerCE2026"
ok "Credenciales registradas"

# --- Cámaras -------------------------------------------------------------
echo ""
hr; echo -e "  ${BOLD}Cámaras${N}"; hr
info "La mayoría de las instalaciones usan UNA cámara."
info ""
info "Formatos típicos de URL RTSP:"
info "  Verkada    rtsp://usuario:clave@HOST.camera.verkada-lan.com:8554/standard"
info "  Hikvision  rtsp://usuario:clave@192.168.1.50:554/Streaming/Channels/102"
info "  Dahua      rtsp://usuario:clave@192.168.1.50:554/cam/realmonitor?channel=1&subtype=1"
info "  Axis       rtsp://usuario:clave@192.168.1.50:554/axis-media/media.amp"
info ""
info "Usá el substream si existe: consume una fracción del CPU."
echo ""

CAM_INDEX=0
while true; do
  CAM_INDEX=$((CAM_INDEX + 1))

  # La primera cámara hereda el nombre del equipo: en una instalación de una
  # sola cámara, "el equipo" y "la cámara" son la misma cosa y preguntarlo dos
  # veces sólo genera dudas sobre cuál es cuál.
  if [ "$CAM_INDEX" -eq 1 ]; then
    CAM_NAME="$SITE_NAME"
    CAM_ID="$SITE_SLUG"
    CAM_ZONE="—"
    echo -e "  ${B}${BOLD}── Cámara ──${N}"
    info "Se llama \"$CAM_NAME\" y su kiosko es /kiosk/?id=$CAM_ID"
    info "(igual que el equipo — si querés otro nombre, lo cambiás después"
    info " en config/cameras.json sin romper nada)"
    echo ""
  else
    echo -e "  ${B}${BOLD}── Cámara $CAM_INDEX ──${N}"
    ask CAM_NAME "Nombre visible"
    SUGGESTED="$(slugify "$CAM_NAME")"; [ -z "$SUGGESTED" ] && SUGGESTED="cam$CAM_INDEX"
    while true; do
      ask CAM_ID "Identificador corto (va en la URL del kiosko)" "$SUGGESTED"
      CAM_ID="$(echo "$CAM_ID" | tr '[:upper:]' '[:lower:]')"
      valid_slug "$CAM_ID" || { err "Sólo minúsculas, números, guiones y guiones bajos."; continue; }
      DUP=0; for e in ${CAM_IDS[@]+"${CAM_IDS[@]}"}; do [ "$e" = "$CAM_ID" ] && DUP=1; done
      [ "$DUP" -eq 1 ] && { err "Ese identificador ya lo usaste."; continue; }
      break
    done
    ask CAM_ZONE "Zona o ubicación (opcional)" "—"
  fi

  while true; do
    ask CAM_URL "URL RTSP"
    if ! echo "$CAM_URL" | grep -qE '^rtsps?://'; then
      warn "Debería empezar con rtsp:// o rtsps://"
      confirm "¿Usarla igual?" "n" && break || continue
    fi
    info "Probando la cámara (hasta 15 s)..."
    PROBE="$(timeout 15 ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
             -show_entries stream=codec_name,width,height,avg_frame_rate \
             -of default=noprint_wrappers=1:nokey=1 "$CAM_URL" 2>/dev/null | tr '\n' ' ')"
    if [ -n "$PROBE" ]; then
      set -- $PROBE
      ok "Cámara OK · ${2:-?}x${3:-?} · ${1:-?} · ${4:-?} fps"
      [ "${2:-0}" -gt 1280 ] 2>/dev/null && warn "Resolución alta: si hay substream, conviene usarlo."
      break
    fi
    err "No hubo respuesta de esa URL."
    info "Causas típicas: credenciales incorrectas, la cámara no está en esta red,"
    info "el puerto no es 554/8554, o la ruta del stream es otra."
    echo -e "    ${BOLD}1${N}) Corregir  ${BOLD}2${N}) Usarla igual  ${BOLD}3${N}) Saltear"
    read -r -p "    Opción [1]: " RETRY
    case "${RETRY:-1}" in
      2) warn "Se guarda sin validar"; break ;;
      3) CAM_URL=""; break ;;
      *) continue ;;
    esac
  done

  echo ""
  info "El device_id de Verkada vincula esta cámara con las alarmas del webhook."
  info "Si no lo tenés, lo completás después mirando 'sentinel logs server'."
  ask CAM_DEVICE_INPUT "device_id de Verkada (Enter para omitir)" "—"
  [ "$CAM_DEVICE_INPUT" = "—" ] && CAM_DEVICE="" || CAM_DEVICE="$CAM_DEVICE_INPUT"

  CAM_IDS+=("$CAM_ID"); CAM_NAMES+=("$CAM_NAME")
  CAM_ZONES+=("$([ "$CAM_ZONE" = "—" ] && echo "" || echo "$CAM_ZONE")")
  CAM_URLS+=("$CAM_URL"); CAM_DEVICES+=("$CAM_DEVICE")
  ok "\"$CAM_NAME\" agregada como '$CAM_ID'"
  echo ""
  confirm "¿Agregar otra cámara?" "n" || break
  echo ""
done
ok "${#CAM_IDS[@]} cámara(s) configurada(s)"

# --- Verkada + túnel ------------------------------------------------------
echo ""
hr; echo -e "  ${BOLD}Verkada${N}"; hr
info "El shared secret valida la firma HMAC de las alarmas."
info "Está en Verkada Command → Admin → Webhooks."
echo ""
ask VERKADA_SECRET "Shared secret (Enter para omitir)" "—"
[ "$VERKADA_SECRET" = "—" ] && VERKADA_SECRET=""
[ -n "$VERKADA_SECRET" ] && ok "Webhook habilitado" \
  || warn "Sin secret: el webhook rechaza todo hasta cargarlo en .env"

echo ""
hr; echo -e "  ${BOLD}Acceso desde internet${N}"; hr
info "Verkada es un servicio en la nube: para mandarte alarmas necesita llegar"
info "a este equipo DESDE INTERNET. Una IP de red local no le sirve."
echo ""
if confirm "¿Configurar un túnel de Cloudflare?" "s"; then
  . "$APP_DIR/lib/tunnel.sh"

  # Si ya hay túneles en la cuenta, los mostramos: evita crear un duplicado
  # sin darse cuenta, que es exactamente lo que pasa cuando uno escribe el
  # dominio apenas distinto (con guión, sin guión...).
  if tunnel_logged_in; then
    EXISTING="$(tunnel_rows 2>/dev/null || true)"
    if [ -n "$EXISTING" ]; then
      info "Túneles que ya existen en tu cuenta de Cloudflare:"
      echo "$EXISTING" | awk '{printf "    · %-34s %s\n", $2, ($4 == "" ? "(sin conexiones)" : "conectado")}'
      echo ""
      info "Si el de este equipo ya está en la lista, usá su mismo dominio:"
      info "se reutiliza en vez de crear uno nuevo."
      echo ""
    fi
  fi

  while true; do
    ask TUNNEL_DOMAIN "Dominio para este equipo" "$DEFAULT_DOMAIN"
    valid_hostname "$TUNNEL_DOMAIN" || { err "No es un dominio válido."; continue; }
    if [ "$(echo "$TUNNEL_DOMAIN" | tr -cd '.' | wc -c)" -gt 2 ]; then
      warn "Más de un nivel de subdominio: el certificado gratuito de Cloudflare"
      warn "cubre *.dominio.com pero no a.b.dominio.com"
      confirm "¿Usarlo igual?" "n" || continue
    fi
    break
  done

  # El nombre del túnel se deriva del dominio: es sólo una etiqueta interna y
  # preguntarlo era una fuente de confusión más.
  TUNNEL_NAME="$(tunnel_name_from_domain "$TUNNEL_DOMAIN")"
  TUNNEL_ENABLED=1
  echo ""
  ok "Túnel: ${BOLD}$TUNNEL_NAME${N} → ${BOLD}$TUNNEL_DOMAIN${N}"
  if [ -n "$(tunnel_uuid_of "$TUNNEL_NAME" 2>/dev/null)" ]; then
    info "Ese túnel ya existe: se reutiliza, no se crea otro."
  fi
  echo -e "  ${D}Tablero : https://$TUNNEL_DOMAIN/backoffice/${N}"
  echo -e "  ${D}Webhook : https://$TUNNEL_DOMAIN/verkada-webhook${N}"
else
  warn "Sin túnel: Verkada no va a poder mandar alarmas"
  info "Podés configurarlo después: sentinel tunnel setup <dominio>"
fi

# --- Kiosko ---------------------------------------------------------------
echo ""
hr; echo -e "  ${BOLD}Kiosko${N}"; hr
if confirm "¿Este equipo tiene una pantalla que muestre el kiosko?" "s"; then
  KIOSK_ENABLED=1
  if [ "${#CAM_IDS[@]}" -eq 1 ]; then
    KIOSK_ID="${CAM_IDS[0]}"
  else
    echo ""
    for i in "${!CAM_IDS[@]}"; do echo -e "    ${BOLD}${CAM_IDS[$i]}${N} · ${CAM_NAMES[$i]}"; done
    echo ""
    while true; do
      ask KIOSK_ID "¿Qué puesto muestra esta pantalla?" "${CAM_IDS[0]}"
      FOUND=0; for e in "${CAM_IDS[@]}"; do [ "$e" = "$KIOSK_ID" ] && FOUND=1; done
      [ "$FOUND" -eq 1 ] && break
      err "Ese puesto no existe."
    done
  fi

  echo ""
  info "Si la pantalla está montada en vertical, hay que rotar la salida."
  echo -e "    ${BOLD}1${N}) 90° horario   ${BOLD}2${N}) 90° antihorario   ${BOLD}3${N}) 180°   ${BOLD}4${N}) sin rotación"
  read -r -p "$(echo -e "  ${BOLD}Orientación${N} ${D}[1]${N}: ")" ROT
  case "${ROT:-1}" in 1) SCREEN_ROTATION=90;; 2) SCREEN_ROTATION=270;; 3) SCREEN_ROTATION=180;; 4) SCREEN_ROTATION=0;; *) SCREEN_ROTATION=90;; esac
  case "$SCREEN_ROTATION" in 90) ROT_LABEL="90° horario";; 270) ROT_LABEL="90° antihorario";; 180) ROT_LABEL="180°";; *) ROT_LABEL="sin rotación";; esac
  info "Si queda al revés: sentinel rotate 270"
else
  warn "Sin kiosko: sólo servidor y backoffice"
  KIOSK_ID="${CAM_IDS[0]}"
fi

# --- Arduino --------------------------------------------------------------
echo ""
hr; echo -e "  ${BOLD}Control de luces${N}"; hr
if confirm "¿Hay un Arduino conectado por USB?" "s"; then
  GPIO_ENABLED=true
  DETECTED="$(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | head -1)"
  [ -n "$DETECTED" ] && ok "Detectado en $DETECTED" \
    || warn "No detecté ningún puerto serie ahora. El daemon se reconecta solo al enchufarlo."
  groups | grep -qw dialout && ok "Usuario ya está en el grupo dialout" || {
    sudo usermod -aG dialout "$(whoami)" && ok "Usuario agregado al grupo dialout"
    warn "Aplica al próximo reinicio"
  }
else
  warn "Control de luces deshabilitado"
fi

# ===========================================================================
step "Resumen"
# ===========================================================================
hr
printf "  %-17s ${BOLD}%s${N}\n" "Sitio"      "$SITE_NAME"
printf "  %-17s ${BOLD}%s${N}\n" "Puerto"     "$APP_PORT"
printf "  %-17s ${BOLD}%s${N}\n" "Usuario"    "$AUTH_USER"
printf "  %-17s ${BOLD}%s${N}\n" "Cámaras"    "${#CAM_IDS[@]}"
for i in "${!CAM_IDS[@]}"; do
  echo -e "    ${D}· ${CAM_IDS[$i]} — ${CAM_NAMES[$i]}${N}"
  echo -e "      ${D}$(mask_url "${CAM_URLS[$i]:-sin URL}")${N}"
done
printf "  %-17s ${BOLD}%s${N}\n" "Webhook"    "$([ -n "$VERKADA_SECRET" ] && echo sí || echo no)"
printf "  %-17s ${BOLD}%s${N}\n" "Túnel"      "$([ "$TUNNEL_ENABLED" -eq 1 ] && echo "sí ($TUNNEL_DOMAIN)" || echo no)"
printf "  %-17s ${BOLD}%s${N}\n" "Kiosko"     "$([ "$KIOSK_ENABLED" -eq 1 ] && echo "sí ($KIOSK_ID · $ROT_LABEL)" || echo no)"
printf "  %-17s ${BOLD}%s${N}\n" "Luces"      "$([ "$GPIO_ENABLED" = true ] && echo sí || echo no)"
hr

# Última red de seguridad: aunque `ask` ya limpia, revisamos antes de escribir
# a disco. Un byte invisible en un hostname o una URL rompe mucho más adelante.
DIRTY=0
check_clean() {
  if printf '%s' "$2" | LC_ALL=C grep -q '[^[:print:]]' 2>/dev/null; then
    err "$1 contiene caracteres no imprimibles:"
    printf '%s' "$2" | od -c | head -2 | sed 's/^/      /'
    DIRTY=1
  fi
}
check_clean "El nombre del sitio" "$SITE_NAME"
check_clean "El usuario" "$AUTH_USER"
[ -n "$VERKADA_SECRET" ] && check_clean "El secret de Verkada" "$VERKADA_SECRET"
[ "$TUNNEL_ENABLED" -eq 1 ] && check_clean "El dominio del túnel" "$TUNNEL_DOMAIN"
for i in "${!CAM_IDS[@]}"; do
  check_clean "El id ${CAM_IDS[$i]}" "${CAM_IDS[$i]}"
  check_clean "La URL de ${CAM_IDS[$i]}" "${CAM_URLS[$i]}"
done
[ "$DIRTY" -eq 1 ] && {
  echo ""
  warn "Hay caracteres invisibles en algún campo (¿backspace por SSH?)."
  info "Cancelá con 'n' y volvé a correr el instalador."
  echo ""
}

echo ""
confirm "¿Confirmás e instalo?" "s" || die "Cancelado. No se escribió nada."

# ===========================================================================
step "Dependencias de Node"
# ===========================================================================
cd "$APP_DIR"
npm install --omit=dev --no-audit --no-fund 2>&1 | tail -3 || die "Falló npm install"
ok "Paquetes instalados"
for f in src/*.js; do node --check "$f" >/dev/null 2>&1 || die "Error de sintaxis en $f"; done
ok "Código verificado"

# ===========================================================================
step "Escribiendo configuración"
# ===========================================================================
mkdir -p "$CONFIG_DIR" "$DATA_DIR"
[ -f "$CAMERAS_JSON" ] && { cp "$CAMERAS_JSON" "$CAMERAS_JSON.bak-$(date +%Y%m%d-%H%M%S)"; warn "cameras.json anterior respaldado"; }
[ -f "$ENV_FILE" ]     && { cp "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"; warn ".env anterior respaldado"; }

# El JSON lo genera node, no un heredoc: las URLs RTSP traen &, ?, comillas y
# demás caracteres que romperían el archivo si se interpolaran a mano.
export SENTINEL_SITE="$SITE_NAME"
SEP=$'\x1f'; PAYLOAD=""
for i in "${!CAM_IDS[@]}"; do
  PAYLOAD+="${CAM_IDS[$i]}${SEP}${CAM_NAMES[$i]}${SEP}${CAM_ZONES[$i]}${SEP}${CAM_URLS[$i]}${SEP}${CAM_DEVICES[$i]}"$'\x1e'
done
export SENTINEL_CAMS="$PAYLOAD"
node -e '
const fs = require("fs");
const SEP = "\x1f", ROW = "\x1e";
const cameras = (process.env.SENTINEL_CAMS || "").split(ROW).filter(Boolean).map((row) => {
  const [id, name, zone, rtspUrl, deviceId] = row.split(SEP);
  return { deviceId: deviceId || null, id, name, shortName: id.toUpperCase().slice(0, 12),
           zone: zone || "", rtspUrl: rtspUrl || null, triggerVideo: true, sound: true,
           allowedEvents: ["alert_rule_line_crossing", "alert_rule_motion"] };
});
fs.writeFileSync(process.argv[1], JSON.stringify({ site: process.env.SENTINEL_SITE || "Sentinel", cameras }, null, 2) + "\n");
' "$CAMERAS_JSON" || die "No se pudo escribir cameras.json"
chmod 600 "$CAMERAS_JSON"
ok "config/cameras.json ${D}(las URLs RTSP viven acá)${N}"

# src/hash.js no depende de npm: funciona aunque todavía no se haya corrido
# `npm install`. Antes esto usaba src/auth.js, que arrastra config.js -> dotenv,
# y la instalación se moría acá con "Cannot find module 'dotenv'".
AUTH_HASH="$(node -e '
  const { hashPassword } = require(process.argv[1]);
  process.stdout.write(hashPassword(process.argv[2]));
' "$APP_DIR/src/hash.js" "$AUTH_PASSWORD")" || die "No se pudo generar el hash"
[ -n "$AUTH_HASH" ] || die "El hash salió vacío"
SESSION_SECRET="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"

cat > "$ENV_FILE" <<EOF
# ===========================================================================
# Sentinel · configuración
# Generado por install.sh el $(date '+%Y-%m-%d %H:%M:%S')
#
# Las URLs RTSP NO están acá: van en config/cameras.json
# ===========================================================================

PORT=$APP_PORT
HOST=0.0.0.0

# --- Acceso al backoffice --------------------------------------------------
# Para cambiar la contraseña:  sentinel password
AUTH_USER=$AUTH_USER
AUTH_HASH=$AUTH_HASH
SESSION_SECRET=$SESSION_SECRET
SESSION_HOURS=12
LOGIN_MAX_ATTEMPTS=8
LOGIN_LOCKOUT_MIN=10

# true SÓLO si accedés exclusivamente por HTTPS.
# Con true, el login por http://localhost deja de funcionar.
SECURE_COOKIE=false
TRUST_PROXY=true

# --- Verkada ---------------------------------------------------------------
VERKADA_SHARED_SECRET=$VERKADA_SECRET
WEBHOOK_TOLERANCE_S=120

# --- Streams RTSP ----------------------------------------------------------
# on-demand: ffmpeg sólo corre mientras alguien mira el backoffice.
# En una RPi 5 es la diferencia entre ~60% de CPU permanente y ~3%.
STREAM_ON_DEMAND=true
STREAM_IDLE_TIMEOUT_S=25
STREAM_WIDTH=640
STREAM_HEIGHT=360
STREAM_FPS=12
STREAM_BITRATE=450k

# --- Historial de eventos --------------------------------------------------
EVENTS_MEMORY_LIMIT=200
EVENTS_FILE_MAX_MB=5

# --- Control de luces ------------------------------------------------------
GPIO_ENABLED=$GPIO_ENABLED
GPIO_HOST=127.0.0.1
GPIO_PORT=8765

# --- Telemetría ------------------------------------------------------------
HEALTH_INTERVAL_S=5
EOF
chmod 600 "$ENV_FILE"
ok ".env ${D}(contraseña hasheada, nunca en texto plano)${N}"
unset SENTINEL_CAMS SENTINEL_SITE

# ===========================================================================
step "Servicios"
# ===========================================================================
pm2 delete sentinel      >/dev/null 2>&1 && warn "Servicio anterior reemplazado" || true
pm2 delete sentinel-gpio >/dev/null 2>&1 || true

PIDS="$(sudo lsof -ti :"$APP_PORT" 2>/dev/null || true)"
[ -n "$PIDS" ] && { echo "$PIDS" | xargs -r sudo kill -TERM 2>/dev/null; sleep 2; warn "Puerto $APP_PORT liberado"; }

if [ "$GPIO_ENABLED" = true ] && python3 -c "import serial" 2>/dev/null; then
  pm2 start "$APP_DIR/scripts/gpio_daemon.py" --name sentinel-gpio \
    --interpreter python3 --restart-delay 5000 >/dev/null 2>&1 \
    && ok "Daemon de luces activo" || warn "No arrancó el daemon de luces"
fi

pm2 start "$APP_DIR/src/server.js" --name sentinel --cwd "$APP_DIR" \
  --max-memory-restart 400M --restart-delay 3000 --time >/dev/null 2>&1 \
  || die "No se pudo iniciar el servidor"
ok "Servidor iniciado"

pm2 save >/dev/null 2>&1
STARTUP="$(pm2 startup 2>/dev/null | grep -E '^sudo ' | tail -1)"
if [ -n "$STARTUP" ]; then
  eval "$STARTUP" >/dev/null 2>&1 && { pm2 save >/dev/null 2>&1; ok "Arranque automático configurado"; } \
    || { warn "Ejecutá a mano:"; echo -e "       ${Y}$STARTUP${N}"; }
else
  ok "pm2 ya arranca con el sistema"
fi

# ===========================================================================
if [ "$KIOSK_ENABLED" -eq 1 ]; then
step "Kiosko"
chmod +x "$APP_DIR"/*.sh "$APP_DIR/sentinel" 2>/dev/null || true
AUTOSTART="$HOME/.config/autostart"
mkdir -p "$AUTOSTART"
for OLD in "$AUTOSTART"/sentinel*.desktop; do
  [ -f "$OLD" ] && mv "$OLD" "$OLD.bak-$(date +%Y%m%d-%H%M%S)" && warn "Autostart anterior archivado"
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
ok "Autostart configurado (puesto: $KIOSK_ID)"

if [ "$SCREEN_ROTATION" != "0" ]; then
  . "$APP_DIR/lib/screen.sh"
  screen_rotate "$SCREEN_ROTATION" 2>&1 | sed 's/^/  /'
fi
fi

# ===========================================================================
if [ "$TUNNEL_ENABLED" -eq 1 ]; then
step "Túnel de Cloudflare"
. "$APP_DIR/lib/tunnel.sh"
tunnel_setup "$TUNNEL_DOMAIN" "$TUNNEL_NAME" && TUNNEL_OK=1 || {
  warn "El túnel no quedó configurado."
  info "Reintentalo con: sentinel tunnel setup $TUNNEL_DOMAIN"
}
fi

# ===========================================================================
step "Verificación final"
# ===========================================================================
checks_reset
check_dependencies
check_config
check_services
check_endpoints
check_login "$AUTH_USER" "$AUTH_PASSWORD"
unset AUTH_PASSWORD
checks_summary || true

REPORT="$HOME/sentinel-instalacion-$(hostname)-$(date +%Y%m%d-%H%M%S).txt"
write_report "$REPORT" "Reporte de instalación"

# ===========================================================================
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; IP="${IP:-localhost}"
echo ""
if [ "$CHECKS_FAILED" -eq 0 ]; then
  echo -e "${G}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║              INSTALACIÓN COMPLETA                        ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${N}"
else
  warn "Instalación terminada con $CHECKS_FAILED fallo(s). Revisá arriba."
  echo ""
fi

hr; echo -e "  ${BOLD}Acceso${N}"; hr
echo -e "  Backoffice   ${B}http://$IP:$APP_PORT/backoffice/${N}"
echo -e "  Usuario      ${Y}$AUTH_USER${N}"
echo ""
if [ "$KIOSK_ENABLED" -eq 1 ]; then
  hr; echo -e "  ${BOLD}Kiosko${N}"; hr
  for i in "${!CAM_IDS[@]}"; do
    echo -e "  ${CAM_NAMES[$i]}: ${B}http://$IP:$APP_PORT/kiosk/?id=${CAM_IDS[$i]}${N}"
  done
  echo -e "  ${D}Arranca solo con '$KIOSK_ID' al reiniciar.${N}"
  echo -e "  ${D}Probarlo ahora: ${N}$APP_DIR/sentinel kiosk $KIOSK_ID"
  [ "$SCREEN_ROTATION" != "0" ] && echo -e "  ${D}¿Pantalla al revés? ${N}sentinel rotate $([ "$SCREEN_ROTATION" = "90" ] && echo 270 || echo 90)"
  echo ""
fi

hr; echo -e "  ${BOLD}Webhook de Verkada${N}"; hr
if [ "$TUNNEL_OK" -eq 1 ]; then
  echo -e "  ${B}https://$TUNNEL_DOMAIN/verkada-webhook${N}"
elif [ "$TUNNEL_ENABLED" -eq 1 ]; then
  echo -e "  ${B}https://$TUNNEL_DOMAIN/verkada-webhook${N} ${Y}(cuando el túnel funcione)${N}"
else
  echo -e "  ${Y}Este equipo no es accesible desde internet todavía.${N}"
  echo -e "  ${D}sentinel tunnel setup <dominio>${N}"
fi
[ -z "$VERKADA_SECRET" ] && echo -e "\n  ${Y}⚠ Falta VERKADA_SHARED_SECRET en .env: el webhook rechaza todo.${N}"
MISSING=0; for i in "${!CAM_IDS[@]}"; do [ -z "${CAM_DEVICES[$i]}" ] && MISSING=1; done
[ "$MISSING" -eq 1 ] && {
  echo -e "\n  ${Y}⚠ Hay cámaras sin device_id: sus alarmas se ignoran.${N}"
  echo -e "  ${D}Disparás una alarma, mirás 'sentinel logs server', copiás el ID.${N}"
}
echo ""

hr; echo -e "  ${BOLD}Operación${N}"; hr
echo -e "  ${B}sentinel status${N}      ${D}estado general${N}"
echo -e "  ${B}sentinel diagnose${N}    ${D}diagnóstico completo${N}"
echo -e "  ${B}sentinel logs${N}        ${D}ver qué está pasando${N}"
echo -e "  ${B}sentinel${N}             ${D}todos los comandos${N}"
echo ""
echo -e "  Reporte: ${B}$REPORT${N}"
echo ""
echo -e "  ${Y}Reiniciá para validar el arranque automático:${N} ${B}sudo reboot${N}"
echo ""
