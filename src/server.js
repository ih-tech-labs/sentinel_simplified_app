'use strict';

/**
 * Sentinel v5 - servidor unico
 *
 *   :3000  ->  HTTP (kiosko publico, backoffice autenticado)
 *              socket.io  en /socket.io/
 *              video RTSP en /stream/<id>   (WebSocket, autenticado)
 *
 * Todo por un solo puerto: pasa entero por el tunel de Cloudflare y no hay
 * que abrir 9998/9999 en el firewall como en la v4.
 */

const express = require('express');
const http = require('http');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { Server } = require('socket.io');

const config = require('./config');
const cameras = require('./cameras');
const auth = require('./auth');
const events = require('./events');
const system = require('./system');
const devices = require('./devices');
const sockets = require('./sockets');
const { StreamManager } = require('./streams');

const PUBLIC_DIR = path.join(config.ROOT, 'public');

// ---------------------------------------------------------------------------
// Arranque
// ---------------------------------------------------------------------------

events.load();

const app = express();
const server = http.createServer(app);

// Keep-alive generoso: evita que Cloudflare corte conexiones ociosas
server.keepAliveTimeout = 65000;
server.headersTimeout = 70000;

const io = new Server(server, {
  cors: { origin: false },
  // El kiosko corre en la misma LAN: websocket directo, sin polling de arranque
  transports: ['websocket', 'polling'],
  pingInterval: 25000,
  pingTimeout: 20000,
  maxHttpBufferSize: 1e6,
});

const streams = new StreamManager();
streams.attach(server);

const hub = sockets.register(io, { streams });

if (config.TRUST_PROXY) app.set('trust proxy', true);
app.disable('x-powered-by');

// ---------------------------------------------------------------------------
// Middleware base
// ---------------------------------------------------------------------------

// Cabeceras de seguridad basicas (sin traer helmet como dependencia)
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'SAMEORIGIN');
  res.setHeader('Referrer-Policy', 'same-origin');
  res.setHeader('Permissions-Policy', 'camera=(self), microphone=(self), geolocation=()');
  next();
});

/**
 * El webhook necesita el body CRUDO para validar el HMAC, asi que se parsea
 * aparte y ANTES del json() general.
 */
app.use(
  '/verkada-webhook',
  express.json({
    limit: '256kb',
    verify: (req, _res, buf) => {
      req.rawBody = buf;
    },
  })
);
app.use(express.json({ limit: '64kb' }));
app.use(express.urlencoded({ extended: false, limit: '64kb' }));
app.use(auth.attachSession);

// ---------------------------------------------------------------------------
// Autenticacion
// ---------------------------------------------------------------------------

app.post('/api/login', (req, res) => {
  const ip = auth.clientIp(req);
  const lockMs = auth.isLockedOut(ip);
  if (lockMs) {
    return res.status(429).json({
      error: 'too_many_attempts',
      message: `Demasiados intentos. Reintentá en ${Math.ceil(lockMs / 60000)} minuto(s).`,
    });
  }

  const user = String((req.body && req.body.user) || '').trim();
  const password = String((req.body && req.body.password) || '');

  const userOk = user.toLowerCase() === config.AUTH_USER.toLowerCase();
  const passOk = auth.verifyPassword(password);

  if (!userOk || !passOk) {
    auth.registerFailure(ip);
    console.warn(`[AUTH] Login fallido desde ${ip} (usuario: "${user}")`);
    return res.status(401).json({ error: 'invalid_credentials', message: 'Usuario o contraseña incorrectos.' });
  }

  auth.clearFailures(ip);
  const token = auth.issueToken(config.AUTH_USER);
  auth.setSessionCookie(res, token);
  console.log(`[AUTH] Login OK: ${config.AUTH_USER} desde ${ip}`);
  res.json({ ok: true, user: config.AUTH_USER });
});

app.post('/api/logout', (req, res) => {
  auth.clearSessionCookie(res);
  res.json({ ok: true });
});

app.get('/api/session', (req, res) => {
  if (!req.session) return res.status(401).json({ authenticated: false });
  res.json({ authenticated: true, user: req.session.u, expiresAt: req.session.exp });
});

// ---------------------------------------------------------------------------
// API del backoffice (toda protegida)
// ---------------------------------------------------------------------------

const api = express.Router();
api.use(auth.requireApi);

api.get('/cameras', (_req, res) => res.json(cameras.publicList()));

