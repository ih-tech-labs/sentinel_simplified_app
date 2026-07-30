#!/usr/bin/env bash
# =============================================================================
#  Sentinel · funciones compartidas
#
#  Todos los scripts hacen `source lib/common.sh`. Acá viven los helpers que
#  antes estaban duplicados en once archivos distintos — y con ellos, los bugs
#  duplicados. Cada corrección acá vale para todo el sistema.
# =============================================================================

# Idempotente: si ya se cargó, no volvemos a definir nada
[ -n "${SENTINEL_COMMON_LOADED:-}" ] && return 0
SENTINEL_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Rutas
# ---------------------------------------------------------------------------
SENTINEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SENTINEL_LIB_DIR/.." && pwd)"
ENV_FILE="$APP_DIR/.env"
CONFIG_DIR="$APP_DIR/config"
CAMERAS_JSON="$CONFIG_DIR/cameras.json"
DATA_DIR="$APP_DIR/data"

# ---------------------------------------------------------------------------
# Colores. Se desactivan solos si la salida no es una terminal, para que los
# logs redirigidos a archivo queden legibles.
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; B=$'\033[0;36m'
  BOLD=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=''; Y=''; R=''; B=''; BOLD=''; D=''; N=''
fi

ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
err()  { echo -e "  ${R}✘${N} $*"; }
info() { echo -e "  ${D}$*${N}"; }
step() { echo -e "\n${B}${BOLD}▸ $*${N}"; }
hr()   { echo -e "${D}  ────────────────────────────────────────────────────────${N}"; }
die()  { echo -e "\n${R}✘ $*${N}\n"; exit 1; }

banner() {
  echo -e "${B}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  printf "  ║  %-56s║\n" "$1"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${N}"
}

# ---------------------------------------------------------------------------
# Entrada del usuario
# ---------------------------------------------------------------------------

# Saca caracteres de control y recorta espacios.
#
# Si la tecla de borrado del terminal no coincide con lo que espera la tty
# (pasa seguido por SSH), el backspace no borra: mete un byte 0x08 o 0x7F crudo
# en la línea. `read` lo guarda igual y queda un carácter invisible en el medio
# de la variable, que después rompe un hostname o un JSON lejos de acá.
sanitize() {
  printf '%s' "$1" | tr -d '[:cntrl:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# ask <variable> <pregunta> [default]
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __input __clean
  while true; do
    if [ -n "$__default" ]; then
      read -r -p "$(echo -e "  ${BOLD}$__prompt${N} ${D}[$__default]${N}: ")" __input
      __input="${__input:-$__default}"
    else
      read -r -p "$(echo -e "  ${BOLD}$__prompt${N}: ")" __input
    fi
    __clean="$(sanitize "$__input")"
    if [ "$__clean" != "$__input" ]; then
      warn "Se limpiaron caracteres invisibles. Quedó: ${BOLD}$__clean${N}"
      info "(suele pasar cuando el backspace no borra bien por SSH)"
    fi
    [ -z "$__clean" ] && [ -z "$__default" ] && { warn "Este dato es obligatorio."; continue; }
    break
  done
  printf -v "$__var" '%s' "$__clean"
}

# ask_secret <variable> <pregunta> [default]
ask_secret() {
  local __var="$1" __prompt="$2" __default="${3:-}" __input __confirm __clean
  while true; do
    if [ -n "$__default" ]; then
      read -r -s -p "$(echo -e "  ${BOLD}$__prompt${N} ${D}[Enter = usar la sugerida]${N}: ")" __input; echo ""
      [ -z "$__input" ] && { printf -v "$__var" '%s' "$__default"; return; }
    else
      read -r -s -p "$(echo -e "  ${BOLD}$__prompt${N}: ")" __input; echo ""
      [ -z "$__input" ] && { warn "No puede quedar vacía."; continue; }
    fi
    # Acá importa más: como no se ve al tipear, un byte invisible quedaría
    # adentro sin que nadie lo note y el login fallaría siempre.
    __clean="$(printf '%s' "$__input" | tr -d '[:cntrl:]')"
    [ "$__clean" != "$__input" ] && { warn "Caracteres invisibles detectados. Escribila de nuevo."; continue; }
    [ "${#__clean}" -lt 8 ] && { warn "Mínimo 8 caracteres."; continue; }
    read -r -s -p "$(echo -e "  ${BOLD}Repetir${N}: ")" __confirm; echo ""
    [ "$__clean" = "$__confirm" ] && break
    err "No coinciden. Probá de nuevo."
  done
  printf -v "$__var" '%s' "$__clean"
}

# confirm <pregunta> [s|n]  -> 0 si sí
confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local __prompt="$1" __default="${2:-n}" __hint __ans
  [ "$__default" = "s" ] && __hint="S/n" || __hint="s/N"
  read -r -p "$(echo -e "  ${BOLD}$__prompt${N} ${D}[$__hint]${N}: ")" __ans
  __ans="${__ans:-$__default}"
  case "$__ans" in s|S|si|Si|SI|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# require_typed <palabra> <mensaje>  -> corta si no la escriben exacta
require_typed() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local __word="$1" __msg="$2" __ans
  read -r -p "$(echo -e "  $__msg ${BOLD}$__word${N}: ")" __ans
  [ "$__ans" = "$__word" ] || die "Cancelado."
}

