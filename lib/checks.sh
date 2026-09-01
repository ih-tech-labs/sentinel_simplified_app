#!/usr/bin/env bash
# =============================================================================
#  Sentinel · suite de verificación
#
#  Una sola definición de "el sistema está sano", usada por install.sh,
#  deploy.sh y `sentinel status`. Si los criterios divergen entre scripts,
#  tarde o temprano uno dice OK y el otro dice error sobre el mismo equipo.
# =============================================================================
[ -n "${SENTINEL_CHECKS_LOADED:-}" ] && return 0
SENTINEL_CHECKS_LOADED=1

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0
CHECK_REPORT=()

_record() { CHECK_REPORT+=("$1|$2|$3"); }

check_pass() { CHECKS_PASSED=$((CHECKS_PASSED+1)); ok   "$1"; _record OK   "$1" "${2:-}"; }
check_fail() { CHECKS_FAILED=$((CHECKS_FAILED+1)); err  "$1"; _record FAIL "$1" "${2:-}"; }
check_warn() { CHECKS_WARNED=$((CHECKS_WARNED+1)); warn "$1"; _record WARN "$1" "${2:-}"; }

checks_reset() { CHECKS_PASSED=0; CHECKS_FAILED=0; CHECKS_WARNED=0; CHECK_REPORT=(); }

# check_http <url> <esperado> <descripción>
check_http() {
  local code
  code="$(http_code "$1" 6)"
  if [ "$code" = "$2" ]; then
    check_pass "$3" "HTTP $code"
  else
    check_fail "$3" "HTTP $code, se esperaba $2"
  fi
}

# ---------------------------------------------------------------------------
# Dependencias del sistema
# ---------------------------------------------------------------------------
check_dependencies() {
  step "Dependencias"
  local major

  if command -v node >/dev/null 2>&1; then
    major="$(node -v | sed 's/v\([0-9]*\).*/\1/')"
    if [ "$major" -ge 18 ]; then
      check_pass "Node.js $(node -v)"
    else
      check_fail "Node.js $(node -v) es muy viejo" "se necesita 18+"
    fi
  else
    check_fail "Node.js no está instalado"
  fi

  command -v ffmpeg >/dev/null 2>&1 \
    && check_pass "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')" \
    || check_fail "ffmpeg no está instalado" "sudo apt install -y ffmpeg"

  has_pm2 && check_pass "pm2 $(pm2 -v 2>/dev/null)" \
          || check_fail "pm2 no está instalado" "sudo npm install -g pm2"

  python3 -c "import serial" 2>/dev/null \
    && check_pass "pyserial disponible" \
    || check_warn "pyserial no está: sin control de luces" "sudo apt install -y python3-serial"

  command -v dig >/dev/null 2>&1 \
    && check_pass "dig disponible" \
    || check_warn "dig no está: no se puede verificar DNS" "sudo apt install -y dnsutils"
}

# ---------------------------------------------------------------------------
# Archivos del proyecto
# ---------------------------------------------------------------------------
check_files() {
  step "Archivos"
  local f missing=0
  for f in src/server.js public/kiosk/index.html public/backoffice/index.html sentinel; do
    [ -e "$APP_DIR/$f" ] || { check_fail "Falta $f"; missing=1; }
  done
  [ "$missing" -eq 0 ] && check_pass "Archivos del proyecto completos"

  [ -f "$ENV_FILE" ] && check_pass ".env presente" || check_fail "Falta .env"

  if [ -f "$APP_DIR/public/assets/background.mp4" ]; then
    local mb; mb="$(du -m "$APP_DIR/public/assets/background.mp4" | cut -f1)"
    if [ "$mb" -gt 20 ]; then
      check_warn "background.mp4 pesa ${mb}MB" "optimizalo: sentinel video <archivo>"
    else
      check_pass "background.mp4 optimizado (${mb}MB)"
    fi
  else
    check_warn "No hay background.mp4" "el kiosko va a mostrar fondo negro"
  fi

  [ -d "$APP_DIR/node_modules" ] && check_pass "Dependencias instaladas" \
                                 || check_fail "Falta node_modules" "npm install --omit=dev"
}

