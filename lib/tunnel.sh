#!/usr/bin/env bash
# =============================================================================
#  Sentinel · túnel de Cloudflare
#
#  Un túnel publica este equipo en un dominio propio para que Verkada pueda
#  entregarle las alarmas desde internet.
#
#  REGLA DE ORO: nunca tocar túneles que no sean el nuestro. El instalador de
#  la v4 hacía "destruir y recrear" sobre un nombre fijo, así que correrlo en
#  un equipo nuevo con la misma cuenta borraba el túnel de producción de otro
#  sitio. Acá se reutiliza si existe y se borra sólo con --recreate.
# =============================================================================
[ -n "${SENTINEL_TUNNEL_LOADED:-}" ] && return 0
SENTINEL_TUNNEL_LOADED=1

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

tunnel_install_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 && { ok "cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}')"; return 0; }

  local arch url tmp
  arch="$(dpkg --print-architecture 2>/dev/null || echo arm64)"
  case "$arch" in
    arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb" ;;
    armhf) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-armhf.deb" ;;
    amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" ;;
    *) err "Arquitectura no soportada: $arch"; return 1 ;;
  esac

  info "Descargando cloudflared para $arch..."
  tmp="$(mktemp -u /tmp/cloudflared-XXXX).deb"
  if curl -fsSL --output "$tmp" "$url" && sudo dpkg -i "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; ok "cloudflared instalado"; return 0
  fi
  rm -f "$tmp"; err "No se pudo instalar cloudflared"; return 1
}

tunnel_logged_in() { [ -f "$HOME/.cloudflared/cert.pem" ]; }

tunnel_login_help() {
  echo ""
  err "No estás logueado en Cloudflare"
  echo ""
  echo -e "  Corré esto y autorizá el dominio en el navegador:"
  echo -e "    ${B}cloudflared tunnel login${N}"
  echo ""
  info "Por SSH sin navegador: cloudflared imprime una URL, abrila desde"
  info "cualquier otra computadora con tu sesión de Cloudflare."
  echo ""
}

# Sólo las líneas que empiezan con un UUID son túneles. El resto de la salida
# es encabezado, ayuda y avisos de versión — contarlas daba números inventados.
tunnel_rows() {
  cloudflared tunnel list 2>/dev/null \
    | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} ' || true
}

tunnel_uuid_of() { tunnel_rows | awk -v n="$1" '$2 == n {print $1; exit}'; }
tunnel_name_of() { tunnel_rows | awk -v u="$1" '$1 == u {print $2; exit}'; }

tunnel_name_from_domain() {
  local label; label="$(echo "$1" | cut -d. -f1)"
  case "$label" in sentinel*) echo "$label" ;; *) echo "sentinel-$label" ;; esac
}

tunnel_validate_name() {
  case "$1" in
    http*|*://*|*/*) err "\"$1\" parece una URL, no un nombre de túnel."
                     info "El nombre es sólo una etiqueta. Ej: sentinel-catamarca"
                     return 1 ;;
  esac
  echo "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$' && return 0
  err "\"$1\" no es un nombre de túnel válido."
  return 1
}

# Devuelve el UUID al que apunta hoy el DNS del dominio, o vacío
tunnel_dns_uuid() {
  local domain="$1" cname=""
  if command -v dig >/dev/null 2>&1; then
    cname="$(dig +short CNAME "$domain" @1.1.1.1 2>/dev/null | head -1 | sed 's/\.$//')"
  elif command -v host >/dev/null 2>&1; then
    cname="$(host -t CNAME "$domain" 1.1.1.1 2>/dev/null | awk '/alias for/ {print $NF}' | head -1 | sed 's/\.$//')"
  fi
  [ -n "$cname" ] && [ "${cname%%.cfargotunnel.com}" != "$cname" ] && echo "${cname%%.cfargotunnel.com}"
}

