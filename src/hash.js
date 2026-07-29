'use strict';

/**
 * Hasheo de contraseñas · SIN DEPENDENCIAS
 *
 * Vive aparte de auth.js a propósito. auth.js necesita config.js, que necesita
 * dotenv, que es un paquete de npm. El instalador tiene que poder hashear la
 * contraseña ANTES de correr `npm install` — si no, se muere con
 * "Cannot find module 'dotenv'" justo cuando escribe el .env.
 *
 * Acá sólo se usa `crypto`, que viene con Node. Así el instalador y la
 * aplicación comparten exactamente el mismo algoritmo sin duplicar parámetros:
 * si estos números divergieran entre dos archivos, la contraseña se guardaría
 * de una forma y se verificaría de otra, y el login fallaría siempre sin
 * ninguna pista de por qué.
 */

const crypto = require('crypto');

const SCRYPT = { N: 16384, r: 8, p: 1, keylen: 64, maxmem: 64 * 1024 * 1024 };

/**
 * Genera "saltHex:hashHex" listo para guardar en .env
 * @param {string} password
 * @param {string} [saltHex] sólo para re-derivar al verificar
 */
function hashPassword(password, saltHex) {
  const salt = saltHex ? Buffer.from(saltHex, 'hex') : crypto.randomBytes(16);
  const derived = crypto.scryptSync(password, salt, SCRYPT.keylen, {
    N: SCRYPT.N,
    r: SCRYPT.r,
    p: SCRYPT.p,
    maxmem: SCRYPT.maxmem,
  });
  return `${salt.toString('hex')}:${derived.toString('hex')}`;
}

/** Comparación en tiempo constante, tolerante a longitudes distintas. */
function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) {
    // Comparación dummy para no filtrar la diferencia de longitud por tiempo
    crypto.timingSafeEqual(ba, ba);
    return false;
  }
  return crypto.timingSafeEqual(ba, bb);
}

/**
 * Verifica una contraseña contra un "saltHex:hashHex" guardado.
 * @returns {boolean}
 */
function verifyPassword(password, stored) {
  if (!stored || !stored.includes(':')) return false;
  const [saltHex, expected] = stored.split(':');
  let candidate;
  try {
    candidate = hashPassword(password, saltHex).split(':')[1];
  } catch (_) {
    return false;
  }
  return safeEqual(candidate, expected);
}

module.exports = { hashPassword, verifyPassword, safeEqual, SCRYPT };
