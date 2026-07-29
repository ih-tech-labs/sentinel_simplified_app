#!/usr/bin/env bash
# =============================================================================
#  Sentinel · diagnóstico del webhook de Verkada
#
#  Recorre la cadena completa y dice en qué eslabón se corta:
#
#     Verkada → internet → túnel → servidor → firma → device_id → alarma
#
#  El problema con este camino es que casi todos los fallos son SILENCIOSOS:
#  Verkada manda el POST, recibe un 200 o un 404, y no avisa nada. Por eso
#  acá se prueba cada eslabón por separado con peticiones firmadas de verdad.
# =============================================================================
[ -n "${SENTINEL_WEBHOOK_LOADED:-}" ] && return 0
SENTINEL_WEBHOOK_LOADED=1

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Firma un cuerpo igual que lo hace Verkada: HMAC-SHA256 sobre "cuerpo|timestamp"
webhook_sign() {
  local body="$1" ts="$2" secret="$3"
  printf '%s|%s' "$body" "$ts" | openssl dgst -sha256 -hmac "$secret" -hex 2>/dev/null | awk '{print $NF}'
}

# webhook_post <url> <body> <secret> [timestamp]  -> imprime "codigo|respuesta"
webhook_post() {
  local url="$1" body="$2" secret="$3" ts="${4:-$(date +%s)}" sig out code
  sig="$(webhook_sign "$body" "$ts" "$secret")"
  out="$(curl -sS -m 15 -w '\n%{http_code}' -X POST \
        -H 'Content-Type: application/json' \
        -H "verkada-signature: ${ts}|${sig}" \
        -d "$body" "$url" 2>/dev/null)" || out=$'\n000'
  code="$(printf '%s' "$out" | tail -1)"
  printf '%s|%s' "$code" "$(printf '%s' "$out" | head -n -1)"
}

