'use strict';

/**
 * Puente hacia el Arduino (luces, sirena, luz de emergencia).
 *
 * PROBLEMA DE LA v4: cada comando hacia `python3 GPIO_control.py`, que abria
 * el puerto serie de cero. Abrir el serial RESETEA al Arduino, por eso el
 * script tenia un `time.sleep(2)` fijo -> 2 segundos de latencia por comando
 * y un parpadeo del Arduino cada vez.
 *
 * SOLUCION: un daemon Python (scripts/gpio_daemon.py) mantiene el puerto
 * abierto y escucha en 127.0.0.1:8765. Node le manda una linea de texto y
 * listo: latencia de milisegundos y sin resets.
 *
 * FALLBACK: si el daemon no responde, se cae al script CLI de siempre, asi
 * que el sistema sigue funcionando aunque el daemon no este levantado.
 */

const net = require('net');
const { execFile } = require('child_process');
const config = require('./config');

/** Frames "R,G,B,W,WW,EFFECT,ARG1,ARG2" que entiende el firmware. */
const PRESETS = {
  off: { frame: '0,0,0,0,0,0,0,0', label: 'Apagar todo', kind: 'off' },
  white: { frame: '0,0,0,255,0,0,0,0', label: 'Luz blanca', kind: 'light' },
  warm: { frame: '0,0,0,0,255,0,0,0', label: 'Luz cálida', kind: 'light' },
  blue: { frame: '0,0,255,0,0,0,0,0', label: 'Azul', kind: 'light' },
  green: { frame: '0,255,0,0,0,0,0,0', label: 'Verde', kind: 'light' },
  red: { frame: '255,0,0,0,0,0,0,0', label: 'Rojo', kind: 'light' },
  yellow: { frame: '255,255,0,0,0,0,0,0', label: 'Ámbar', kind: 'light' },
  siren: { frame: '255,0,0,0,0,1,0,0', label: 'Sirena', kind: 'alarm' },
  emergency: { frame: '255,255,0,255,0,2,0,0', label: 'Emergencia', kind: 'alarm' },
};

const FRAME_RE = /^-?\d+(,-?\d+){7}$/;

let lastCommand = null;
let daemonHealthy = null; // null = sin probar todavia

function sendViaDaemon(frame, timeoutMs = 2500) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({
      host: config.GPIO_HOST,
      port: config.GPIO_PORT,
      timeout: timeoutMs,
    });

    let response = '';
    let settled = false;

    const finish = (fn, arg) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      fn(arg);
    };

    socket.on('connect', () => socket.write(frame + '\n'));
    socket.on('data', (d) => {
      response += d.toString();
      if (response.includes('\n')) finish(resolve, response.trim());
    });
    socket.on('timeout', () => finish(reject, new Error('timeout del daemon GPIO')));
    socket.on('error', (err) => finish(reject, err));
    socket.on('close', () => {
      if (!settled) finish(response ? resolve : reject, response.trim() || new Error('daemon cerro sin responder'));
    });
  });
}

function sendViaCli(frame, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    execFile('python3', [config.GPIO_SCRIPT, frame], { timeout: timeoutMs }, (err, stdout, stderr) => {
      if (err) return reject(new Error((stderr || err.message).trim().slice(0, 200)));
      resolve((stdout || '').trim());
    });
  });
}

/**
 * Manda un frame crudo al Arduino.
 * @returns {Promise<{ok:boolean, via:string, response?:string, error?:string}>}
 */
async function sendFrame(frame) {
  if (!config.GPIO_ENABLED) {
    return { ok: false, via: 'none', error: 'Control de dispositivos deshabilitado (GPIO_ENABLED=false)' };
  }
  if (!FRAME_RE.test(frame)) {
    return { ok: false, via: 'none', error: 'Frame invalido. Formato: R,G,B,W,WW,EFFECT,ARG1,ARG2' };
  }

  lastCommand = { frame, at: Date.now() };

  try {
    const response = await sendViaDaemon(frame);
    daemonHealthy = true;
    return { ok: true, via: 'daemon', response };
  } catch (daemonErr) {
    daemonHealthy = false;
    try {
      const response = await sendViaCli(frame);
      return { ok: true, via: 'cli', response, warning: `daemon no disponible (${daemonErr.message})` };
    } catch (cliErr) {
      return {
        ok: false,
        via: 'none',
        error: `Arduino no responde. daemon: ${daemonErr.message} | cli: ${cliErr.message}`,
      };
    }
  }
}

/** Manda un preset por nombre. */
async function sendPreset(name) {
  const preset = PRESETS[name];
  if (!preset) {
    return { ok: false, error: `Preset desconocido '${name}'. Validos: ${Object.keys(PRESETS).join(', ')}` };
  }
  const result = await sendFrame(preset.frame);
  return { ...result, preset: name, label: preset.label };
}

/** Lista de presets para dibujar los botones del backoffice. */
function presetList() {
  return Object.entries(PRESETS).map(([key, v]) => ({ key, label: v.label, kind: v.kind }));
}

function status() {
  return {
    enabled: config.GPIO_ENABLED,
    daemon: { host: config.GPIO_HOST, port: config.GPIO_PORT, healthy: daemonHealthy },
    lastCommand,
  };
}

module.exports = { sendFrame, sendPreset, presetList, status, PRESETS };
