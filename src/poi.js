'use strict';

/**
 * Saludo a Personas de Interes (POI) de Verkada.
 *
 * El webhook de POI trae `person_label` (el nombre del perfil) y un
 * `image_url` con el snapshot del evento. Esa URL es de Verkada y puede ser
 * firmada con expiracion, asi que NO se le pasa al kiosko: el servidor la
 * descarga UNA vez aca y la sirve local por /poi-images/. Ademas el kiosko
 * puede estar sin salida a internet y aun asi tiene que mostrar la foto.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = require('./config');

const DIR = path.join(config.DATA_DIR, 'poi');
const MAX_BYTES = 5 * 1024 * 1024; // una foto de Verkada pesa cientos de KB
const KEEP_FILES = 40;             // historial corto: son archivos efimeros
const FETCH_TIMEOUT_MS = 8000;

const EXT_BY_MIME = {
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/webp': '.webp',
  'image/gif': '.gif',
};

function ensureDir() {
  fs.mkdirSync(DIR, { recursive: true });
}

/** Borra las fotos mas viejas para que el directorio no crezca sin limite. */
function cleanup() {
  let files;
  try {
    files = fs.readdirSync(DIR)
      .map((name) => {
        const full = path.join(DIR, name);
        try {
          return { full, mtime: fs.statSync(full).mtimeMs };
        } catch (_) {
          return null;
        }
      })
      .filter(Boolean)
      .sort((a, b) => b.mtime - a.mtime);
  } catch (_) {
    return;
  }
  for (const f of files.slice(KEEP_FILES)) {
    try { fs.unlinkSync(f.full); } catch (_) { /* ignore */ }
  }
}

/**
 * Descarga la imagen del evento y la guarda local.
 * @param {string} url  image_url que vino en el webhook
 * @returns {Promise<string|null>} ruta web local (/poi-images/xxx.jpg) o null
 */
async function fetchImage(url) {
  if (!url || !/^https?:\/\//i.test(String(url))) return null;

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);

  try {
    const res = await fetch(url, { signal: ctrl.signal, redirect: 'follow' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);

    const mime = String(res.headers.get('content-type') || '').split(';')[0].trim();
    const ext = EXT_BY_MIME[mime];
    if (!ext) throw new Error(`content-type inesperado: ${mime || 'vacio'}`);

    const declared = parseInt(res.headers.get('content-length'), 10);
    if (Number.isFinite(declared) && declared > MAX_BYTES) {
      throw new Error(`imagen demasiado grande (${declared} bytes)`);
    }

    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.byteLength === 0) throw new Error('respuesta vacia');
    if (buf.byteLength > MAX_BYTES) throw new Error(`imagen demasiado grande (${buf.byteLength} bytes)`);

    ensureDir();
    const name = crypto.randomBytes(10).toString('hex') + ext;
    fs.writeFileSync(path.join(DIR, name), buf);
    cleanup();
    return `/poi-images/${name}`;
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { fetchImage, DIR };