# ---------------------------------------------------------------------------
# tunnel_setup <dominio> [nombre] [--recreate]
# ---------------------------------------------------------------------------
tunnel_setup() {
  local domain name recreate=0 arg
  domain="$(sanitize "${1:-}")"; shift || true
  name=""
  for arg in "$@"; do
    case "$arg" in
      --recreate) recreate=1 ;;
      --*) ;;
      *) [ -z "$name" ] && name="$(sanitize "$arg")" ;;
    esac
  done

  [ -z "$domain" ] && { err "Falta el dominio. Ej: sentinel sentinel-catamarca.ihtechlabs.com"; return 1; }
  valid_hostname "$domain" || { err "\"$domain\" no es un dominio válido."; return 1; }
  [ -z "$name" ] && name="$(tunnel_name_from_domain "$domain")"
  tunnel_validate_name "$name" || return 1

  local port; port="$(app_port)"
  banner "TÚNEL DE CLOUDFLARE"
  echo -e "  Dominio  ${BOLD}$domain${N}"
  echo -e "  Túnel    ${BOLD}$name${N}"
  echo -e "  Destino  ${BOLD}http://localhost:$port${N}"

  step "1/6 · cloudflared"
  tunnel_install_cloudflared || return 1

  step "2/6 · Login"
  tunnel_logged_in || { tunnel_login_help; return 1; }
  ok "Credenciales encontradas"

  step "3/6 · Túnel"
  local uuid; uuid="$(tunnel_uuid_of "$name")"
  if [ -n "$uuid" ]; then
    if [ "$recreate" -eq 1 ]; then
      warn "Borrando '$name' (--recreate)"
      sudo systemctl stop cloudflared 2>/dev/null || true
      cloudflared tunnel delete -f "$name" >/dev/null 2>&1 || true
      cloudflared tunnel create "$name" >/dev/null 2>&1 || { err "No se pudo recrear"; return 1; }
      uuid="$(tunnel_uuid_of "$name")"
      ok "Túnel recreado"
    else
      ok "El túnel '$name' ya existe: se reutiliza"
    fi
  else
    cloudflared tunnel create "$name" >/dev/null 2>&1 || { err "No se pudo crear '$name'"; return 1; }
    uuid="$(tunnel_uuid_of "$name")"
    ok "Túnel '$name' creado"
  fi
  [ -z "$uuid" ] && { err "No pude obtener el UUID de '$name'"; return 1; }
  ok "UUID: $uuid"

  local others
  others="$(tunnel_rows | awk -v n="$name" '$2 != n {print "    · " $2}')"
  [ -n "$others" ] && { info "Otros túneles de la cuenta (no se tocan):"; echo "$others"; }

  local cred="$HOME/.cloudflared/$uuid.json"
  [ -f "$cred" ] || { err "Faltan las credenciales: $cred"; info "Probá con --recreate"; return 1; }

  step "4/6 · DNS"
  # `route dns -f` pisa el registro sin preguntar. Si el dominio ya lo usa otro
  # equipo, ese equipo se queda sin webhook y nadie se entera hasta que falla
  # una alarma, en otro sitio, otro día.
  local dns_uuid; dns_uuid="$(tunnel_dns_uuid "$domain")"
  if [ -n "$dns_uuid" ] && [ "$dns_uuid" != "$uuid" ]; then
    echo ""
    err "$domain ya apunta a OTRO túnel"
    info "DNS actual : $dns_uuid ($(tunnel_name_of "$dns_uuid"))"
    info "Este equipo: $uuid ($name)"
    echo ""
    echo -e "  ${Y}Si seguís, el equipo que usa hoy ese dominio se queda sin webhook.${N}"
    echo ""
    require_typed PISAR "Escribí" || return 1
  fi

  if cloudflared tunnel route dns -f "$name" "$domain" >/dev/null 2>&1; then
    ok "$domain → $name"
  else
    warn "No se pudo crear el registro DNS automáticamente"
    info "Alternativa manual en Cloudflare → DNS:"
    info "  CNAME · $(echo "$domain" | cut -d. -f1) · $uuid.cfargotunnel.com · Proxy activado"
  fi

  step "5/6 · Servicio"
  sudo mkdir -p /etc/cloudflared
  if [ -f /etc/cloudflared/config.yml ]; then
    sudo cp /etc/cloudflared/config.yml "/etc/cloudflared/config.yml.bak-$(date +%Y%m%d-%H%M%S)"
    warn "Config anterior respaldada"
  fi
  sudo cp "$cred" /etc/cloudflared/
  sudo cp "$HOME/.cloudflared/cert.pem" /etc/cloudflared/ 2>/dev/null || true

  sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: $uuid
credentials-file: /etc/cloudflared/$uuid.json

ingress:
  - hostname: $domain
    service: http://localhost:$port
    originRequest:
      connectTimeout: 30s
  - service: http_status:404
