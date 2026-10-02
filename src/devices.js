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
 * Manda un frame crudo al Arduino (nucleo comun, sin tocar el estado del
 * preset temporal).
 * @returns {Promise<{ok:boolean, via:string, response?:string, error?:string}>}
 */
async function rawSend(frame) {
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

// ---------------------------------------------------------------------------
// Preset temporal (saludo POI): se enciende N segundos y despues se restaura
// solo el estado anterior.
// ---------------------------------------------------------------------------

let tempState = null; // { baselineFrame, timer, preset }

// Periodo del "respirado" del saludo POI, en ms. El respirado lo hace el
// FIRMWARE (EFFECT 3): respira a 60 fps y 12 bits, suave y sin escalones. El
// servidor manda UN solo frame con EFFECT=3 y el Arduino hace el resto — nada
// de animar por software a 6 fps como antes (eso era lo que se veia escalonado).
const BREATH_PERIOD_MS = 2600;

function cancelTemporary() {
  if (!tempState) return;
  clearTimeout(tempState.timer);
  tempState = null;
}

/** El mismo frame pero con EFFECT=3 (respiracion nativa) y el periodo en ARG1
 *  (decimas de segundo). Los 5 canales de color quedan intactos. */
function toBreatheFrame(frame, periodMs) {
  const p = frame.split(',');
  p[5] = '3';
  p[6] = String(Math.max(1, Math.round(periodMs / 100)));
  p[7] = '0';
  return p.slice(0, 8).join(',');
}

/**
 * Manda un frame al Arduino (comando manual del operador o de la API).
 * Un comando manual siempre gana: si habia un preset temporal esperando
 * restaurarse, se cancela para no pisar lo que el operador acaba de elegir.
 */
async function sendFrame(frame) {
  cancelTemporary();
  return rawSend(frame);
}

/**
 * Manda un preset y lo deja `seconds` segundos; despues restaura solo el
 * estado anterior (el ultimo frame enviado, o todo apagado si no habia
 * ninguno). Si llegan dos saludos seguidos, el segundo extiende la ventana
 * pero el estado a restaurar sigue siendo el ORIGINAL, no el del saludo.
 *
 * @param {'solid'|'breathe'} mode  'breathe' => el Arduino respira el color
 *   (EFFECT 3) mientras dura la ventana; al terminar se restaura el estado
 *   anterior. 'solid' => color fijo.
 */
async function sendTemporaryFrame(frame, seconds, mode = 'solid', label = 'personalizado') {
  if (!FRAME_RE.test(frame)) {
    return { ok: false, via: 'none', error: 'Frame invalido. Formato: R,G,B,W,WW,EFFECT,ARG1,ARG2' };
  }
  const holdS = Math.max(1, Number(seconds) || 10);
  const baselineFrame = tempState
    ? tempState.baselineFrame
    : (lastCommand ? lastCommand.frame : PRESETS.off.frame);
  if (tempState) clearTimeout(tempState.timer);

  // El respirado lo resuelve el firmware: mandamos UN frame con EFFECT=3.
  const outFrame = (mode === 'breathe') ? toBreatheFrame(frame, BREATH_PERIOD_MS) : frame;

  const result = await rawSend(outFrame);
  if (!result.ok) {
    tempState = null;
    return { ...result, label };
  }

  const timer = setTimeout(() => {
    tempState = null;
    rawSend(baselineFrame).then((r) => {
      if (!r.ok) console.warn('[GPIO] No se pudo restaurar el estado previo:', r.error);
    });
  }, holdS * 1000);
  if (timer.unref) timer.unref();

  tempState = { baselineFrame, timer, preset: label };
  return { ...result, label, mode, restoresInS: holdS };
}

/** Igual que sendTemporaryFrame pero por nombre de preset. */
async function sendTemporaryPreset(name, seconds, mode = 'solid') {
  const preset = PRESETS[name];
  if (!preset) {
    return { ok: false, error: `Preset desconocido '${name}'. Validos: ${Object.keys(PRESETS).join(', ')}` };
  }
  const result = await sendTemporaryFrame(preset.frame, seconds, mode, preset.label);
  return { ...result, preset: name };
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
    temporary: tempState ? { preset: tempState.preset } : null,
  };
}

module.exports = { sendFrame, sendPreset, sendTemporaryPreset, sendTemporaryFrame, presetList, status, PRESETS };