# ---------------------------------------------------------------------------
# Validaciones
# ---------------------------------------------------------------------------
valid_hostname() {
  echo "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
}
valid_slug() { echo "$1" | grep -qE '^[a-z0-9][a-z0-9_-]{0,31}$'; }
valid_port() { echo "$1" | grep -qE '^[0-9]+$' && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }

slugify() {
  local s="$1" ascii
  ascii="$(printf '%s' "$s" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null)" && s="$ascii"
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\+/-/g; s/^-\+//; s/-\+$//' | cut -c1-24
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# OJO: sin -f a propósito. Con -f, curl sale con error en 4xx/5xx y el
# `|| echo 000` concatena el código: un 401 devolvía "401000" y todos los
# chequeos de "debe dar 401" fallaban en falso.
http_code() {
  curl -sS --max-time "${2:-5}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000
}
http_code_post() {
  curl -sS --max-time "${2:-5}" -o /dev/null -w '%{http_code}' -X POST "$1" 2>/dev/null || echo 000
}

# Cuenta coincidencias sin el bug de `grep -c`, que imprime 0 Y ADEMÁS
# devuelve código 1 cuando no encuentra nada.
count_matches() {
  local n
  n="$(grep -ciE "$1" 2>/dev/null || true)"
  printf '%s' "${n:-0}" | tr -dc '0-9' | head -c 6
}

wait_for_http() {
  local url="$1" timeout="${2:-30}" i
  for i in $(seq 1 "$timeout"); do
    curl -sS -m 2 -o /dev/null "$url" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
env_get() {
  local key="$1" default="${2:-}" val
  [ -f "$ENV_FILE" ] || { printf '%s' "$default"; return; }
  val="$(grep -m1 "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
  printf '%s' "${val:-$default}"
}

# env_set <clave> <valor> — reemplaza o agrega, preservando el resto
env_set() {
  local key="$1" val="$2"
  [ -f "$ENV_FILE" ] || { err "No existe $ENV_FILE"; return 1; }
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

app_port()  { env_get PORT 3000; }
app_url()   { echo "http://localhost:$(app_port)"; }

# Slug del primer kiosko configurado
first_kiosk() {
  if [ -f "$CAMERAS_JSON" ] && command -v node >/dev/null 2>&1; then
    node -e '
      try {
        const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        process.stdout.write((c.cameras && c.cameras[0] && c.cameras[0].id) || "principal");
      } catch (e) { process.stdout.write("principal"); }
    ' "$CAMERAS_JSON" 2>/dev/null || echo principal
  else
    echo principal
  fi
}

# ---------------------------------------------------------------------------
# Sistema
# ---------------------------------------------------------------------------
is_raspberry_pi() {
  [ -f /proc/device-tree/model ] && tr -d '\0' < /proc/device-tree/model | grep -q "Raspberry Pi"
}
pi_model() {
  [ -f /proc/device-tree/model ] && tr -d '\0' < /proc/device-tree/model || echo "desconocido"
}
has_pm2()     { command -v pm2 >/dev/null 2>&1; }
pm2_exists()  { has_pm2 && pm2 describe "$1" >/dev/null 2>&1; }
pm2_status()  {
  has_pm2 || { echo "sin-pm2"; return; }
  pm2 jlist 2>/dev/null | node -e '
    let d = ""; process.stdin.on("data", c => d += c).on("end", () => {
      try {
        const p = JSON.parse(d).find(x => x.name === process.argv[1]);
        process.stdout.write(p ? (p.pm2_env && p.pm2_env.status) || "?" : "no-existe");
      } catch (e) { process.stdout.write("?"); }
    });
  ' "$1" 2>/dev/null || echo "?"
}

# Reparación de finales de línea.
#
# El patrón es \r*$ y no \r$: un archivo que ya venía con CRLF y encima pasó
# por otra conversión queda con \r\r\n, y quitar un solo \r no alcanza.
fix_line_endings() {
  local fixed=0 f
  for f in "$APP_DIR"/*.sh "$APP_DIR"/sentinel "$APP_DIR"/lib/*.sh "$APP_DIR"/scripts/*.py; do
    [ -f "$f" ] || continue
    if grep -qU $'\r' "$f" 2>/dev/null; then
      sed -i 's/\r*$//' "$f" 2>/dev/null && fixed=$((fixed + 1))
    fi
  done
  [ "$fixed" -gt 0 ] && warn "Corregidos finales de línea CRLF en $fixed archivo(s)"
  chmod +x "$APP_DIR"/*.sh "$APP_DIR"/sentinel 2>/dev/null || true
  return 0
}

# Mantiene sudo vivo durante una operación larga
keep_sudo_alive() {
  sudo -v || die "Se necesitan permisos de sudo."
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null & )
}

require_not_root() {
  [ "$(id -u)" -eq 0 ] && die "No lo corras como root ni con sudo.
    Ejecutalo como tu usuario normal — pide sudo cuando lo necesita."
  return 0
}

require_app_dir() {
  [ -f "$APP_DIR/src/server.js" ] || die "No encuentro src/server.js.
    Corré el comando desde adentro de la carpeta del proyecto."
  return 0
}

# Oculta usuario y clave de una URL antes de mostrarla o loguearla
mask_url() { echo "$1" | sed -E 's#(rtsps?://)[^@/]*@#\1***:***@#'; }

human_time() {
  local s="${1:-0}" h m
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  [ "$h" -gt 0 ] && printf '%dh %02dm' "$h" "$m" || printf '%dm %02ds' "$m" "$((s % 60))"
}