EOF
  ok "config.yml escrito"

  sudo cloudflared service uninstall >/dev/null 2>&1 || true
  sudo cloudflared service install >/dev/null 2>&1 || warn "service install devolvió error"
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable cloudflared >/dev/null 2>&1 || true
  sudo systemctl restart cloudflared >/dev/null 2>&1 || true

  step "6/6 · Verificación"
  sleep 5
  systemctl is-active --quiet cloudflared 2>/dev/null \
    && ok "cloudflared corriendo" \
    || { err "cloudflared no está activo"; info "sudo journalctl -u cloudflared -n 40"; }

  echo -n "  Probando desde internet"
  local i code reached=0
  for i in $(seq 1 12); do
    code="$(http_code "https://$domain/healthz" 6)"
    [ "$code" = "200" ] && { reached=1; echo -e " ${G}responde${N}"; break; }
    printf "."; sleep 5
  done
  [ "$reached" -eq 0 ] && echo ""

  echo ""
  if [ "$reached" -eq 1 ]; then
    echo -e "${G}${BOLD}  ✔ Túnel operativo${N}"
  else
    warn "Todavía no responde. El DNS puede tardar unos minutos."
    info "Probá luego: curl -I https://$domain/healthz"
  fi
  echo ""
  echo -e "  ${BOLD}URL para Verkada Command → Admin → Webhooks:${N}"
  echo -e "    ${B}https://$domain/verkada-webhook${N}"
  echo ""
  return 0
}

# ---------------------------------------------------------------------------
# tunnel_status
# ---------------------------------------------------------------------------
tunnel_status() {
  local problems=0 works=0
  banner "ESTADO DEL TÚNEL"

  command -v cloudflared >/dev/null 2>&1 || { err "cloudflared no está instalado"; return 1; }
  ok "cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}')"
  tunnel_logged_in && ok "Logueado en Cloudflare" || { err "Sin login"; problems=$((problems+1)); }

  step "Túneles de la cuenta"
  local rows; rows="$(tunnel_rows)"
  if [ -z "$rows" ]; then
    warn "No hay túneles"
  else
    echo "$rows" | awk '{printf "    %-38s %s\n", $2, ($4 == "" ? "(sin conexiones)" : "conectado")}'
    info "$(echo "$rows" | grep -c .) túnel(es)"
    local junk; junk="$(echo "$rows" | awk '{print $2}' | grep -E '://|/' || true)"
    if [ -n "$junk" ]; then
      echo ""
      warn "Túneles con nombre inválido (una URL pegada por error):"
      echo "$junk" | sed 's/^/      · /'
      info "Borralos con: cloudflared tunnel delete '<nombre>'"
    fi
  fi

  step "Configuración local"
  local uuid="" domain=""
  if [ -f /etc/cloudflared/config.yml ]; then
    uuid="$(sudo grep -m1 '^tunnel:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}')"
    domain="$(sudo grep -m1 'hostname:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $NF}')"
    ok "Túnel   : $uuid ($(tunnel_name_of "$uuid"))"
    ok "Dominio : $domain"
    local cred; cred="$(sudo grep -m1 'credentials-file:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}')"
    if [ -n "$cred" ]; then
      sudo test -f "$cred" && ok "Credenciales presentes" \
        || { err "Faltan las credenciales: $cred"; problems=$((problems+1)); }
    fi
    if [ -n "$uuid" ] && [ -n "$rows" ] && ! echo "$rows" | grep -q "$uuid"; then
      err "El túnel del config ya no existe en la cuenta"
      problems=$((problems+1))
    fi
  else
    err "Sin /etc/cloudflared/config.yml"
    problems=$((problems+1))
  fi

  step "Servicio"
  if systemctl is-active --quiet cloudflared 2>/dev/null; then
    ok "cloudflared corriendo"
  else
    err "cloudflared no está corriendo"
    problems=$((problems+1))
    sudo journalctl -u cloudflared -n 10 --no-pager 2>/dev/null | sed 's/^/      /'
  fi
  systemctl is-enabled --quiet cloudflared 2>/dev/null && ok "Habilitado al arranque" \
    || warn "No arranca solo con el sistema"

  step "DNS"
  if [ -n "$domain" ]; then
    if ! command -v dig >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1; then
      # Sin resolver no podemos afirmar nada: es una herramienta que falta, no
      # un problema del túnel. La prueba real es la de más abajo.
      warn "Falta dig/host: se saltea (sudo apt install -y dnsutils)"
    else
      local dns_uuid; dns_uuid="$(tunnel_dns_uuid "$domain")"
      if [ -z "$dns_uuid" ]; then
        err "$domain no resuelve a un túnel"
        problems=$((problems+1))
      elif [ "$dns_uuid" = "$uuid" ]; then
        ok "$domain apunta a este túnel"
      else
        err "$domain apunta a otro túnel ($dns_uuid)"
        problems=$((problems+1))
      fi
    fi
  fi

  step "Prueba de punta a punta"
  local base; base="$(app_url)"
  curl -sS -m3 -o /dev/null "$base/healthz" 2>/dev/null \
    && ok "Sentinel responde en local" \
    || { err "Sentinel no responde en $base"; problems=$((problems+1)); }

  if [ -n "$domain" ]; then
    local code; code="$(http_code "https://$domain/healthz" 12)"
    case "$code" in
      200) ok "https://$domain/healthz → 200 · EL TÚNEL FUNCIONA"; works=1 ;;
      000) err "Sin respuesta desde internet"; problems=$((problems+1)) ;;
      530) err "HTTP 530 — el túnel no está conectado"; problems=$((problems+1)) ;;
      502|503) err "HTTP $code — Cloudflare llega pero no alcanza el origen"; problems=$((problems+1)) ;;
      *)   warn "HTTP $code" ;;
    esac
    local wh; wh="$(http_code_post "https://$domain/verkada-webhook" 12)"
    [ "$wh" = "400" ] && ok "Webhook vivo desde internet" || info "Webhook: HTTP $wh"
  fi

  echo ""
  hr
  # La prueba desde internet manda: si el dominio responde 200 el túnel anda,
  # aunque falte alguna herramienta de diagnóstico.
  if [ "$works" -eq 1 ] && [ "$problems" -eq 0 ]; then
    echo -e "  ${G}${BOLD}Túnel operativo.${N}"
    echo -e "\n  ${B}https://$domain/verkada-webhook${N}"
  elif [ "$works" -eq 1 ]; then
    echo -e "  ${G}${BOLD}El túnel FUNCIONA${N} ${D}($problems observación/es de higiene)${N}"
    echo -e "\n  ${B}https://$domain/verkada-webhook${N}"
  else
    echo -e "  ${R}${BOLD}$problems problema(s).${N}"
    echo -e "\n  Para rehacerlo:  ${B}sentinel tunnel clean${N} y después ${B}sentinel tunnel setup <dominio>${N}"
  fi
  hr
  echo ""
  return 0
}

