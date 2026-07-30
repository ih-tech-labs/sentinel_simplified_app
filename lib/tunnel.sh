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

# Parametrizados para poder probar el diagnóstico y la reparación sin root.
# En producción quedan en sus valores reales.
CF_DIR="${SENTINEL_CF_DIR:-/etc/cloudflared}"
CF_SUDO="${SENTINEL_SUDO-sudo}"

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

  # Las credenciales se generan al CREAR el túnel y quedan sólo en esa máquina.
  # Si este equipo no las tiene —porque el túnel se creó en otro, o porque las
  # borró remove_all.sh— se pueden volver a bajar de la cuenta. Recrear el túnel
  # sería destructivo y cambiaría el UUID sin necesidad.
  local cred="$HOME/.cloudflared/$uuid.json"
  if [ ! -f "$cred" ]; then
    warn "Este equipo no tiene las credenciales de '$name'"
    info "Descargándolas de tu cuenta de Cloudflare..."
    mkdir -p "$HOME/.cloudflared"
    if cloudflared tunnel token --cred-file "$cred" "$name" >/dev/null 2>&1 && [ -s "$cred" ]; then
      chmod 600 "$cred" 2>/dev/null || true
      ok "Credenciales recuperadas (el túnel no se tocó)"
    else
      rm -f "$cred" 2>/dev/null || true
      err "No se pudieron recuperar las credenciales de '$name'"
      echo ""
      info "Opciones:"
      info "  · Usar otro dominio y crear un túnel nuevo:"
      echo -e "      ${B}sentinel tunnel setup sentinel-lab.ihtechlabs.com${N}"
      info "  · Rehacer ESTE túnel — le cambia el UUID y hay que reapuntar el DNS:"
      echo -e "      ${B}sentinel tunnel setup $domain --recreate${N}"
      echo ""
      return 1
    fi
  fi

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
# tunnel_why_down [uuid] — por qué no levanta cloudflared
#
#  "cloudflared no está corriendo" no dice nada por sí solo. Las causas reales
#  son pocas y concretas: falta la unidad de systemd, falta el archivo de
#  credenciales, el YAML está roto, o la red bloquea UDP 7844. Esto las separa
#  para no tener que leer el journal desde el otro lado del país.
# ---------------------------------------------------------------------------
tunnel_why_down() {
  local uuid="${1:-}" found=0

  # Sin config no hay nada que reparar: el unico camino es crearlo. Decir
  # "el servicio no esta instalado" ademas solo agrega ruido.
  if [ ! -f $CF_DIR/config.yml ]; then
    warn "CAUSA: este equipo no tiene túnel configurado"
    info "Arreglo: sentinel tunnel setup <dominio>"
    return 0
  fi

  if ! systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared\.service'; then
    err "CAUSA: el servicio no está instalado"
    info "Arreglo: sentinel tunnel fix"
    found=1
  fi

  # A partir de acá el config existe: revisamos su contenido.
  {
    local cred
    cred="$($CF_SUDO grep -m1 'credentials-file:' $CF_DIR/config.yml 2>/dev/null | awk '{print $2}')"
    if [ -n "$cred" ] && ! $CF_SUDO test -f "$cred"; then
      err "CAUSA: el config apunta a credenciales que no existen"
      info "        $cred"
      if [ -n "$uuid" ] && [ -f "$HOME/.cloudflared/$uuid.json" ]; then
        info "Están en ~/.cloudflared/$uuid.json — sentinel tunnel fix las copia"
      else
        info "Arreglo: sentinel tunnel setup <dominio> --recreate"
      fi
      found=1
    fi
    if command -v python3 >/dev/null 2>&1; then
      $CF_SUDO cat $CF_DIR/config.yml 2>/dev/null \
        | python3 -c 'import sys,yaml;yaml.safe_load(sys.stdin)' >/dev/null 2>&1 \
        || { err "CAUSA: el config.yml no es YAML válido"; found=1; }
    fi
  }

  # Un origen caído da 502 desde internet, no impide que cloudflared levante,
  # pero es la confusión más común: "el túnel no anda" cuando lo que no anda
  # es Sentinel.
  local port; port="$(app_port)"
  curl -sS -m3 -o /dev/null "http://localhost:$port/healthz" 2>/dev/null \
    || { warn "Además: Sentinel no responde en el puerto $port"; info "        sentinel restart server"; }

  local jlog
  jlog="$($CF_SUDO journalctl -u cloudflared -n 60 --no-pager 2>/dev/null || true)"
  if [ -n "$jlog" ]; then
    if echo "$jlog" | grep -qi 'failed to connect\|no such host\|i/o timeout\|context deadline'; then
      err "CAUSA probable: la red bloquea la salida del túnel"
      info "cloudflared usa UDP 7844 hacia Cloudflare. Si el firewall del sitio"
      info "lo bloquea, probá modo HTTP/2: sentinel tunnel fix --http2"
      found=1
    fi
    if echo "$jlog" | grep -qi 'tunnel credentials file\|not found\|Cannot determine default'; then
      err "CAUSA probable: credenciales inválidas o túnel borrado de la cuenta"
      found=1
    fi
  fi

  [ "$found" -eq 0 ] && { warn "Causa no evidente. Últimas líneas del log:"; echo "$jlog" | tail -12 | sed 's/^/      /'; }
  return 0
}

