'use strict';

/**
 * Gestor de streams RTSP -> MPEG-TS(mpeg1video) -> WebSocket -> jsmpeg.
 *
 * Diferencias clave contra node-rtsp-stream (v4):
 *
 *  1. UN SOLO PUERTO. Todos los streams viajan por el mismo servidor HTTP
 *     (path /stream/<id>), asi que funcionan a traves del tunel de Cloudflare
 *     y no hay que abrir 9998/9999 en el firewall.
 *  2. ON-DEMAND. ffmpeg arranca cuando alguien mira y se apaga N segundos
 *     despues de que se va el ultimo espectador. En una RPi 5 esto libera
 *     practicamente todo el CPU cuando nadie tiene el backoffice abierto.
 *  3. AUTENTICADO. El upgrade del WebSocket valida la cookie de sesion.
 *  4. WATCHDOG. Si ffmpeg muere o deja de emitir datos, se reinicia solo con
 *     backoff exponencial en vez de quedar colgado.
 *  5. BACKPRESSURE. Si un cliente no consume, se le descartan frames en vez
 *     de acumular memoria en el proceso.
 */

const { spawn } = require('child_process');
const { WebSocketServer } = require('ws');
const { EventEmitter } = require('events');

const config = require('./config');
const { CAMERA_LIST } = require('./cameras');
const auth = require('./auth');

const NO_DATA_TIMEOUT_MS = 15000;
const BACKOFF_MIN_MS = 2000;
const BACKOFF_MAX_MS = 30000;

/**
 * MPEG-1 solo admite oficialmente estas tasas de cuadros. Con cualquier otra,
 * ffmpeg aborta con "MPEG-1/2 does not support N/1 fps" y el stream nunca
 * arranca. Como 12 fps consume la mitad de CPU que 25 y para vigilancia
 * alcanza de sobra, pasamos `-strict -1` para habilitar tasas libres; jsmpeg
 * las reproduce sin problema.
 */
const MPEG1_STANDARD_FPS = [24, 25, 30, 50, 60];

class CameraStream extends EventEmitter {
  constructor(camera) {
    super();
    this.camera = camera;
    this.id = camera.id;
    this.clients = new Set();
    this.proc = null;
    this.status = 'idle'; // idle | starting | live | retrying | error
    this.lastDataAt = 0;
    this.bytesOut = 0;
    this.retries = 0;
    this.idleTimer = null;
    this.watchdog = null;
    this.restartTimer = null;
    this.stderrTail = [];
  }

  // -------------------------------------------------------------------------
  // Ciclo de vida de ffmpeg
  // -------------------------------------------------------------------------

  ffmpegArgs() {
    const fps = config.STREAM_FPS;
    const needsLooseStrict = !MPEG1_STANDARD_FPS.includes(fps);

    return [
      '-hide_banner',
      '-loglevel', 'error',
      '-nostdin',
      '-fflags', 'nobuffer',
      '-flags', 'low_delay',
      '-rtsp_transport', 'tcp',
      // Nota: no usamos -stimeout/-timeout porque el nombre de la opcion cambio
      // entre versiones de ffmpeg y un flag desconocido hace fallar el proceso.
      // Los cuelgues los resuelve el watchdog de mas abajo.
      '-i', this.camera.rtspUrl,
      '-an',                          // sin audio: no lo usamos y ahorra CPU
      '-f', 'mpegts',
      '-codec:v', 'mpeg1video',
      '-s', `${config.STREAM_WIDTH}x${config.STREAM_HEIGHT}`,
      '-r', String(fps),
      '-b:v', config.STREAM_BITRATE,
      '-bf', '0',                     // sin B-frames: menos latencia y menos CPU
      '-g', String(fps * 2),
      // Habilita tasas de cuadros fuera del estándar MPEG-1 (ver constante arriba)
      ...(needsLooseStrict ? ['-strict', '-1'] : []),
      '-muxdelay', '0.001',
      'pipe:1',
    ];
  }

