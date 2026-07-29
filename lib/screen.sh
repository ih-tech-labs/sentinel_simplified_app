#!/usr/bin/env bash
# =============================================================================
#  Sentinel · rotación de pantalla del kiosko
#
#  Raspberry Pi OS Bookworm puede correr Wayland (labwc en la Pi 5, wayfire en
#  modelos anteriores) o X11, y cada uno se configura distinto:
#      labwc    -> wlr-randr en ~/.config/labwc/autostart
#      wayfire  -> sección [output:NOMBRE] en ~/.config/wayfire.ini
#      X11      -> xrandr en el arranque de la sesión
#  Detectamos cuál está corriendo y escribimos donde corresponde.
# =============================================================================
[ -n "${SENTINEL_SCREEN_LOADED:-}" ] && return 0
SENTINEL_SCREEN_LOADED=1

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ROTATION_FILE="$APP_DIR/.screen_rotation"

# Reconstruye el entorno gráfico: por SSH no hay DISPLAY ni WAYLAND_DISPLAY
screen_env() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    local sock
    for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
      case "$sock" in *.lock) continue ;; esac
      [ -S "$sock" ] && { export WAYLAND_DISPLAY="$(basename "$sock")"; break; }
    done
  fi
  export DISPLAY="${DISPLAY:-:0}"
}

screen_compositor() {
  pgrep -x labwc   >/dev/null 2>&1 && { echo labwc;   return; }
  pgrep -x wayfire >/dev/null 2>&1 && { echo wayfire; return; }
  pgrep -x Xorg    >/dev/null 2>&1 && { echo x11;     return; }
  pgrep -x X       >/dev/null 2>&1 && { echo x11;     return; }
  command -v labwc   >/dev/null 2>&1 && { echo labwc;   return; }
  command -v wayfire >/dev/null 2>&1 && { echo wayfire; return; }
  command -v Xorg    >/dev/null 2>&1 && { echo x11;     return; }
  echo unknown
}

screen_output() {
  local out=""
  if command -v wlr-randr >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    out="$(wlr-randr 2>/dev/null | grep -E '^[A-Za-z][A-Za-z0-9-]*[[:space:]]' | head -1 | awk '{print $1}')"
  fi
  [ -z "$out" ] && command -v xrandr >/dev/null 2>&1 && \
    out="$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')"
  echo "${out:-HDMI-A-1}"
}

screen_show() {
  screen_env
  banner "ESTADO DE LA PANTALLA"
  info "Compositor : $(screen_compositor)"
  info "Salida     : $(screen_output)"
  [ -f "$ROTATION_FILE" ] && info "Guardado   : $(grep -m1 '^ROTATION=' "$ROTATION_FILE" | cut -d= -f2)°"
  echo ""
  if command -v wlr-randr >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    wlr-randr 2>/dev/null | sed 's/^/  /'
  elif command -v xrandr >/dev/null 2>&1; then
    xrandr 2>/dev/null | grep " connected" | sed 's/^/  /'
  fi
  echo ""
  echo -e "  Rotar:  ${B}sentinel rotate 90${N}   ${D}(horario)${N}"
  echo -e "          ${B}sentinel rotate 270${N}  ${D}(antihorario)${N}"
  echo -e "          ${B}sentinel rotate 0${N}    ${D}(sin rotación)${N}"
  echo ""
}