# ---------------------------------------------------------------------------
# tunnel_clean — borra la config LOCAL, no toca la cuenta
# ---------------------------------------------------------------------------
tunnel_clean() {
  banner "LIMPIAR TÚNEL LOCAL"
  echo -e "  ${Y}Borra la configuración del túnel EN ESTE EQUIPO.${N}"
  info "Los túneles de tu cuenta de Cloudflare NO se tocan."
  info "Tu login (~/.cloudflared/cert.pem) tampoco."
  echo ""
  require_typed LIMPIAR "Escribí"

  echo ""
  sudo systemctl stop cloudflared 2>/dev/null && ok "Servicio detenido" || true
  sudo systemctl disable cloudflared >/dev/null 2>&1 && ok "Deshabilitado" || true
  sudo cloudflared service uninstall >/dev/null 2>&1 && ok "Servicio desinstalado" || true

  if [ -d /etc/cloudflared ]; then
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    sudo mkdir -p "/etc/cloudflared.bak-$stamp"
    sudo cp -a /etc/cloudflared/. "/etc/cloudflared.bak-$stamp/" 2>/dev/null || true
    ok "Backup en /etc/cloudflared.bak-$stamp"
    sudo rm -f /etc/cloudflared/config.yml /etc/cloudflared/*.json 2>/dev/null
    ok "config.yml y credenciales borrados"
  fi
  pkill -f "cloudflared tunnel" 2>/dev/null && ok "Procesos sueltos terminados" || true

  echo ""
  info "Ahora: sentinel tunnel setup <tu-dominio>"
  echo ""
}

# ---------------------------------------------------------------------------
# tunnel_delete <nombre> — borra un túnel de la cuenta
# ---------------------------------------------------------------------------
tunnel_delete() {
  local name="$1"
  [ -z "$name" ] && { err "Falta el nombre. Uso: sentinel tunnel delete <nombre>"; return 1; }

  local uuid; uuid="$(tunnel_uuid_of "$name")"
  [ -z "$uuid" ] && { err "No existe un túnel llamado '$name'"; tunnel_rows | awk '{print "    · " $2}'; return 1; }

  # Guardia: no dejar sin túnel al equipo que lo está usando ahora
  local local_uuid=""
  [ -f /etc/cloudflared/config.yml ] && local_uuid="$(sudo grep -m1 '^tunnel:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}')"
  if [ "$uuid" = "$local_uuid" ]; then
    echo ""
    err "'$name' es el túnel que usa ESTE equipo"
    info "Si lo borrás, este equipo se queda sin acceso desde internet."
    echo ""
    require_typed BORRAR "Escribí" || return 1
    sudo systemctl stop cloudflared 2>/dev/null || true
  fi

  echo ""
  warn "Borrando '$name' ($uuid)"
  if cloudflared tunnel delete -f "$name" 2>&1 | sed 's/^/      /'; then
    ok "Túnel borrado"
    info "Revisá el CNAME huérfano en Cloudflare → DNS → Records"
  else
    err "No se pudo borrar"
    info "Un túnel con conexiones activas no se deja borrar."
    info "Pará el servicio del equipo que lo usa: sudo systemctl stop cloudflared"
  fi
}