  start() {
    if (this.proc || this.restartTimer) return;
    this.setStatus('starting');
    console.log(`[STREAM:${this.id}] Iniciando ffmpeg (${this.clients.size} espectador/es)`);

    let proc;
    try {
      proc = spawn(config.FFMPEG_PATH, this.ffmpegArgs(), {
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (err) {
      console.error(`[STREAM:${this.id}] No se pudo lanzar ffmpeg:`, err.message);
      this.setStatus('error');
      this.scheduleRestart();
      return;
    }

    this.proc = proc;
    this.lastDataAt = Date.now();

    proc.stdout.on('data', (chunk) => {
      this.lastDataAt = Date.now();
      this.bytesOut += chunk.length;
      if (this.status !== 'live') {
        this.retries = 0;
        this.setStatus('live');
      }
      this.broadcast(chunk);
    });

    proc.stderr.on('data', (d) => {
      const line = d.toString().trim();
      if (!line) return;
      this.stderrTail.push(line);
      if (this.stderrTail.length > 5) this.stderrTail.shift();
      console.warn(`[STREAM:${this.id}] ffmpeg: ${line.slice(0, 200)}`);
    });

    proc.on('error', (err) => {
      console.error(`[STREAM:${this.id}] Error de proceso:`, err.message);
    });

    proc.on('close', (code, signal) => {
      const wasIntentional = this._stopping;
      this.proc = null;
      this.clearWatchdog();
      if (wasIntentional) {
        this._stopping = false;
        this.setStatus('idle');
        return;
      }
      console.warn(`[STREAM:${this.id}] ffmpeg termino (code=${code} signal=${signal})`);
      this.setStatus('retrying');
      if (this.clients.size > 0 || !config.STREAM_ON_DEMAND) this.scheduleRestart();
      else this.setStatus('idle');
    });

    this.armWatchdog();
  }

  scheduleRestart() {
    if (this.restartTimer) return;
    const delay = Math.min(BACKOFF_MIN_MS * Math.pow(2, this.retries), BACKOFF_MAX_MS);
    this.retries = Math.min(this.retries + 1, 6);
    console.log(`[STREAM:${this.id}] Reintentando en ${Math.round(delay / 1000)}s`);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      if (this.clients.size > 0 || !config.STREAM_ON_DEMAND) this.start();
      else this.setStatus('idle');
    }, delay);
    this.restartTimer.unref();
  }

  armWatchdog() {
    this.clearWatchdog();
    this.watchdog = setInterval(() => {
      if (!this.proc) return;
      if (Date.now() - this.lastDataAt > NO_DATA_TIMEOUT_MS) {
        console.warn(`[STREAM:${this.id}] Sin datos hace ${NO_DATA_TIMEOUT_MS / 1000}s. Reiniciando.`);
        this.kill();
      }
    }, 5000);
    this.watchdog.unref();
  }

  clearWatchdog() {
    if (this.watchdog) {
      clearInterval(this.watchdog);
      this.watchdog = null;
    }
  }

  kill(intentional = false) {
    this._stopping = intentional;
    this.clearWatchdog();
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    if (this.proc) {
      const p = this.proc;
      try {
        p.kill('SIGTERM');
      } catch (_) {
        /* ignore */
      }
      // Si no muere en 3s, SIGKILL
      setTimeout(() => {
        try {
          if (!p.killed) p.kill('SIGKILL');
        } catch (_) {
          /* ignore */
        }
      }, 3000).unref();
    }
  }

  stop() {
    console.log(`[STREAM:${this.id}] Deteniendo (sin espectadores)`);
    this.kill(true);
    this.setStatus('idle');
  }

  setStatus(s) {
    if (this.status === s) return;
    this.status = s;
    this.emit('status', { id: this.id, status: s });
  }

  // -------------------------------------------------------------------------
  // Clientes
  // -------------------------------------------------------------------------

  addClient(ws) {
    this.clients.add(ws);
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    if (!this.proc && !this.restartTimer) {
      this.retries = 0;
      this.start();
    }
  }

  removeClient(ws) {
    this.clients.delete(ws);
    if (this.clients.size > 0 || !config.STREAM_ON_DEMAND) return;
    if (config.STREAM_IDLE_TIMEOUT_S <= 0) return;
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;
      if (this.clients.size === 0) this.stop();
    }, config.STREAM_IDLE_TIMEOUT_S * 1000);
    this.idleTimer.unref();
  }

  broadcast(chunk) {
    for (const ws of this.clients) {
      if (ws.readyState !== ws.OPEN) continue;
      // Backpressure: si el cliente esta atrasado, descartamos el frame en vez
      // de acumular buffer en el servidor (mejor perder video que morir de RAM).
      if (ws.bufferedAmount > 1024 * 512) continue;
      ws.send(chunk, { binary: true });
    }
  }

  info() {
    return {
      id: this.id,
      name: this.camera.name,
      status: this.status,
      viewers: this.clients.size,
      running: Boolean(this.proc),
      bytesOut: this.bytesOut,
      lastDataAgoMs: this.lastDataAt ? Date.now() - this.lastDataAt : null,
      lastError: this.stderrTail[this.stderrTail.length - 1] || null,
    };
  }
}

