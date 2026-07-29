'use strict';

/**
 * Configuración de cámaras / puestos.
 *
 * La fuente de verdad es  config/cameras.json  (lo genera install.sh).
 * Si ese archivo no existe se usan los valores por defecto de más abajo, que
 * son los del sitio original — así una instalación existente sigue andando
 * exactamente igual sin tocar nada.
 *
 * Para agregar o cambiar una cámara: editá config/cameras.json y reiniciá
 * (pm2 restart sentinel-v5). No hace falta tocar este archivo.
 */

const fs = require('fs');
const path = require('path');

const CONFIG_FILE = path.join(__dirname, '..', 'config', 'cameras.json');

// ---------------------------------------------------------------------------
// Valores por defecto (sitio original)
// ---------------------------------------------------------------------------

const DEFAULTS = {
  site: 'Sentinel',
  cameras: [
    {
      deviceId: '4b5525c7-fc5a-4616-8f0f-5ad21a92c45e',
      id: 'admin',
      name: 'Administración',
      shortName: 'ADMIN',
      zone: 'Planta Baja',
      triggerVideo: true,
      sound: true,
      allowedEvents: ['alert_rule_line_crossing', 'alert_rule_motion'],
      rtspUrl:
        'rtsp://admin:Admin0962@dc58d86505200da3b7675766a03f287a.14.camera.verkada-lan.com:8554/standard',
    },
    {
      deviceId: '95b12b72-e081-488b-9ad5-f8ea6f1223b7',
      id: 'tenis',
      name: 'House Tenis',
      shortName: 'TENIS',
      zone: 'Sector Deportivo',
      triggerVideo: true,
      sound: true,
      allowedEvents: ['alert_rule_line_crossing', 'alert_rule_motion'],
      rtspUrl:
        'rtsp://admin:Admin0962@2f206bcb1ad24144a5192eaf72758885.5.camera.verkada-lan.com:8554/standard',
    },
  ],
};

// ---------------------------------------------------------------------------
// Carga y normalización
// ---------------------------------------------------------------------------

const SLUG_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;

function normalize(cam, index) {
  const id = String(cam.id || `cam${index + 1}`).trim().toLowerCase();

  if (!SLUG_RE.test(id)) {
    throw new Error(
      `cameras.json: el id "${cam.id}" no es válido. ` +
      'Usá sólo minúsculas, números, guiones y guiones bajos (ej: "entrada-principal").'
    );
  }
  if (!cam.rtspUrl) {
    console.warn(`[CAMERAS] "${id}" no tiene rtspUrl: no va a tener video en el backoffice`);
  }

  return {
    // deviceId es el identificador de Verkada. Si no se usa webhook queda null
    // y esa cámara simplemente no recibe alarmas automáticas.
    deviceId: cam.deviceId ? String(cam.deviceId).trim() : null,
    id,
    name: String(cam.name || id).trim(),
    shortName: String(cam.shortName || id).trim().toUpperCase().slice(0, 12),
    zone: String(cam.zone || '').trim(),
    rtspUrl: cam.rtspUrl ? String(cam.rtspUrl).trim() : null,
    triggerVideo: cam.triggerVideo !== false,
    sound: cam.sound !== false,
    // allowedEvents null/ausente = aceptar todos los tipos de evento
    allowedEvents: Array.isArray(cam.allowedEvents) && cam.allowedEvents.length
      ? cam.allowedEvents.map(String)
      : null,
  };
}

function load() {
  let raw = DEFAULTS;
  let source = 'valores por defecto';

  if (fs.existsSync(CONFIG_FILE)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
      if (!Array.isArray(parsed.cameras) || parsed.cameras.length === 0) {
        throw new Error('la clave "cameras" debe ser un array con al menos una cámara');
      }
      raw = parsed;
      source = 'config/cameras.json';
    } catch (err) {
      console.error('');
      console.error('  ✘ No se pudo leer config/cameras.json:', err.message);
      console.error('    Se usan los valores por defecto. Revisá el archivo y reiniciá.');
      console.error('');
    }
  }

  const cameras = raw.cameras.map(normalize);

  // Los ids duplicados romperían el ruteo de rooms y los ids del DOM
  const seen = new Set();
  for (const c of cameras) {
    if (seen.has(c.id)) throw new Error(`cameras.json: el id "${c.id}" está repetido`);
    seen.add(c.id);
  }

  // A stderr, no a stdout: este módulo lo requieren scripts que capturan su
  // salida (`node -e '...cameras...'`), y una línea de log en el medio les
  // rompe el valor que están leyendo.
  console.error(`[CAMERAS] ${cameras.length} puesto(s) desde ${source}: ${cameras.map((c) => c.id).join(', ')}`);

  return { site: String(raw.site || 'Sentinel'), cameras };
}

/**
 * Un cameras.json con ids inválidos o repetidos es un error de configuración,
 * no algo que se pueda "arreglar" cayendo a los valores por defecto: arrancar
 * con las cámaras de otro sitio sería peor que no arrancar. Por eso acá
 * cortamos, pero con un mensaje legible en vez de un stack trace, para que
 * quien mire `pm2 logs` entienda qué tocar.
 */
let CONFIG;
try {
  CONFIG = load();
} catch (err) {
  console.error('');
  console.error('  ══════════════════════════════════════════════════════');
  console.error('   ERROR DE CONFIGURACIÓN — el servidor no puede arrancar');
  console.error('  ══════════════════════════════════════════════════════');
  console.error('');
  console.error(`   ${err.message}`);
  console.error('');
  console.error(`   Archivo: ${CONFIG_FILE}`);
  console.error('   Corregilo y reiniciá con:  pm2 restart sentinel');
  console.error('   O volvé a correr el asistente:  ./install.sh --reconfigure');
  console.error('');
  process.exit(1);
}

const CAMERA_LIST = CONFIG.cameras;
const SITE = CONFIG.site;

/** Índice por device_id de Verkada (sólo cámaras que lo tengan). */
const BY_DEVICE = new Map();
for (const cam of CAMERA_LIST) {
  if (cam.deviceId) BY_DEVICE.set(cam.deviceId, cam);
}

/** Índice por slug corto. */
const BY_SLUG = new Map(CAMERA_LIST.map((c) => [c.id, c]));

function byDeviceId(deviceId) {
  return BY_DEVICE.get(deviceId) || null;
}

function bySlug(slug) {
  return BY_SLUG.get(String(slug || '').toLowerCase()) || null;
}

/** Versión segura para el browser: sin credenciales RTSP. */
function publicList() {
  return CAMERA_LIST.map(({ id, name, shortName, zone, deviceId }) => ({
    id,
    name,
    shortName,
    zone,
    deviceId,
  }));
}

module.exports = { CAMERA_LIST, SITE, byDeviceId, bySlug, publicList };
