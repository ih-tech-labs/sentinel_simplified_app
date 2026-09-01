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

let tempState = null; // { baselineFrame, timer, anim, preset }

function cancelTemporary() {
  if (!tempState) return;
  clearTimeout(tempState.timer);
  if (tempState.anim) clearInterval(tempState.anim);
  tempState = null;
}

/**
 * Animacion de respiracion: reescala los 5 canales de color con una senoidal
 * y manda un frame cada ~160 ms DIRECTO al daemon (nunca por el CLI: cada
 * invocacion del CLI resetea al Arduino, seria un desastre a 6 fps).
 * Si el daemon deja de responder, la animacion se detiene sola y queda el
 * color fijo del ultimo frame bueno.
 */
function startBreathing(frame) {
  const parts = frame.split(',').map(Number);
  const channels = parts.slice(0, 5);
  const tail = parts.slice(5).join(',');
  let phase = 0;
  let inFlight = false;

  const anim = setInterval(() => {
    if (inFlight) return; // no encolar si el daemon viene atrasado
    phase += 0.55; // ciclo completo cada ~1.8 s
    const scale = 0.12 + 0.88 * (0.5 + 0.5 * Math.sin(phase));
    const breathed = channels.map((c) => Math.round(c * scale)).join(',') + ',' + tail;
    inFlight = true;
    sendViaDaemon(breathed, 1500)
      .then(() => { inFlight = false; })
      .catch(() => {
        inFlight = false;
        if (tempState && tempState.anim === anim) {
          clearInterval(anim);
          tempState.anim = null;
        }
      });
  }, 160);
  if (anim.unref) anim.unref();
  return anim;
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
 * @param {'solid'|'breathe'} mode  'breathe' hace respirar el color mientras
 *   dura la ventana (requiere el daemon; sin daemon cae a color fijo).
 */
async function sendTemporaryPreset(name, seconds, mode = 'solid') {
  const preset = PRESETS[name];
  if (!preset) {
    return { ok: false, error: `Preset desconocido '${name}'. Validos: ${Object.keys(PRESETS).join(', ')}` };
  }
  const holdS = Math.max(1, Number(seconds) || 10);
  const baselineFrame = tempState
    ? tempState.baselineFrame
    : (lastCommand ? lastCommand.frame : PRESETS.off.frame);
  if (tempState) clearTimeout(tempState.timer);

  if (tempState && tempState.anim) clearInterval(tempState.anim);

  const result = await rawSend(preset.frame);
  if (!result.ok) {
    tempState = null;
    return { ...result, preset: name, label: preset.label };
  }

  // Respiracion solo si el frame inicial salio por el daemon: es la prueba
  // de que hay daemon vivo para sostener la animacion.
  const anim = (mode === 'breathe' && result.via === 'daemon')
    ? startBreathing(preset.frame)
    : null;

  const timer = setTimeout(() => {
    if (tempState && tempState.anim) clearInterval(tempState.anim);
    tempState = null;
    rawSend(baselineFrame).then((r) => {
      if (!r.ok) console.warn('[GPIO] No se pudo restaurar el estado previo:', r.error);
    });
  }, holdS * 1000);
  if (timer.unref) timer.unref();

  tempState = { baselineFrame, timer, anim, preset: name };
  return { ...result, preset: name, label: preset.label, mode: anim ? 'breathe' : 'solid', restoresInS: holdS };
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

module.exports = { sendFrame, sendPreset, sendTemporaryPreset, presetList, status, PRESETS };