webhook_diagnose() {
  local problems=0
  banner "DIAGNÓSTICO · webhook de Verkada"

  # -------------------------------------------------------------------------
  step "1 · Secret compartido"
  # -------------------------------------------------------------------------
  local secret; secret="$(env_get VERKADA_SHARED_SECRET)"
  if [ -z "$secret" ]; then
    err "VERKADA_SHARED_SECRET está vacío en .env"
    info "Sin esto el webhook rechaza TODO con HTTP 500."
    info "Copialo de Verkada Command → Admin → Webhooks y pegalo en .env"
    problems=$((problems + 1))
    hr; return 1
  fi
  ok "Configurado (${#secret} caracteres)"
  info "Tiene que ser idéntico al de Verkada Command, sin espacios de más."

  # -------------------------------------------------------------------------
  step "2 · Cámaras y sus device_id"
  # -------------------------------------------------------------------------
  local first_device=""
  if [ -f "$CAMERAS_JSON" ]; then
    node -e '
      const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      (c.cameras || []).forEach((cam) => {
        console.log("    " + cam.id.padEnd(16) + (cam.deviceId || "SIN device_id — no va a recibir alarmas"));
      });
    ' "$CAMERAS_JSON" 2>/dev/null
    first_device="$(node -e '
      const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const cam = (c.cameras || []).find((x) => x.deviceId);
      process.stdout.write(cam ? cam.deviceId : "");
    ' "$CAMERAS_JSON" 2>/dev/null)"
    if [ -z "$first_device" ]; then
      err "Ninguna cámara tiene device_id"
      info "Las alarmas van a llegar y validar, pero se descartan como 'unknown_camera'."
      problems=$((problems + 1))
    else
      ok "Hay al menos una cámara con device_id"
    fi
  else
    warn "Sin config/cameras.json (se usan los valores por defecto)"
  fi

  # -------------------------------------------------------------------------
  step "3 · El endpoint local"
  # -------------------------------------------------------------------------
  local base; base="$(app_url)"
  if ! curl -sS -m3 -o /dev/null "$base/healthz" 2>/dev/null; then
    err "El servidor no responde en $base"
    info "./sentinel restart server"
    problems=$((problems + 1)); hr; return 1
  fi
  ok "El servidor responde"

  local code
  code="$(http_code_post "$base/verkada-webhook" 5)"
  case "$code" in
    400) ok "POST /verkada-webhook → 400 sin firma ${D}(correcto: está vivo)${N}" ;;
    500) err "POST /verkada-webhook → 500: falta el secret"; problems=$((problems + 1)) ;;
    404) err "POST /verkada-webhook → 404: la ruta no existe"; problems=$((problems + 1)) ;;
    *)   warn "POST /verkada-webhook → HTTP $code" ;;
  esac

  # La raíz NO es el webhook: es el error más común al cargar la URL
  code="$(http_code_post "$base/" 5)"
  info "POST / → HTTP $code ${D}(si Verkada apunta acá, el evento se pierde)${N}"

  # -------------------------------------------------------------------------
  step "4 · Firma"
  # -------------------------------------------------------------------------
  local body result
  body='{"data":{"device_id":"prueba-diagnostico","notification_type":"alert_rule_motion"}}'

  result="$(webhook_post "$base/verkada-webhook" "$body" "$secret")"
  case "${result%%|*}" in
    200) ok "Firma válida aceptada ${D}(${result#*|})${N}" ;;
    401) err "Firma rechazada con el secret del .env"
         info "El secret del .env no coincide con el que espera el servidor."
         problems=$((problems + 1)) ;;
    *)   err "Respuesta inesperada: HTTP ${result%%|*} ${result#*|}"; problems=$((problems + 1)) ;;
  esac

  result="$(webhook_post "$base/verkada-webhook" "$body" "secret-incorrecto-a-proposito")"
  [ "${result%%|*}" = "401" ] \
    && ok "Firma incorrecta rechazada ${D}(la validación funciona)${N}" \
    || { err "Una firma incorrecta devolvió HTTP ${result%%|*} en vez de 401"; problems=$((problems + 1)); }

  # Timestamp viejo: protección contra reenvío
  result="$(webhook_post "$base/verkada-webhook" "$body" "$secret" 1000000000)"
  [ "${result%%|*}" = "403" ] \
    && ok "Firma expirada rechazada ${D}(protección de replay)${N}" \
    || info "Firma vieja → HTTP ${result%%|*}"

  # -------------------------------------------------------------------------
  step "5 · Alarma real de punta a punta"
  # -------------------------------------------------------------------------
  if [ -n "$first_device" ]; then
    body="{\"data\":{\"device_id\":\"$first_device\",\"notification_type\":\"alert_rule_motion\"}}"
    result="$(webhook_post "$base/verkada-webhook" "$body" "$secret")"
    if [ "${result%%|*}" = "200" ] && echo "${result#*|}" | grep -q '"ok"'; then
      ok "Alarma aceptada y disparada ${D}(mirá el tablero: tiene que aparecer)${N}"
    elif echo "${result#*|}" | grep -q 'filtered_type'; then
      warn "Aceptada pero filtrada por allowedEvents"
      info "El tipo 'alert_rule_motion' no está en la lista de esa cámara."
    else
      err "No se disparó: ${result#*|}"
      problems=$((problems + 1))
    fi
  else
    warn "Se omite: no hay ninguna cámara con device_id"
  fi

  # -------------------------------------------------------------------------
  step "6 · Desde internet"
  # -------------------------------------------------------------------------
  local domain=""
  [ -f /etc/cloudflared/config.yml ] && \
    domain="$(sudo grep -m1 'hostname:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $NF}')"

  if [ -z "$domain" ]; then
    err "No hay túnel configurado: Verkada no puede llegar a este equipo"
    info "./sentinel tunnel setup <dominio>"
    problems=$((problems + 1))
  else
    local url="https://$domain/verkada-webhook"
    echo -e "  ${BOLD}URL para Verkada Command → Admin → Webhooks:${N}"
    echo -e "    ${B}$url${N}"
    echo ""

    code="$(http_code_post "$url" 15)"
    case "$code" in
      400) ok "Responde 400 sin firma ${D}(el endpoint es alcanzable desde afuera)${N}" ;;
      404) err "404 desde internet: revisá que el túnel apunte al puerto correcto"; problems=$((problems + 1)) ;;
      000) err "Sin respuesta: el túnel no está funcionando"
           info "./sentinel tunnel status"
           problems=$((problems + 1)) ;;
      530|502) err "HTTP $code: el túnel no alcanza el servidor local"; problems=$((problems + 1)) ;;
      *)   warn "HTTP $code" ;;
    esac

    if [ "$code" = "400" ] && [ -n "$first_device" ]; then
      body="{\"data\":{\"device_id\":\"$first_device\",\"notification_type\":\"alert_rule_motion\"}}"
      result="$(webhook_post "$url" "$body" "$secret")"
      [ "${result%%|*}" = "200" ] \
        && ok "Alarma firmada aceptada DESDE INTERNET ${D}(cadena completa OK)${N}" \
        || { err "Desde internet: HTTP ${result%%|*} ${result#*|}"; problems=$((problems + 1)); }
    fi
  fi

  # -------------------------------------------------------------------------
  step "7 · Actividad reciente"
  # -------------------------------------------------------------------------
  local lines
  lines="$(pm2 logs sentinel --lines 400 --nostream 2>/dev/null | grep -c "WEBHOOK\|CÁMARA NO CONFIGURADA" || true)"
  lines="$(printf '%s' "${lines:-0}" | tr -dc '0-9')"
  if [ "${lines:-0}" -gt 0 ]; then
    ok "$lines evento(s) de webhook en el log reciente"
    pm2 logs sentinel --lines 400 --nostream 2>/dev/null \
      | grep -E "WEBHOOK|device_id :" | tail -6 | sed 's/^/      /'
  else
    warn "Ningún webhook en el log reciente"
    info "Si Verkada dice que los está mandando, la URL de allá está mal."
    info "Tiene que terminar en /verkada-webhook — el dominio solo no alcanza."
  fi

  # -------------------------------------------------------------------------
  echo ""
  hr
  if [ "$problems" -eq 0 ]; then
    echo -e "  ${G}${BOLD}La cadena funciona de punta a punta.${N}"
    echo ""
    info "Si Verkada igual no dispara nada, el problema está de su lado:"
    info "  · que la URL cargada allá termine en /verkada-webhook"
    info "  · que la regla de alerta esté activa y apunte a esta cámara"
    info "  · que el tipo de evento esté en allowedEvents de cameras.json"
  else
    echo -e "  ${R}${BOLD}$problems problema(s).${N}"
  fi
  hr
  echo ""
  return 0
}
