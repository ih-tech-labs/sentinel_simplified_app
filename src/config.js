'use strict';

const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

// Carga .env desde la raiz del proyecto (v5/.env)
const ROOT = path.resolve(__dirname, '..');
require('dotenv').config({ path: path.join(ROOT, '.env') });

function int(name, fallback) {
  const v = parseInt(process.env[name], 10);
  return Number.isFinite(v) ? v : fallback;
}

function bool(name, fallback) {
  const v = process.env[name];
  if (v === undefined) return fallback;
  return /^(1|true|yes|on)$/i.test(v.trim());
}

// ---------------------------------------------------------------------------
// SESSION SECRET
// Si no hay uno en .env se genera y se persiste, asi las sesiones sobreviven
// a un reinicio del proceso (pm2 restart no deberia desloguear al operador).
// ---------------------------------------------------------------------------
const SECRET_FILE = path.join(ROOT, '.session_secret');

function resolveSessionSecret() {
  if (process.env.SESSION_SECRET && process.env.SESSION_SECRET.length >= 16) {
    return process.env.SESSION_SECRET;
  }
  try {
    if (fs.existsSync(SECRET_FILE)) {
      const s = fs.readFileSync(SECRET_FILE, 'utf8').trim();
      if (s.length >= 16) return s;
    }
  } catch (_) {
    /* ignore */
  }
  const generated = crypto.randomBytes(32).toString('hex');
  try {
    fs.writeFileSync(SECRET_FILE, generated, { mode: 0o600 });
  } catch (e) {
    console.warn('[CONFIG] No se pudo persistir .session_secret:', e.message);
  }
  return generated;
}

const config = {
  ROOT,
  PORT: int('PORT', 3000),
  HOST: process.env.HOST || '0.0.0.0',

  // --- Auth ---
  AUTH_USER: process.env.AUTH_USER || 'Bunker',
  AUTH_HASH: process.env.AUTH_HASH || '', // scrypt: <saltHex>:<hashHex>
  AUTH_PLAIN: process.env.AUTH_PASSWORD || '', // fallback si no hay hash (no recomendado)
  SESSION_SECRET: resolveSessionSecret(),
  SESSION_TTL_MS: int('SESSION_HOURS', 12) * 60 * 60 * 1000,
  COOKIE_NAME: 'sentinel_sid',
  LOGIN_MAX_ATTEMPTS: int('LOGIN_MAX_ATTEMPTS', 8),
  LOGIN_LOCKOUT_MS: int('LOGIN_LOCKOUT_MIN', 10) * 60 * 1000,

  // --- Verkada ---
  VERKADA_SHARED_SECRET: process.env.VERKADA_SHARED_SECRET || '',
  WEBHOOK_TOLERANCE_S: int('WEBHOOK_TOLERANCE_S', 120),

  // --- Streams (transcode RTSP -> MPEG1 para jsmpeg) ---
  STREAM_WIDTH: int('STREAM_WIDTH', 640),
  STREAM_HEIGHT: int('STREAM_HEIGHT', 360),
  STREAM_FPS: int('STREAM_FPS', 12),
  STREAM_BITRATE: process.env.STREAM_BITRATE || '450k',
  // Segundos sin espectadores antes de matar ffmpeg (0 = nunca apagar)
  STREAM_IDLE_TIMEOUT_S: int('STREAM_IDLE_TIMEOUT_S', 25),
  STREAM_ON_DEMAND: bool('STREAM_ON_DEMAND', true),
  FFMPEG_PATH: process.env.FFMPEG_PATH || 'ffmpeg',

  // --- Historial de alarmas ---
  DATA_DIR: process.env.DATA_DIR || path.join(ROOT, 'data'),
  EVENTS_MEMORY_LIMIT: int('EVENTS_MEMORY_LIMIT', 500),
  EVENTS_FILE_MAX_BYTES: int('EVENTS_FILE_MAX_MB', 10) * 1024 * 1024,

  // --- Control de luces (Arduino) ---
  GPIO_ENABLED: bool('GPIO_ENABLED', true),
  GPIO_HOST: process.env.GPIO_HOST || '127.0.0.1',
  GPIO_PORT: int('GPIO_PORT', 8765),
  GPIO_SCRIPT: process.env.GPIO_SCRIPT || path.join(ROOT, 'scripts', 'GPIO_control.py'),

  // --- Salud del sistema ---
  HEALTH_INTERVAL_MS: int('HEALTH_INTERVAL_S', 5) * 1000,

  // true si corre detras de Cloudflare Tunnel / proxy
  TRUST_PROXY: bool('TRUST_PROXY', true),
  SECURE_COOKIE: bool('SECURE_COOKIE', false),
};

module.exports = config;
