'use strict';

/**
 * Historial de alarmas.
 *
 * Deliberadamente SIN base de datos: en una RPi 5 que corre 24/7 un modulo
 * nativo (better-sqlite3) es un punto de falla mas en cada `npm install` y en
 * cada actualizacion de Node. Para el volumen de este sitio alcanza y sobra con:
 *
 *   - un ring buffer en memoria (consultas instantaneas, cero I/O)
 *   - un append-only JSONL en disco con rotacion (persistencia entre reinicios)
 *
 * Cero dependencias nativas, cero migraciones, cero riesgo de corrupcion.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = require('./config');

const FILE = path.join(config.DATA_DIR, 'events.jsonl');
const ROTATED = path.join(config.DATA_DIR, 'events.1.jsonl');

let memory = [];      // mas nuevo primero
let writeStream = null;

function ensureDir() {
  try {
    fs.mkdirSync(config.DATA_DIR, { recursive: true });
    return true;
  } catch (err) {
    console.error('[EVENTS] No se pudo crear DATA_DIR:', err.message);
    return false;
  }
}

function openStream() {
  if (!ensureDir()) return;
  try {
    writeStream = fs.createWriteStream(FILE, { flags: 'a' });
    writeStream.on('error', (e) => {
      console.error('[EVENTS] Error de escritura:', e.message);
      writeStream = null;
    });
  } catch (err) {
    console.error('[EVENTS] No se pudo abrir el log:', err.message);
  }
}

function rotateIfNeeded() {
  try {
    const st = fs.statSync(FILE);
    if (st.size < config.EVENTS_FILE_MAX_BYTES) return;
    if (writeStream) {
      writeStream.end();
      writeStream = null;
    }
    fs.renameSync(FILE, ROTATED);
    console.log('[EVENTS] Log rotado');
    openStream();
  } catch (_) {
    /* el archivo puede no existir todavia */
  }
}

/** Carga en memoria las ultimas N lineas del log al arrancar. */
function load() {
  ensureDir();
  const collected = [];
  for (const f of [FILE, ROTATED]) {
    if (collected.length >= config.EVENTS_MEMORY_LIMIT) break;
    let raw;
    try {
      raw = fs.readFileSync(f, 'utf8');
    } catch (_) {
      continue;
    }
    const lines = raw.split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line) continue;
      try {
        collected.push(JSON.parse(line));
      } catch (_) {
        /* linea truncada por un corte de luz: se ignora */
      }
      if (collected.length >= config.EVENTS_MEMORY_LIMIT) break;
    }
  }
  memory = collected;
  openStream();
  console.log(`[EVENTS] ${memory.length} eventos cargados en memoria`);
}

/**
 * Registra un evento.
 * @returns {object} el evento normalizado (con id y ts)
 */
function record(evt) {
  const entry = {
    id: crypto.randomUUID ? crypto.randomUUID() : crypto.randomBytes(16).toString('hex'),
    ts: Date.now(),
    kioskId: evt.kioskId || null,
    camera: evt.camera || 'Desconocida',
    cameraId: evt.cameraId || null,
    type: evt.type || 'unknown',
    severity: evt.severity || 'alert',   // alert | info | test | system
    source: evt.source || 'verkada',     // verkada | manual | system
    details: evt.details || '',
    ack: false,
    ackBy: null,
    ackAt: null,
  };

  memory.unshift(entry);
  if (memory.length > config.EVENTS_MEMORY_LIMIT) memory.length = config.EVENTS_MEMORY_LIMIT;

  if (!writeStream) openStream();
  if (writeStream) {
    writeStream.write(JSON.stringify(entry) + '\n', (err) => {
      if (err) console.error('[EVENTS] write fallo:', err.message);
    });
    rotateIfNeeded();
  }

  return entry;
}

/** Marca un evento como reconocido por el operador. */
function acknowledge(id, user) {
  const evt = memory.find((e) => e.id === id);
  if (!evt) return null;
  if (evt.ack) return evt;
  evt.ack = true;
  evt.ackBy = user || 'operador';
  evt.ackAt = Date.now();
  if (writeStream) {
    writeStream.write(JSON.stringify({ ...evt, _op: 'ack' }) + '\n', () => {});
  }
  return evt;
}

/** Marca como reconocidos todos los eventos pendientes. */
function acknowledgeAll(user) {
  const changed = [];
  for (const evt of memory) {
    if (!evt.ack) {
      evt.ack = true;
      evt.ackBy = user || 'operador';
      evt.ackAt = Date.now();
      changed.push(evt);
    }
  }
  if (writeStream && changed.length) {
    for (const evt of changed) writeStream.write(JSON.stringify({ ...evt, _op: 'ack' }) + '\n', () => {});
  }
  return changed;
}

/**
 * Consulta con filtros.
 * @param {{kioskId?:string, severity?:string, since?:number, limit?:number, onlyPending?:boolean}} q
 */
function query(q = {}) {
  const limit = Math.min(parseInt(q.limit, 10) || 100, config.EVENTS_MEMORY_LIMIT);
  let out = memory;

  if (q.kioskId && q.kioskId !== 'all') out = out.filter((e) => e.kioskId === q.kioskId);
  if (q.severity && q.severity !== 'all') out = out.filter((e) => e.severity === q.severity);
  if (q.since) out = out.filter((e) => e.ts >= Number(q.since));
  if (q.onlyPending) out = out.filter((e) => !e.ack);

  return out.slice(0, limit);
}

/** Resumen para los contadores del header. */
function stats() {
  const now = Date.now();
  const day = 24 * 60 * 60 * 1000;
  const last24 = memory.filter((e) => now - e.ts < day);
  const byKiosk = {};
  for (const e of last24) {
    if (!e.kioskId) continue;
    byKiosk[e.kioskId] = (byKiosk[e.kioskId] || 0) + 1;
  }
  return {
    total: memory.length,
    last24h: last24.length,
    pending: memory.filter((e) => !e.ack).length,
    byKiosk,
    lastEventTs: memory.length ? memory[0].ts : null,
  };
}

function shutdown() {
  if (writeStream) {
    try {
      writeStream.end();
    } catch (_) {
      /* ignore */
    }
    writeStream = null;
  }
}

module.exports = { load, record, acknowledge, acknowledgeAll, query, stats, shutdown };