# ---------------------------------------------------------------------------
# Sintaxis
# ---------------------------------------------------------------------------
check_syntax() {
  step "Sintaxis"
  local f bad=0
  for f in "$APP_DIR"/src/*.js; do
    node --check "$f" 2>/dev/null || { check_fail "Error de sintaxis en $(basename "$f")"; bad=1; }
  done
  [ "$bad" -eq 0 ] && check_pass "Módulos de Node verificados"

  bad=0
  for f in "$APP_DIR"/*.sh "$APP_DIR"/sentinel "$APP_DIR"/lib/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null || { check_fail "Error de sintaxis en $(basename "$f")"; bad=1; }
  done
  [ "$bad" -eq 0 ] && check_pass "Scripts verificados"
}

# ---------------------------------------------------------------------------
# Configuración de cámaras
# ---------------------------------------------------------------------------
check_config() {
  step "Configuración"
  if [ -f "$CAMERAS_JSON" ]; then
    if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$CAMERAS_JSON" 2>/dev/null; then
      local n
      n="$(node -e '
        const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        process.stdout.write(String((c.cameras || []).length));
      ' "$CAMERAS_JSON" 2>/dev/null || echo 0)"
      check_pass "cameras.json válido" "$n cámara(s)"
    else
      check_fail "cameras.json tiene JSON inválido"
    fi
  else
    check_warn "Sin config/cameras.json" "se usan los valores por defecto"
  fi

  # appearance.json es opcional (sin él, el kiosko usa los valores de siempre),
  # pero si existe y está roto conviene enterarse acá y no mirando el kiosko.
  if [ -f "$APP_DIR/config/appearance.json" ]; then
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$APP_DIR/config/appearance.json" 2>/dev/null \
      && check_pass "appearance.json válido" \
      || check_warn "appearance.json tiene JSON inválido" "el kiosko usa los valores por defecto"
  fi

  [ -n "$(env_get VERKADA_SHARED_SECRET)" ] \
    && check_pass "Secret de Verkada configurado" \
    || check_warn "VERKADA_SHARED_SECRET vacío" "el webhook va a rechazar todo"

  [ -n "$(env_get AUTH_HASH)" ] \
    && check_pass "Contraseña hasheada" \
    || check_fail "Falta AUTH_HASH en .env"
}

# ---------------------------------------------------------------------------
# Servicios y endpoints
# ---------------------------------------------------------------------------
check_services() {
  step "Servicios"
  local st
  st="$(pm2_status sentinel)"
  case "$st" in
    online)    check_pass "Servicio 'sentinel' online" ;;
    no-existe) check_fail "El servicio 'sentinel' no existe en pm2" ;;
    sin-pm2)   check_warn "pm2 no disponible" ;;
    *)         check_fail "Servicio 'sentinel' en estado '$st'" ;;
  esac

  if [ "$(env_get GPIO_ENABLED true)" = "true" ]; then
    st="$(pm2_status sentinel-gpio)"
    case "$st" in
      online)    check_pass "Daemon de luces online" ;;
      no-existe) check_warn "El daemon de luces no está" "sentinel diagnose gpio" ;;
      *)         check_warn "Daemon de luces en estado '$st'" ;;
    esac
  fi
}

check_endpoints() {
  step "Endpoints"
  local base kiosk
  base="$(app_url)"
  kiosk="$(first_kiosk)"

  if ! wait_for_http "$base/healthz" 20; then
    check_fail "El servidor no responde en $base"
    return 1
  fi

  check_http "$base/healthz"           200 "Servidor operativo"
  check_http "$base/login/"            200 "Página de login"
  check_http "$base/api/health"        401 "API protegida sin sesión"
  check_http "$base/backoffice/"       302 "Backoffice exige login"
  check_http "$base/kiosk/?id=$kiosk"  200 "Kiosko accesible"

  local wh
  wh="$(http_code_post "$base/verkada-webhook" 5)"
  case "$wh" in
    400) check_pass "Webhook activo" "rechaza sin firma, correcto" ;;
    500) check_warn "Webhook sin secret configurado" "HTTP 500" ;;
    *)   check_warn "El webhook devolvió HTTP $wh" ;;
  esac
}

# check_login <usuario> <clave>  — prueba real de punta a punta
check_login() {
  local user="$1" pass="$2" base body code jar
  base="$(app_url)"
  jar="$(mktemp)"
  body="$(node -e 'process.stdout.write(JSON.stringify({user:process.argv[1],password:process.argv[2]}))' "$user" "$pass")"
  code="$(curl -sS -m 6 -o /dev/null -w '%{http_code}' -c "$jar" -X POST \
          -H 'Content-Type: application/json' -d "$body" "$base/api/login" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    local sess
    sess="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -b "$jar" "$base/api/health" 2>/dev/null || echo 000)"
    [ "$sess" = "200" ] && check_pass "Login funciona de punta a punta" \
                        || check_fail "La sesión no da acceso a la API" "HTTP $sess"
  else
    check_fail "El login falló" "HTTP $code"
  fi
  rm -f "$jar"
}

# ---------------------------------------------------------------------------
# Resumen y reporte
# ---------------------------------------------------------------------------
checks_summary() {
  echo ""
  hr
  local total=$((CHECKS_PASSED + CHECKS_FAILED))
  if [ "$CHECKS_FAILED" -eq 0 ]; then
    echo -e "  ${G}${BOLD}$CHECKS_PASSED/$total verificaciones OK${N}$([ "$CHECKS_WARNED" -gt 0 ] && echo " ${Y}· $CHECKS_WARNED advertencia(s)${N}")"
  else
    echo -e "  ${R}${BOLD}$CHECKS_FAILED de $total verificaciones fallaron${N}"
  fi
  hr
  return "$CHECKS_FAILED"
}

# write_report <archivo> <título>
write_report() {
  local out="$1" title="${2:-Reporte de instalación}" line status desc detail
  {
    echo "═══════════════════════════════════════════════════════════"
    echo " SENTINEL · $title"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Fecha        : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Equipo       : $(hostname)"
    echo "Hardware     : $(pi_model)"
    echo "Sistema      : $( [ -f /etc/os-release ] && . /etc/os-release && echo "${PRETTY_NAME:-?}" )"
    echo "Usuario      : $(whoami)"
    echo "Carpeta      : $APP_DIR"
    echo "IP local     : $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo ""
    echo "─── Versiones ─────────────────────────────────────────────"
    echo "Node.js      : $(node -v 2>/dev/null || echo '-')"
    echo "npm          : $(npm -v 2>/dev/null || echo '-')"
    echo "pm2          : $(pm2 -v 2>/dev/null || echo '-')"
    echo "ffmpeg       : $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}' || echo '-')"
    echo "Python       : $(python3 -V 2>/dev/null || echo '-')"
    echo "cloudflared  : $(cloudflared --version 2>/dev/null | awk '{print $3}' || echo 'no instalado')"
    echo "Chromium     : $( (chromium-browser --version || chromium --version) 2>/dev/null | head -1 || echo '-')"
    echo ""
    echo "─── Configuración ─────────────────────────────────────────"
    echo "Puerto       : $(app_port)"
    echo "Usuario web  : $(env_get AUTH_USER)"
    echo "Streams      : $(env_get STREAM_WIDTH 640)x$(env_get STREAM_HEIGHT 360) @ $(env_get STREAM_FPS 12)fps"
    echo "On-demand    : $(env_get STREAM_ON_DEMAND true)"
    echo "Webhook      : $( [ -n "$(env_get VERKADA_SHARED_SECRET)" ] && echo 'configurado' || echo 'SIN SECRET' )"
    echo "Luces        : $(env_get GPIO_ENABLED true)"
    if [ -f "$APP_DIR/.screen_rotation" ]; then
      echo "Pantalla     : $(grep -m1 '^ROTATION=' "$APP_DIR/.screen_rotation" | cut -d= -f2)° de rotación"
    fi
    echo ""
    echo "─── Cámaras ───────────────────────────────────────────────"
    if [ -f "$CAMERAS_JSON" ]; then
      node -e '
        const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        console.log("Sitio        : " + (c.site || "-"));
        (c.cameras || []).forEach((cam) => {
          console.log("");
          console.log("  id         : " + cam.id);
          console.log("  nombre     : " + cam.name);
          console.log("  zona       : " + (cam.zone || "-"));
          console.log("  deviceId   : " + (cam.deviceId || "SIN CARGAR"));
          console.log("  rtsp       : " + String(cam.rtspUrl || "-").replace(/(rtsps?:\/\/)[^@/]*@/, "$1***:***@"));
        });
      ' "$CAMERAS_JSON" 2>/dev/null || echo "(no se pudo leer)"
    else
      echo "(sin cameras.json — valores por defecto)"
    fi
    echo ""
    echo "─── Túnel ─────────────────────────────────────────────────"
    if [ -f /etc/cloudflared/config.yml ]; then
      echo "Dominio      : $(sudo grep -m1 'hostname:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $NF}')"
      echo "Túnel UUID   : $(sudo grep -m1 '^tunnel:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}')"
      echo "Servicio     : $(systemctl is-active cloudflared 2>/dev/null || echo '-')"
    else
      echo "(sin túnel configurado)"
    fi
    echo ""
    echo "─── Verificaciones ────────────────────────────────────────"
    for line in "${CHECK_REPORT[@]}"; do
      status="${line%%|*}"; line="${line#*|}"
      desc="${line%%|*}"; detail="${line#*|}"
      printf '[%-4s] %s%s\n' "$status" "$desc" "$( [ -n "$detail" ] && echo "  ($detail)" )"
    done
    echo ""
    echo "OK: $CHECKS_PASSED · Fallos: $CHECKS_FAILED · Advertencias: $CHECKS_WARNED"
    echo ""
    echo "─── Servicios pm2 ─────────────────────────────────────────"
    pm2 list --no-color 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || echo "(pm2 no disponible)"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
  } > "$out" 2>/dev/null
  chmod 600 "$out" 2>/dev/null || true
}