# ---------------------------------------------------------------------------
# tunnel_fix [--http2] — reparaciones idempotentes, sin tocar la cuenta
# ---------------------------------------------------------------------------
tunnel_fix() {
  local http2=0
  [ "${1:-}" = "--http2" ] && http2=1

  banner "REPARAR EL TÚNEL"
  info "No se crean ni se borran túneles. Sólo se repara este equipo."
  echo ""

  if [ ! -f $CF_DIR/config.yml ]; then
    warn "Este equipo no tiene túnel configurado: no hay nada que reparar."
    echo ""
    info "'fix' arregla una configuración existente. Para crear una:"
    echo -e "    ${B}sentinel tunnel setup <dominio>${N}"
    local libres
    libres="$(tunnel_rows | awk '$4 == "" {print "    · " $2}')"
    if [ -n "$libres" ]; then
      echo ""
      info "Túneles sin usar en la cuenta (poné su dominio y se reutilizan):"
      echo "$libres"
    fi
    echo ""
    return 1
  fi

  local uuid; uuid="$($CF_SUDO grep -m1 '^tunnel:' $CF_DIR/config.yml 2>/dev/null | awk '{print $2}')"

  step "1/4 · Credenciales"
  local cred; cred="$($CF_SUDO grep -m1 'credentials-file:' $CF_DIR/config.yml 2>/dev/null | awk '{print $2}')"
  if [ -n "$cred" ] && ! $CF_SUDO test -f "$cred"; then
    if [ -n "$uuid" ] && [ -f "$HOME/.cloudflared/$uuid.json" ]; then
      $CF_SUDO cp "$HOME/.cloudflared/$uuid.json" $CF_DIR/ && ok "Credenciales restauradas desde ~/.cloudflared"
    else
      err "No hay copia en ~/.cloudflared/$uuid.json"
      info "Hay que rehacerlo: sentinel tunnel setup <dominio> --recreate"; return 1
    fi
  else
    ok "Presentes"
  fi
  $CF_SUDO cp "$HOME/.cloudflared/cert.pem" $CF_DIR/ 2>/dev/null || true

  step "2/4 · Puerto de destino"
  local port cfg_port; port="$(app_port)"
  cfg_port="$($CF_SUDO grep -m1 'service: http://localhost:' $CF_DIR/config.yml 2>/dev/null | sed 's/.*localhost://')"
  if [ -n "$cfg_port" ] && [ "$cfg_port" != "$port" ]; then
    $CF_SUDO sed -i "s|service: http://localhost:$cfg_port|service: http://localhost:$port|" $CF_DIR/config.yml
    ok "Corregido: apuntaba al $cfg_port, Sentinel usa el $port"
  else
    ok "Coincide ($port)"
  fi

  step "3/4 · Transporte"
  if [ "$http2" -eq 1 ]; then
    $CF_SUDO sed -i '/^protocol:/d' $CF_DIR/config.yml
    $CF_SUDO sed -i "1i protocol: http2" $CF_DIR/config.yml
    ok "Forzado HTTP/2 (para redes que bloquean UDP 7844)"
  else
    $CF_SUDO grep -q '^protocol:' $CF_DIR/config.yml 2>/dev/null \
      && info "Forzado a $($CF_SUDO grep -m1 '^protocol:' $CF_DIR/config.yml | awk '{print $2}')" \
      || ok "QUIC (por defecto)"
  fi

  step "4/4 · Servicio"
  $CF_SUDO cloudflared service uninstall >/dev/null 2>&1 || true
  $CF_SUDO cloudflared service install >/dev/null 2>&1 || warn "service install devolvió error"
  $CF_SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  $CF_SUDO systemctl enable cloudflared >/dev/null 2>&1 || true
  $CF_SUDO systemctl restart cloudflared >/dev/null 2>&1 || true
  sleep 6

  echo ""
  if systemctl is-active --quiet cloudflared 2>/dev/null; then
    ok "cloudflared corriendo"
    local domain; domain="$($CF_SUDO grep -m1 'hostname:' $CF_DIR/config.yml 2>/dev/null | awk '{print $NF}')"
    if [ -n "$domain" ]; then
      echo -n "  Probando desde internet"
      local i code=000
      for i in $(seq 1 8); do
        code="$(http_code "https://$domain/healthz" 6)"
        [ "$code" = "200" ] && break
        printf "."; sleep 4
      done
      echo ""
      [ "$code" = "200" ] && echo -e "\n${G}${BOLD}  ✔ Túnel operativo${N}\n" \
        || { warn "Levantó pero desde internet da HTTP $code"; info "sentinel diagnose tunnel"; }
    fi
  else
    err "Sigue sin levantar"
    tunnel_why_down "$uuid"
    [ "$http2" -eq 0 ] && info "Si la red del sitio filtra UDP: sentinel tunnel fix --http2"
  fi
  echo ""
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
  local uuid="" domain="" no_config=0
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
    # No es lo mismo "roto" que "nunca se configuro". Mandar a 'tunnel fix' a
    # alguien que no tiene config lo hace correr un comando que se va a negar.
    warn "Este equipo no tiene túnel configurado"
    no_config=1
    problems=$((problems+1))
  fi

  step "Servicio"
  if systemctl is-active --quiet cloudflared 2>/dev/null; then
    ok "cloudflared corriendo"
  else
    err "cloudflared no está corriendo"
    problems=$((problems+1))
    tunnel_why_down "$uuid"
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
        # Con el proxy de Cloudflare activado (la nube naranja) el CNAME a
        # .cfargotunnel.com no se publica: dig devuelve las IP del proxy. No
        # poder verlo NO es un problema, y de hecho es lo normal y lo deseable.
        # La prueba que vale es la peticion real de mas abajo.
        if [ -n "$(dig +short A "$domain" @1.1.1.1 2>/dev/null | head -1)" ]; then
          ok "$domain resuelve (CNAME oculto por el proxy de Cloudflare)"
        else
          err "$domain no resuelve"
          problems=$((problems+1))
        fi
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
  elif [ "${no_config:-0}" -eq 1 ]; then
    echo -e "  ${Y}${BOLD}Falta configurar el túnel en este equipo.${N}"
    echo -e "  ${D}No hay nada roto: nunca se configuró, o se borró con remove_all.${N}"
    echo ""
    echo -e "  ${B}sentinel tunnel setup <dominio>${N}"
    local libres
    libres="$(tunnel_rows | awk '$4 == "" {print "    · " $2}')"
    if [ -n "$libres" ]; then
      echo ""
      info "Túneles de la cuenta sin usar (se reutilizan si ponés su dominio):"
      echo "$libres"
    fi
  else
    echo -e "  ${R}${BOLD}$problems problema(s).${N}"
    echo -e "\n  Primero probá reparar:  ${B}sentinel tunnel fix${N}"
    echo -e "  Si la red del sitio filtra UDP:  ${B}sentinel tunnel fix --http2${N}"
    echo -e "  ${D}Último recurso — rehacerlo:  sentinel tunnel clean && sentinel tunnel setup <dominio>${N}"
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