api.get('/events', (req, res) => {
  res.json({
    events: events.query({
      kioskId: req.query.kiosk,
      severity: req.query.severity,
      since: req.query.since,
      limit: req.query.limit,
      onlyPending: req.query.pending === '1',
    }),
    stats: events.stats(),
  });
});

api.post('/events/:id/ack', (req, res) => {
  const evt = events.acknowledge(req.params.id, req.session.u);
  if (!evt) return res.status(404).json({ error: 'not_found' });
  io.to('backoffice').emit('event_acked', { id: evt.id, ackBy: evt.ackBy, ackAt: evt.ackAt });
  res.json({ ok: true, event: evt });
});

api.get('/health', (_req, res) => {
  res.json({
    system: system.snapshot(),
    streams: streams.info(),
    kiosks: hub.onlineKiosks(),
    events: events.stats(),
    devices: devices.status(),
    call: hub.getActiveCall(),
  });
});

api.get('/devices/presets', (_req, res) => res.json(devices.presetList()));

api.post('/devices/preset/:name', async (req, res) => {
  const result = await devices.sendPreset(req.params.name);
  if (result.ok) {
    console.log(`[GPIO] ${req.session.u} -> preset '${req.params.name}' (via ${result.via})`);
    events.record({
      type: 'device_command',
      severity: 'info',
      source: 'manual',
      camera: 'Sistema',
      details: `${req.session.u} ejecutó "${result.label || req.params.name}"`,
    });
  }
  res.status(result.ok ? 200 : 502).json(result);
});

api.post('/devices/frame', async (req, res) => {
  const frame = String((req.body && req.body.frame) || '');
  const result = await devices.sendFrame(frame);
  res.status(result.ok ? 200 : 502).json(result);
});

app.use('/api', api);

// ---------------------------------------------------------------------------
// Webhook de Verkada
// ---------------------------------------------------------------------------

function validateVerkada(req, res, next) {
  const signatureHeader = req.headers['verkada-signature'];
  const secret = config.VERKADA_SHARED_SECRET;

  if (!secret) {
    console.error('[WEBHOOK] VERKADA_SHARED_SECRET no configurado');
    return res.status(500).send('server misconfigured');
  }
  if (!signatureHeader) return res.status(400).send('missing signature');

  const [timestampStr, signature] = String(signatureHeader).split('|');
  const timestamp = parseInt(timestampStr, 10);

  if (!Number.isFinite(timestamp) || !signature) return res.status(400).send('malformed signature');
  if (Math.abs(Math.floor(Date.now() / 1000) - timestamp) > config.WEBHOOK_TOLERANCE_S) {
    console.warn('[WEBHOOK] Firma expirada');
    return res.status(403).send('expired signature');
  }

  const signedPayload = Buffer.concat([
    req.rawBody || Buffer.alloc(0),
    Buffer.from('|', 'utf8'),
    Buffer.from(timestampStr, 'utf8'),
  ]);
  const expected = crypto.createHmac('sha256', secret).update(signedPayload).digest('hex');

  // Comparamos hex a hex con longitud garantizada -> timingSafeEqual no tira
  const a = Buffer.from(signature.padEnd(expected.length, '0').slice(0, expected.length), 'utf8');
  const b = Buffer.from(expected, 'utf8');
  if (signature.length !== expected.length || !crypto.timingSafeEqual(a, b)) {
    console.warn('[WEBHOOK] Firma invalida');
    return res.status(401).send('invalid signature');
  }
  next();
}

