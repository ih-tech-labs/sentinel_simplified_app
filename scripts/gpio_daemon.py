#!/usr/bin/env python3
"""
Sentinel · daemon de control del Arduino

POR QUE EXISTE
--------------
GPIO_control.py abre el puerto serie en cada invocacion. En un Arduino, abrir
el puerto dispara un reset por DTR, por eso el script original tenia un
time.sleep(2) fijo. Resultado: 2 segundos de latencia y un parpadeo del
Arduino en CADA comando.

Este daemon mantiene el puerto abierto de por vida y escucha comandos en
127.0.0.1:8765. Latencia: milisegundos. Sin resets.

PROTOCOLO
---------
    -> "R,G,B,W,WW,EFFECT,ARG1,ARG2\\n"     enviar frame
    -> "PING\\n"                             chequeo de vida
    <- "OK <frame>\\n"  |  "ERR <motivo>\\n"

Uso:
    python3 gpio_daemon.py [--port 8765] [--device /dev/ttyACM0] [--baud 9600]
"""

import argparse
import re
import socket
import socketserver
import sys
import threading
import time

try:
    from serial import Serial, SerialException
    from serial.tools.list_ports import comports
except ImportError:
    print("❌ Falta pyserial. Instalar con: pip3 install pyserial --break-system-packages")
    sys.exit(1)


FRAME_RE = re.compile(r'^-?\d+(,-?\d+){7}$')

_lock = threading.Lock()
_serial = None
_device_hint = None
_baud = 9600


# ---------------------------------------------------------------------------
# Puerto serie
# ---------------------------------------------------------------------------

def find_device():
    """Busca un Arduino entre los puertos disponibles."""
    if _device_hint:
        return _device_hint
    for p in comports():
        desc = (p.description or "").lower()
        dev = (p.device or "")
        if "acm" in dev.lower() or "usb" in dev.lower():
            return dev
        if "arduino" in desc or "ch340" in desc or "ftdi" in desc:
            return dev
    return None


def open_serial():
    """Abre (o reabre) el puerto. Devuelve el objeto Serial o None."""
    global _serial

    if _serial is not None and _serial.is_open:
        return _serial

    device = find_device()
    if not device:
        return None

    try:
        _serial = Serial(device, _baud, timeout=1, write_timeout=2)
        # Unica espera del reset por DTR, al arrancar el daemon
        time.sleep(2)
        _serial.reset_input_buffer()
        print(f"[GPIO] Conectado a {device} @ {_baud}", flush=True)
        return _serial
    except SerialException as e:
        print(f"[GPIO] No se pudo abrir {device}: {e}", flush=True)
        _serial = None
        return None


def _reader_loop():
    """
    Lee de forma continua lo que el Arduino manda de vuelta.

    Sin esto no hay forma de saber si el firmware está recibiendo bien: uno
    escribe al puerto, no falla nada, y las luces no se mueven. Cualquier
    respuesta, eco o mensaje de error del Arduino queda en el log con la
    marca RX y se puede ver con `sentinel gpio monitor`.
    """
    buf = b""
    while True:
        try:
            ser = _serial
            if ser is None or not ser.is_open:
                time.sleep(1)
                continue
            data = ser.read(128)
            if not data:
                continue
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode(errors="replace").strip()
                if text:
                    print("[GPIO] RX <- %s" % text, flush=True)
            if len(buf) > 512:
                print("[GPIO] RX <- %s (sin fin de linea)" % buf.decode(errors="replace").strip(), flush=True)
                buf = b""
        except Exception as e:
            print("[GPIO] Error leyendo: %s" % e, flush=True)
            time.sleep(1)


def send(frame):
    """Envia un frame. Reintenta una vez reabriendo el puerto si se cayo."""
    global _serial

    with _lock:
        for attempt in (1, 2):
            ser = open_serial()
            if ser is None:
                return False, "Arduino no detectado"
            try:
                payload = (frame + "\n").encode()
                ser.write(payload)
                ser.flush()
                print("[GPIO] TX -> %s  (%d bytes por %s)" % (frame, len(payload), ser.port), flush=True)
                return True, frame
            except (SerialException, OSError) as e:
                print(f"[GPIO] Error de escritura (intento {attempt}): {e}", flush=True)
                try:
                    ser.close()
                except Exception:
                    pass
                _serial = None
                if attempt == 2:
                    return False, str(e)
        return False, "desconocido"


# ---------------------------------------------------------------------------
# Servidor TCP
# ---------------------------------------------------------------------------

class Handler(socketserver.StreamRequestHandler):
    timeout = 10

    def handle(self):
        try:
            line = self.rfile.readline(256).decode(errors="ignore").strip()
        except Exception:
            return
        if not line:
            return

        if line.upper() == "PING":
            alive = _serial is not None and _serial.is_open
            self.wfile.write(f"OK {'connected' if alive else 'disconnected'}\n".encode())
            return

        if not FRAME_RE.match(line):
            self.wfile.write(b"ERR formato invalido (R,G,B,W,WW,EFFECT,ARG1,ARG2)\n")
            return

        ok, info = send(line)
        prefix = "OK" if ok else "ERR"
        print(f"[GPIO] {prefix} {info}", flush=True)
        try:
            self.wfile.write(f"{prefix} {info}\n".encode())
        except Exception:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    address_family = socket.AF_INET


def main():
    global _device_hint, _baud

    ap = argparse.ArgumentParser(description="Daemon de control del Arduino para Sentinel")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--device", default=None, help="ej: /dev/ttyACM0 (autodetecta si se omite)")
    ap.add_argument("--baud", type=int, default=9600)
    args = ap.parse_args()

    _device_hint = args.device
    _baud = args.baud

    if open_serial() is None:
        print("[GPIO] ⚠️  Arduino no detectado al arrancar. "
              "El daemon sigue vivo y reintenta en cada comando.", flush=True)

    # Reconexion en segundo plano por si se enchufa despues
    def reconnector():
        while True:
            time.sleep(15)
            if _serial is None or not _serial.is_open:
                with _lock:
                    open_serial()

    threading.Thread(target=reconnector, daemon=True).start()
    threading.Thread(target=_reader_loop, daemon=True).start()

    with Server((args.host, args.port), Handler) as srv:
        print(f"[GPIO] Escuchando en {args.host}:{args.port}", flush=True)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\n[GPIO] Cerrando", flush=True)
        finally:
            if _serial is not None and _serial.is_open:
                _serial.close()


if __name__ == "__main__":
    main()