# screen_rotate <0|90|180|270>
screen_rotate() {
  local rot="${1:-}"
  [ -z "$rot" ] && { screen_show; return 0; }

  local wlr xr wf label
  case "$rot" in
    0)   wlr=normal; xr=normal;   wf=normal; label="sin rotación" ;;
    90)  wlr=90;     xr=right;    wf=90;     label="90° horario" ;;
    180) wlr=180;    xr=inverted; wf=180;    label="180°" ;;
    270) wlr=270;    xr=left;     wf=270;    label="90° antihorario" ;;
    *)   err "Rotación inválida: '$rot'. Usá 0, 90, 180 o 270."; return 1 ;;
  esac

  screen_env
  local comp out applied=0
  comp="$(screen_compositor)"; out="$(screen_output)"

  banner "ROTAR PANTALLA · $label"
  info "Compositor : $comp"
  info "Salida     : $out"
  echo ""

  case "$comp" in
    labwc|wayfire)
      if command -v wlr-randr >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        wlr-randr --output "$out" --transform "$wlr" 2>/dev/null && { ok "Aplicado"; applied=1; } \
          || warn "wlr-randr no pudo aplicarlo ahora (¿sin sesión gráfica?)"
      else
        warn "wlr-randr no disponible (sudo apt install -y wlr-randr)"
      fi ;;
    x11)
      command -v xrandr >/dev/null 2>&1 && {
        xrandr --output "$out" --rotate "$xr" 2>/dev/null && { ok "Aplicado"; applied=1; } \
          || warn "xrandr no pudo aplicarlo ahora"
      } ;;
    *) warn "No pude identificar el entorno gráfico" ;;
  esac

  # --- Persistencia ---
  if [ "$comp" = "labwc" ] || [ -d "$HOME/.config/labwc" ] || command -v labwc >/dev/null 2>&1; then
    mkdir -p "$HOME/.config/labwc"; touch "$HOME/.config/labwc/autostart"
    sed -i '/# sentinel-rotation/d' "$HOME/.config/labwc/autostart" 2>/dev/null || true
    [ "$rot" != "0" ] && echo "wlr-randr --output $out --transform $wlr & # sentinel-rotation" >> "$HOME/.config/labwc/autostart"
    ok "Persistido en ~/.config/labwc/autostart"
  fi

  if [ "$comp" = "wayfire" ] || [ -f "$HOME/.config/wayfire.ini" ]; then
    touch "$HOME/.config/wayfire.ini"
    python3 - "$HOME/.config/wayfire.ini" "$out" "$wf" <<'PY' 2>/dev/null && ok "Persistido en ~/.config/wayfire.ini"
import sys, re
path, output, transform = sys.argv[1], sys.argv[2], sys.argv[3]
try: text = open(path, encoding='utf-8').read()
except FileNotFoundError: text = ''
section, line_new = f'[output:{output}]', f'transform = {transform}'
if section not in text:
    if text and not text.endswith('\n'): text += '\n'
    text += f'\n{section}\n{line_new}\n'
else:
    lines = text.splitlines()
    start = next(i for i, l in enumerate(lines) if l.strip() == section)
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].strip().startswith('['): end = i; break
    replaced = False
    for i in range(start + 1, end):
        if re.match(r'\s*transform\s*=', lines[i]):
            lines[i] = line_new; replaced = True; break
    if not replaced:
        insert_at = start + 1
        for i in range(start + 1, end):
            if lines[i].strip(): insert_at = i + 1
        lines.insert(insert_at, line_new)
    text = '\n'.join(lines) + '\n'
open(path, 'w', encoding='utf-8').write(text)
PY
  fi

  if [ "$comp" = "x11" ]; then
    mkdir -p "$HOME/.config/autostart"
    if [ "$rot" = "0" ]; then
      rm -f "$HOME/.config/autostart/sentinel-rotation.desktop"
    else
      cat > "$HOME/.config/autostart/sentinel-rotation.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Sentinel · rotación de pantalla
Exec=xrandr --output $out --rotate $xr
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
EOF
    fi
    ok "Persistido en ~/.config/autostart"
  fi

  # Lo relee `sentinel kiosk` y reaplica antes de abrir Chromium
  cat > "$ROTATION_FILE" <<EOF
ROTATION=$rot
OUTPUT=$out
WLR_TRANSFORM=$wlr
XRANDR_ROTATE=$xr
EOF
  ok "Guardado en .screen_rotation"

  echo ""
  if [ "$applied" -eq 1 ]; then
    echo -e "${G}  ✔ Pantalla rotada: $label${N}"
    [ "$rot" = "90" ]  && echo -e "\n  ${Y}¿Quedó al revés?${N} ${B}sentinel rotate 270${N}"
    [ "$rot" = "270" ] && echo -e "\n  ${Y}¿Quedó al revés?${N} ${B}sentinel rotate 90${N}"
  else
    warn "Guardado. Reiniciá para verlo aplicado: sudo reboot"
  fi
  echo ""
}

# Reaplica la rotación guardada. La llama `sentinel kiosk` antes de Chromium,
# porque el compositor a veces resetea la salida cuando el monitor renegocia
# el EDID — típico si la pantalla se enciende después que la Pi.
screen_reapply() {
  [ -f "$ROTATION_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$ROTATION_FILE"
  [ "${ROTATION:-0}" = "0" ] && return 0
  screen_env
  if command -v wlr-randr >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    wlr-randr --output "$OUTPUT" --transform "$WLR_TRANSFORM" 2>/dev/null && ok "Pantalla rotada ${ROTATION}°"
  elif command -v xrandr >/dev/null 2>&1; then
    xrandr --output "$OUTPUT" --rotate "$XRANDR_ROTATE" 2>/dev/null && ok "Pantalla rotada ${ROTATION}°"
  fi
  return 0
}