app.post('/verkada-webhook', validateVerkada, (req, res) => {
  const body = req.body || {};
  const data = body.data || {};
  const deviceId = data.device_id;
  const eventType = data.notification_type || data.event_type || body.webhook_type || 'unknown';

  const cam = cameras.byDeviceId(deviceId);

  if (!cam) {
    // Este es el segundo tropiezo clásico después de la URL: la firma valida,
    // la alarma llega, pero el device_id no coincide con ninguna cámara y el
    // evento se descarta en silencio. Imprimimos el ID y el paso exacto.
    console.log('');
    console.log('  ┌──────────────────────────────────────────────────────────');
    console.log('  │ ⚠️  ALARMA RECIBIDA DE UNA CÁMARA NO CONFIGURADA');
    console.log('  │');
    console.log(`  │ device_id : ${deviceId}`);
    console.log(`  │ evento    : ${eventType}`);
    console.log('  │');
    console.log('  │ La firma es correcta, pero ese device_id no está en');
    console.log('  │ config/cameras.json, así que el evento se ignora.');
    console.log('  │');
    console.log('  │ Copiá ese device_id al campo "deviceId" de tu cámara:');
    console.log(`  │   nano ${path.join(config.ROOT, 'config', 'cameras.json')}`);
    console.log('  │   ./sentinel restart server');
    console.log('  └──────────────────────────────────────────────────────────');
    console.log('');
    return res.status(200).json({ status: 'ignored', reason: 'unknown_camera', deviceId });
  }

  if (Array.isArray(cam.allowedEvents) && !cam.allowedEvents.includes(eventType)) {
    console.log(`[WEBHOOK] Evento '${eventType}' filtrado para ${cam.name}`);
    return res.status(200).json({ status: 'ignored', reason: 'filtered_type' });
  }

  console.log(`[WEBHOOK] ALARMA ${cam.name} <- ${eventType}`);

  const entry = events.record({
    kioskId: cam.id,
    camera: cam.name,
    cameraId: deviceId,
    type: eventType,
    severity: 'alert',
    source: 'verkada',
    details: prettyEvent(eventType),
  });

  hub.emitAlarm(entry, { sound: cam.sound, triggerVideo: cam.triggerVideo });
  res.status(200).json({ status: 'ok' });
});

function prettyEvent(type) {
  const map = {
    alert_rule_line_crossing: 'Cruce de línea detectado',
    alert_rule_motion: 'Movimiento detectado',
    alert_rule_person: 'Persona detectada',
    alert_rule_vehicle: 'Vehículo detectado',
    alert_rule_loitering: 'Merodeo detectado',
    alert_rule_crowd: 'Aglomeración detectada',
    tamper: 'Manipulación de cámara',
    camera_offline: 'Cámara desconectada',
  };
  return map[type] || `Evento: ${type}`;
}

// ---------------------------------------------------------------------------
// Archivos estaticos y paginas
// ---------------------------------------------------------------------------

const staticOpts = {
  etag: true,
  lastModified: true,
  maxAge: '1h',
  setHeaders(res, filePath) {
    // El video de fondo se cachea fuerte: es inmutable y pesa varios MB.
    // Sin esto Chromium lo vuelve a leer del disco en cada reinicio del kiosko.
    if (/\.(mp4|webm|mp3|woff2?)$/i.test(filePath)) {
      res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    } else if (/\.(html|css|js)$/i.test(filePath)) {
      // Revalidar siempre. Son archivos chicos servidos por LAN o por el túnel,
      // y el costo de un 304 es despreciable frente a depurar por qué un fix
      // "no tomó" en un equipo remoto al que no se puede ir a apretar F5.
      res.setHeader('Cache-Control', 'no-cache');
    }
  },
};

// Publico: kiosko (es una pantalla fisica, no puede pedir login), assets y login
app.use('/assets', express.static(path.join(PUBLIC_DIR, 'assets'), staticOpts));
app.use('/vendor', express.static(path.join(PUBLIC_DIR, 'vendor'), staticOpts));
// Tokens de diseño compartidos: publicos porque tambien los usa la pagina de login
app.use('/ui', express.static(path.join(PUBLIC_DIR, 'shared'), staticOpts));
app.use('/kiosk', express.static(path.join(PUBLIC_DIR, 'kiosk'), staticOpts));
app.use('/login', express.static(path.join(PUBLIC_DIR, 'login'), staticOpts));

// Protegido: backoffice
app.use('/backoffice', auth.requirePage, express.static(path.join(PUBLIC_DIR, 'backoffice'), staticOpts));

app.get('/', (req, res) => res.redirect(req.session ? '/backoffice/' : '/login/'));
app.get('/healthz', (_req, res) => res.json({ ok: true, uptime: Math.round(process.uptime()) }));

/**
 * Metricas de video para diagnosticar a distancia, sin sesion.
 *
 * Va sin autenticar a proposito: sirve para saber por que se ve mal un stream
 * cuando no hay nadie delante del equipo. Por eso devuelve SOLO numeros —
 * nada de URLs RTSP, nombres de camara ni datos del sitio.
 */
