'use strict';

/**
 * Autenticacion minima y sin dependencias externas.
 *
 *  - Password guardada como hash scrypt (salt aleatorio) en .env -> AUTH_HASH
 *  - Sesion = cookie HttpOnly firmada con HMAC-SHA256 (stateless, sobrevive
 *    reinicios del proceso porque el secret se persiste en disco)
 *  - Rate limiting en memoria por IP
 *
 * Pensado para un equipo local: nada de OAuth, JWT libraries ni DB de usuarios.
 */

const crypto = require('crypto');
const config = require('./config');

// El hasheo vive en su propio modulo, sin dependencias de npm, para que el
// instalador pueda generar la contrasena antes de correr `npm install`.
const { hashPassword, verifyPassword: verifyHash, safeEqual } = require('./hash');

// ---------------------------------------------------------------------------
// Password
// ---------------------------------------------------------------------------

function verifyPassword(password) {
  if (config.AUTH_HASH && config.AUTH_HASH.includes(':')) {
    return verifyHash(password, config.AUTH_HASH);
  }
  if (config.AUTH_PLAIN) {
    console.warn('[AUTH] Usando AUTH_PASSWORD en texto plano. Genera AUTH_HASH con: sentinel password');
    return safeEqual(password, config.AUTH_PLAIN);
  }
  console.error('[AUTH] No hay AUTH_HASH ni AUTH_PASSWORD configurados. Login deshabilitado.');
  return false;
}

// ---------------------------------------------------------------------------
// Tokens de sesion
// ---------------------------------------------------------------------------

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function unb64url(str) {
  return Buffer.from(String(str).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function sign(payloadB64) {
  return b64url(crypto.createHmac('sha256', config.SESSION_SECRET).update(payloadB64).digest());
}

function issueToken(user) {
  const payload = {
    u: user,
    iat: Date.now(),
    exp: Date.now() + config.SESSION_TTL_MS,
    n: crypto.randomBytes(6).toString('hex'),
  };
  const p = b64url(JSON.stringify(payload));
  return `${p}.${sign(p)}`;
}

function verifyToken(token) {
  if (!token || typeof token !== 'string') return null;
  const dot = token.lastIndexOf('.');
  if (dot < 1) return null;
  const p = token.slice(0, dot);
  const sig = token.slice(dot + 1);
  if (!safeEqual(sig, sign(p))) return null;
  try {
    const payload = JSON.parse(unb64url(p).toString('utf8'));
    if (!payload.exp || Date.now() > payload.exp) return null;
    return payload;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Cookies
// ---------------------------------------------------------------------------

function parseCookies(header) {
  const out = {};
  if (!header) return out;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx < 0) continue;
    const k = part.slice(0, idx).trim();
    const v = part.slice(idx + 1).trim();
    if (k) {
      try {
        out[k] = decodeURIComponent(v);
      } catch (_) {
        out[k] = v;
      }
    }
  }
  return out;
}

function setSessionCookie(res, token) {
  const parts = [
    `${config.COOKIE_NAME}=${encodeURIComponent(token)}`,
    'HttpOnly',
    'Path=/',
    'SameSite=Lax',
    `Max-Age=${Math.floor(config.SESSION_TTL_MS / 1000)}`,
  ];
  if (config.SECURE_COOKIE) parts.push('Secure');
  res.setHeader('Set-Cookie', parts.join('; '));
}

function clearSessionCookie(res) {
  res.setHeader(
    'Set-Cookie',
    `${config.COOKIE_NAME}=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0`
  );
}

/** Extrae y valida la sesion de un request HTTP crudo (sirve tambien para WS upgrade). */
function sessionFromRequest(req) {
  const cookies = parseCookies(req.headers && req.headers.cookie);
  return verifyToken(cookies[config.COOKIE_NAME]);
}

// ---------------------------------------------------------------------------
// Rate limiting de login
// ---------------------------------------------------------------------------

const attempts = new Map(); // ip -> { count, until }

function clientIp(req) {
  if (config.TRUST_PROXY) {
    const fwd = req.headers['cf-connecting-ip'] || req.headers['x-forwarded-for'];
    if (fwd) return String(fwd).split(',')[0].trim();
  }
  return req.ip || (req.socket && req.socket.remoteAddress) || 'unknown';
}

function isLockedOut(ip) {
  const rec = attempts.get(ip);
  if (!rec) return 0;
  if (rec.until && Date.now() < rec.until) return rec.until - Date.now();
  if (rec.until && Date.now() >= rec.until) attempts.delete(ip);
  return 0;
}

function registerFailure(ip) {
  const rec = attempts.get(ip) || { count: 0, until: 0 };
  rec.count += 1;
  if (rec.count >= config.LOGIN_MAX_ATTEMPTS) {
    rec.until = Date.now() + config.LOGIN_LOCKOUT_MS;
    rec.count = 0;
  }
  attempts.set(ip, rec);
}

function clearFailures(ip) {
  attempts.delete(ip);
}

// Limpieza periodica del mapa (evita crecimiento infinito)
setInterval(() => {
  const now = Date.now();
  for (const [ip, rec] of attempts) {
    if (rec.until && now > rec.until + 60000) attempts.delete(ip);
  }
}, 5 * 60 * 1000).unref();

// ---------------------------------------------------------------------------
// Middlewares Express
// ---------------------------------------------------------------------------

/** Adjunta req.session (o null). Nunca bloquea. */
function attachSession(req, res, next) {
  req.session = sessionFromRequest(req);
  next();
}

/** Protege paginas: redirige a /login si no hay sesion. */
function requirePage(req, res, next) {
  if (req.session) return next();
  const back = encodeURIComponent(req.originalUrl || '/backoffice/');
  res.redirect(`/login/?next=${back}`);
}

/** Protege APIs: 401 JSON si no hay sesion. */
function requireApi(req, res, next) {
  if (req.session) return next();
  res.status(401).json({ error: 'unauthorized' });
}

module.exports = {
  hashPassword,
  verifyPassword,
  issueToken,
  verifyToken,
  setSessionCookie,
  clearSessionCookie,
  sessionFromRequest,
  parseCookies,
  clientIp,
  isLockedOut,
  registerFailure,
  clearFailures,
  attachSession,
  requirePage,
  requireApi,
};
