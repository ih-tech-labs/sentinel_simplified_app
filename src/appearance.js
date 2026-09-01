'use strict';

/**
 * Apariencia del kiosko, editable desde el backoffice.
 *
 * Guarda tipografia, tamanios, color de texto y visibilidad de widgets en
 * config/appearance.json (fuera del repo, como cameras.json: es config del
 * sitio). Si el archivo no existe se usan los defaults y el kiosko se ve
 * exactamente como siempre — no hay paso de migracion.
 *
 * Las fuentes son una lista curada de stacks del sistema, NO webfonts:
 * en una RPi que puede quedarse sin internet un @import de Google Fonts
 * bloquea el render (misma decision que en tokens.css).
 */

const fs = require('fs');
const path = require('path');
const config = require('./config');

const FILE = path.join(config.ROOT, 'config', 'appearance.json');

const FONT_STACKS = {
  default: '"Inter", "Segoe UI", "Noto Sans", "DejaVu Sans", system-ui, sans-serif',
  system: 'system-ui, -apple-system, "Segoe UI", "Noto Sans", sans-serif',
  serif: '"Noto Serif", Georgia, "Times New Roman", "DejaVu Serif", serif',
  mono: '"JetBrains Mono", "SF Mono", "Roboto Mono", "DejaVu Sans Mono", ui-monospace, monospace',
  condensed: '"Arial Narrow", "Liberation Sans Narrow", "DejaVu Sans Condensed", "Noto Sans", sans-serif',
};

const FONT_LABELS = {
  default: 'Moderna (Inter)',
  system: 'Sistema',
  serif: 'Serif clásica',
  mono: 'Monoespaciada',
  condensed: 'Condensada',
};

const DEFAULTS = Object.freeze({
  fontFamily: 'default',
  textColor: '#ffffff',
  clockScale: 1,    // multiplica el tamanio del reloj (0.5 a 2)
  textScale: 1,     // multiplica fecha, clima y linea de estado (0.5 a 2)
  widgets: Object.freeze({ clock: true, date: true, weather: true, status: true }),
});

let current = load();

// ---------------------------------------------------------------------------
// Saneo: nunca confiar en lo que llega del navegador ni en lo que haya
// quedado en el JSON (pudo editarlo alguien a mano).
// ---------------------------------------------------------------------------

function clampScale(v, fallback) {
  const n = Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(2, Math.max(0.5, Math.round(n * 100) / 100));
}

function sanitize(raw) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const out = {
    fontFamily: Object.prototype.hasOwnProperty.call(FONT_STACKS, src.fontFamily)
      ? src.fontFamily
      : DEFAULTS.fontFamily,
    textColor: /^#[0-9a-fA-F]{6}$/.test(String(src.textColor || ''))
      ? String(src.textColor).toLowerCase()
      : DEFAULTS.textColor,
    clockScale: clampScale(src.clockScale, DEFAULTS.clockScale),
    textScale: clampScale(src.textScale, DEFAULTS.textScale),
    widgets: {},
  };
  const w = src.widgets && typeof src.widgets === 'object' ? src.widgets : {};
  for (const key of Object.keys(DEFAULTS.widgets)) {
    out.widgets[key] = w[key] === undefined ? DEFAULTS.widgets[key] : Boolean(w[key]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Persistencia
// ---------------------------------------------------------------------------

function load() {
  try {
    const raw = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    return sanitize(raw);
  } catch (_) {
    return sanitize({}); // sin archivo (o roto): defaults
  }
}

function persist() {
  // Escritura atomica: tmp + rename. Un corte de luz en el medio deja el
  // archivo anterior intacto en vez de un JSON truncado.
  const tmp = FILE + '.tmp';
  fs.mkdirSync(path.dirname(FILE), { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(current, null, 2) + '\n');
  fs.renameSync(tmp, FILE);
}

// ---------------------------------------------------------------------------
// API del modulo
// ---------------------------------------------------------------------------

/** Config actual, tal como se guarda. */
function get() {
  return JSON.parse(JSON.stringify(current));
}

/** Config actual + el stack de fuentes resuelto, listo para el kiosko. */
function publicConfig() {
  const cfg = get();
  cfg.fontStack = FONT_STACKS[cfg.fontFamily] || FONT_STACKS.default;
  return cfg;
}

/**
 * Aplica cambios y persiste.
 * @param {object} patch  campos a cambiar; { reset: true } vuelve a defaults
 */
function set(patch) {
  if (patch && patch.reset === true) {
    current = sanitize({});
  } else {
    current = sanitize({ ...current, ...patch });
  }
  persist();
  return get();
}

/** Opciones de tipografia para el <select> del backoffice. */
function fontOptions() {
  return Object.keys(FONT_STACKS).map((key) => ({ key, label: FONT_LABELS[key] || key }));
}

module.exports = { get, set, publicConfig, fontOptions, DEFAULTS, FILE };