app.get('/healthz/streams', (_req, res) => {
  res.json({
    ok: true,
    streams: streams.info().map((s) => ({
      id: s.id,
      status: s.status,
      viewers: s.viewers,
      kbps: s.kbps,
      keyframes: s.keyframes,
      keyGapAvgMs: s.keyGapAvgMs,
      resyncs: s.resyncs,
      droppedBytes: s.droppedBytes,
      slowClients: s.slowClients,
      lastDataAgoMs: s.lastDataAgoMs,
      inputErrors: s.inputErrors,
      lastInputError: s.lastInputError,
      uptimeS: s.uptimeS,
    })),
  });
});

app.use((req, res) => res.status(404).send('Not found'));

// Handler de errores (evita que una excepcion tumbe el proceso)
app.use((err, _req, res, _next) => {
  console.error('[HTTP] Error no manejado:', err.message);
  res.status(500).json({ error: 'internal_error' });
});

// ---------------------------------------------------------------------------
// Push periodico de salud al backoffice
// ---------------------------------------------------------------------------

const healthTimer = setInterval(() => {
  if (io.sockets.adapter.rooms.get('backoffice')) {
    hub.emitHealth({
      system: system.snapshot(),
      streams: streams.info(),
      kiosks: hub.onlineKiosks(),
      events: events.stats(),
    });
  }
}, config.HEALTH_INTERVAL_MS);
healthTimer.unref();

// ---------------------------------------------------------------------------
// Arranque y apagado limpio
// ---------------------------------------------------------------------------

server.listen(config.PORT, config.HOST, () => {
  console.log('');
  console.log('  ╔══════════════════════════════════════════════╗');
  console.log('  ║   SENTINEL v5  ·  Sistema operativo          ║');
  console.log('  ╚══════════════════════════════════════════════╝');
  const firstKiosk = cameras.CAMERA_LIST[0] ? cameras.CAMERA_LIST[0].id : 'admin';
  console.log(`   Sitio       : ${cameras.SITE}`);
  console.log(`   Puerto      : ${config.PORT}`);
  console.log(`   Kiosko      : http://localhost:${config.PORT}/kiosk/?id=${firstKiosk}`);
  console.log(`   Backoffice  : http://localhost:${config.PORT}/backoffice/`);
  console.log(`   Usuario     : ${config.AUTH_USER}`);
  console.log(`   Cámaras     : ${cameras.CAMERA_LIST.map((c) => c.id).join(', ')}`);
  console.log(`   Streams     : ${config.STREAM_ON_DEMAND ? 'on-demand' : 'always-on'} @ ${config.STREAM_WIDTH}x${config.STREAM_HEIGHT} ${config.STREAM_FPS}fps`);
  console.log(`   Webhook     : ${config.VERKADA_SHARED_SECRET ? 'configurado' : '⚠️  SIN SECRET'}`);
  console.log(`   Auth        : ${config.AUTH_HASH ? 'hash scrypt' : config.AUTH_PLAIN ? '⚠️  texto plano' : '❌ SIN CONFIGURAR'}`);
  console.log('');

  // Sin AUTH_HASH el login rechaza todo, pero el servidor arranca igual y el
  // único síntoma es un "usuario o contraseña incorrectos" que no dice nada.
  // Avisamos fuerte acá, al arrancar, en vez de esperar a que alguien falle
  // el login y después vaya a buscar el motivo en los logs.
  if (!config.AUTH_HASH && !config.AUTH_PLAIN) {
    const envExists = fs.existsSync(path.join(config.ROOT, '.env'));
    console.error('  ╔══════════════════════════════════════════════════════════╗');
    console.error('  ║  ⚠️   NADIE VA A PODER ENTRAR AL TABLERO                  ║');
    console.error('  ╚══════════════════════════════════════════════════════════╝');
    console.error('');
    console.error(envExists
      ? '   El archivo .env existe pero AUTH_HASH está vacío.'
      : '   NO existe el archivo .env: la instalación quedó incompleta.');
    console.error('');
    console.error('   Solución:');
    console.error(`     cd ${config.ROOT}`);
    console.error(envExists ? '     ./sentinel password' : '     ./install.sh');
    console.error('');
  }
});

// Nunca dejar morir el proceso por una excepcion suelta: en un equipo
// desatendido es preferible loguear y seguir.
process.on('uncaughtException', (err) => {
  console.error('[FATAL] uncaughtException:', err && err.stack ? err.stack : err);
});
process.on('unhandledRejection', (reason) => {
  console.error('[FATAL] unhandledRejection:', reason);
});

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`\n[SYS] ${signal} recibido, cerrando...`);
  clearInterval(healthTimer);
  streams.shutdown();
  events.shutdown();
  io.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 5000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
