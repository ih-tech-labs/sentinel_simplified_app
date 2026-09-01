#!/usr/bin/env bash
# =============================================================================
#  Sentinel · grabación del firmware de la torre de luces
#
#  Uso (en la Raspberry Pi, con el Arduino conectado por USB):
#      cd ~/sentinel/firmware && ./flash.sh
#      ./flash.sh --board nano          # Arduino Nano (bootloader nuevo)
#      ./flash.sh --board nano-old      # Nano con bootloader viejo (clones)
#      ./flash.sh --port /dev/ttyUSB0   # forzar el puerto
#
#  Se ocupa de todo: instala arduino-cli si falta, baja el core AVR y la
#  librería del PCA9685, detiene el daemon (que tiene tomado el puerto serie),
#  compila, graba y vuelve a levantar el daemon.
# =============================================================================
set -euo pipefail

BOARD="uno"
PORT=""
SKETCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sentinel_lights"

while [ $# -gt 0 ]; do
  case "$1" in
    --board) BOARD="$2"; shift 2 ;;
    --port)  PORT="$2";  shift 2 ;;
    *) echo "Opción desconocida: $1"; exit 1 ;;
  esac
done

case "$BOARD" in
  uno)      FQBN="arduino:avr:uno" ;;
  nano)     FQBN="arduino:avr:nano" ;;
  nano-old) FQBN="arduino:avr:nano:cpu=atmega328old" ;;
  *) echo "Placa desconocida '$BOARD' (válidas: uno, nano, nano-old)"; exit 1 ;;
esac

echo "==> Sketch: $SKETCH_DIR"
echo "==> Placa : $FQBN"

# --- 1. arduino-cli ----------------------------------------------------------
if ! command -v arduino-cli >/dev/null 2>&1; then
  echo "==> Instalando arduino-cli..."
  case "$(uname -m)" in
    aarch64)        ARCH="ARM64" ;;
    armv7l|armv6l)  ARCH="ARMv7" ;;
    x86_64)         ARCH="64bit" ;;
    *) echo "Arquitectura no soportada: $(uname -m)"; exit 1 ;;
  esac
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/cli.tar.gz" \
    "https://github.com/arduino/arduino-cli/releases/latest/download/arduino-cli_latest_Linux_${ARCH}.tar.gz"
  tar -xzf "$TMP/cli.tar.gz" -C "$TMP" arduino-cli
  sudo mv "$TMP/arduino-cli" /usr/local/bin/
  rm -rf "$TMP"
fi
echo "==> $(arduino-cli version)"

# --- 2. Core AVR + librería --------------------------------------------------
arduino-cli config init --overwrite >/dev/null 2>&1 || true
arduino-cli core update-index >/dev/null
arduino-cli core list | grep -q "^arduino:avr" || arduino-cli core install arduino:avr
arduino-cli lib list 2>/dev/null | grep -qi "Adafruit PWM Servo Driver" \
  || arduino-cli lib install "Adafruit PWM Servo Driver Library"

# --- 3. Puerto ---------------------------------------------------------------
if [ -z "$PORT" ]; then
  PORT="$(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | head -1 || true)"
fi
[ -n "$PORT" ] || { echo "❌ No se detectó el Arduino (¿está conectado por USB?)"; exit 1; }
echo "==> Puerto: $PORT"

# --- 4. Liberar el puerto (el daemon lo tiene abierto) -------------------------
DAEMON_WAS_RUNNING=0
if command -v pm2 >/dev/null 2>&1 && pm2 describe sentinel-gpio >/dev/null 2>&1; then
  echo "==> Deteniendo el daemon GPIO (tiene tomado el puerto serie)..."
  pm2 stop sentinel-gpio >/dev/null && DAEMON_WAS_RUNNING=1
  sleep 1
fi
restore_daemon() {
  if [ "$DAEMON_WAS_RUNNING" = "1" ]; then
    echo "==> Levantando el daemon GPIO de nuevo..."
    pm2 restart sentinel-gpio >/dev/null || true
  fi
}
trap restore_daemon EXIT

# --- 5. Compilar y grabar ------------------------------------------------------
echo "==> Compilando..."
arduino-cli compile --fqbn "$FQBN" "$SKETCH_DIR"
echo "==> Grabando..."
arduino-cli upload --fqbn "$FQBN" --port "$PORT" "$SKETCH_DIR"

echo ""
echo "✅ Firmware grabado."
echo "   Probalo con:  cd ~/sentinel && ./sentinel gpio test"
echo "   Para ver qué contesta el Arduino:  ./sentinel gpio monitor"
echo "   (al arrancar imprime SENTINEL-LIGHTS v1.0 con la dirección del PCA9685)"