// ---------------------------------------------------------------------------
// Manager
// ---------------------------------------------------------------------------

class StreamManager extends EventEmitter {
  constructor() {
    super();
    this.streams = new Map();
    for (const cam of CAMERA_LIST) {
      if (!cam.rtspUrl) {
        console.warn(`[STREAM] ${cam.name} no tiene rtspUrl, se omite`);
        continue;
      }
      const s = new CameraStream(cam);
      s.on('status', (payload) => this.emit('status', payload));
      this.streams.set(cam.id, s);
    }
  }

  /** Monta el WebSocketServer sobre el servidor HTTP existente. */
  attach(httpServer) {
    this.wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

    httpServer.on('upgrade', (req, socket, head) => {
      let pathname;
      try {
        pathname = new URL(req.url, 'http://localhost').pathname;
      } catch (_) {
        return;
      }
      // Solo nos ocupamos de /stream/<id>. socket.io tiene su propio handler
      // sobre el mismo evento y maneja /socket.io/ por su cuenta.
      if (!pathname.startsWith('/stream/')) return;

      const id = pathname.slice('/stream/'.length).replace(/\/+$/, '');
      const stream = this.streams.get(id);

      if (!stream) {
        socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
        socket.destroy();
        return;
      }
      if (!auth.sessionFromRequest(req)) {
        socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
        socket.destroy();
        return;
      }

      this.wss.handleUpgrade(req, socket, head, (ws) => {
        ws.binaryType = 'nodebuffer';
        stream.addClient(ws);
        console.log(`[STREAM:${id}] Cliente conectado (total ${stream.clients.size})`);

        ws.isAlive = true;
        ws.on('pong', () => {
          ws.isAlive = true;
        });

        const cleanup = () => {
          stream.removeClient(ws);
          console.log(`[STREAM:${id}] Cliente desconectado (quedan ${stream.clients.size})`);
        };
        ws.on('close', cleanup);
        ws.on('error', cleanup);
      });
    });

    // Ping/pong para limpiar sockets zombie (kiosko sin red, tab colgada, etc.)
    this.heartbeat = setInterval(() => {
      for (const stream of this.streams.values()) {
        for (const ws of stream.clients) {
          if (ws.isAlive === false) {
            ws.terminate();
            continue;
          }
          ws.isAlive = false;
          try {
            ws.ping();
          } catch (_) {
            /* ignore */
          }
        }
      }
    }, 30000);
    this.heartbeat.unref();

    if (!config.STREAM_ON_DEMAND) {
      console.log('[STREAM] Modo always-on: arrancando todos los streams');
      for (const s of this.streams.values()) s.start();
    } else {
      console.log('[STREAM] Modo on-demand: ffmpeg arranca cuando hay espectadores');
    }
  }

  info() {
    return Array.from(this.streams.values()).map((s) => s.info());
  }

  shutdown() {
    if (this.heartbeat) clearInterval(this.heartbeat);
    for (const s of this.streams.values()) s.kill(true);
    if (this.wss) this.wss.close();
  }
}

module.exports = { StreamManager };
