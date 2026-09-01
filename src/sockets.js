'use strict';

/**
 * Capa de socket.io: presencia de kioskos, alarmas y signaling WebRTC.
 *
 * Correcciones respecto de la v4:
 *
 *  - El listener de `test_alarm` se registraba DENTRO del handler de `register`.
 *    Cada vez que un backoffice se reconectaba quedaba un listener duplicado y
 *    una prueba disparaba N alarmas. Ahora se registra una sola vez por socket.
 *
 *  - El signaling usaba una room global 'sentinel-room' compartida por todos.
 *    Con dos kioskos eso genera crosstalk de ICE candidates. Ahora el backoffice
 *    entra temporalmente a la room del kiosko con el que habla y sale al colgar.
 *
 *  - El rol 'backoffice' ahora exige sesion valida (cookie del handshake).
 *
 *  - Se lleva registro de la llamada activa para impedir dos llamadas en paralelo
 *    y para poder cortar limpio si el operador cierra la pestaña.
 */

const auth = require('./auth');
const events = require('./events');
const cameras = require('./cameras');

const BACKOFFICE_ROOM = 'backoffice';
const roomFor = (kioskId) => `kiosk-${kioskId}`;

function register(io, ctx) {
  // kioskId -> Set<socketId>  (soporta que un kiosko se reconecte sin dejar fantasmas)
  const kiosks = new Map();
  let activeCall = null; // { kioskId, operatorSocketId, startedAt }

  const onlineKiosks = () => {
    const out = {};
    for (const cam of cameras.CAMERA_LIST) {
      out[cam.id] = kiosks.has(cam.id) && kiosks.get(cam.id).size > 0;
    }
    return out;
  };

  const broadcastPresence = () => {
    io.to(BACKOFFICE_ROOM).emit('kiosk_presence', onlineKiosks());
  };

  // -------------------------------------------------------------------------
  // Handshake: adjuntamos la sesion (si hay) antes de aceptar la conexion
  // -------------------------------------------------------------------------
  io.use((socket, next) => {
    socket.data.session = auth.sessionFromRequest(socket.request);
    next();
  });

  io.on('connection', (socket) => {
    socket.data.role = null;

    // ---------------------------------------------------------------------
    // Registro de rol
    // ---------------------------------------------------------------------
    socket.on('register', (payload, cb) => {
      const data = typeof payload === 'object' && payload ? payload : { role: payload };
      const role = data.role;

      if (role === 'kiosk') {
        const kioskId = String(data.id || 'admin');
        if (!cameras.bySlug(kioskId)) {
          console.warn(`[SOCKET] Kiosko desconocido '${kioskId}', se rechaza`);
          if (cb) cb({ ok: false, error: 'kiosko desconocido' });
          return;
        }
        socket.data.role = 'kiosk';
        socket.data.kioskId = kioskId;
        socket.join(roomFor(kioskId));

        if (!kiosks.has(kioskId)) kiosks.set(kioskId, new Set());
        kiosks.get(kioskId).add(socket.id);

        console.log(`[SOCKET] Kiosko '${kioskId}' online (${socket.id})`);
        broadcastPresence();
        if (cb) cb({ ok: true, kioskId });
        return;
      }

      if (role === 'backoffice') {
        if (!socket.data.session) {
          console.warn('[SOCKET] Backoffice sin sesion valida, rechazado');
          if (cb) cb({ ok: false, error: 'unauthorized' });
          socket.emit('force_logout');
          socket.disconnect(true);
          return;
        }
        socket.data.role = 'backoffice';
        socket.join(BACKOFFICE_ROOM);
        console.log(`[SOCKET] Backoffice conectado (${socket.data.session.u})`);

        socket.emit('bootstrap', {
          user: socket.data.session.u,
          site: cameras.SITE,
          cameras: cameras.publicList(),
          presence: onlineKiosks(),
          events: events.query({ limit: 200 }),
          stats: events.stats(),
          streams: ctx.streams.info(),
          activeCall: activeCall ? { kioskId: activeCall.kioskId } : null,
        });
        if (cb) cb({ ok: true });
        return;
      }

      if (cb) cb({ ok: false, error: 'rol invalido' });
    });

    const isOperator = () => socket.data.role === 'backoffice' && socket.data.session;

    // ---------------------------------------------------------------------
    // Alarma de prueba (solo operador autenticado)
    // ---------------------------------------------------------------------
    socket.on('test_alarm', (kioskId) => {
      if (!isOperator()) return;
      const cam = cameras.bySlug(String(kioskId));
      if (!cam) return;

      console.log(`[TEST] Alarma manual para '${cam.id}' por ${socket.data.session.u}`);
      const entry = events.record({
        kioskId: cam.id,
        camera: cam.name,
        cameraId: cam.deviceId,
        type: 'manual_test',
        severity: 'test',
        source: 'manual',
        details: `Prueba manual disparada por ${socket.data.session.u}`,
      });
      io.to(BACKOFFICE_ROOM).emit('alarm', { ...entry, sound: true, triggerVideo: cam.triggerVideo });
    });

    // ---------------------------------------------------------------------
    // Acknowledge de alarmas
    // ---------------------------------------------------------------------
    socket.on('ack_event', (id) => {
      if (!isOperator()) return;
      const evt = events.acknowledge(String(id), socket.data.session.u);
      if (evt) io.to(BACKOFFICE_ROOM).emit('event_acked', { id: evt.id, ackBy: evt.ackBy, ackAt: evt.ackAt });
    });

    socket.on('ack_all', () => {
      if (!isOperator()) return;
      const changed = events.acknowledgeAll(socket.data.session.u);
      if (changed.length) io.to(BACKOFFICE_ROOM).emit('events_acked_all', { by: socket.data.session.u });
    });

    // ---------------------------------------------------------------------
    // WebRTC: inicio / fin de llamada
    // ---------------------------------------------------------------------
    socket.on('start_call', (kioskId, cb) => {
      if (!isOperator()) {
        if (cb) cb({ ok: false, error: 'unauthorized' });
        return;
      }
      const cam = cameras.bySlug(String(kioskId));
      if (!cam) {
        if (cb) cb({ ok: false, error: 'kiosko desconocido' });
        return;
      }
      if (activeCall && activeCall.operatorSocketId !== socket.id) {
        if (cb) cb({ ok: false, error: `Ya hay una llamada activa con ${activeCall.kioskId}` });
        return;
      }
      if (!kiosks.has(cam.id) || kiosks.get(cam.id).size === 0) {
        if (cb) cb({ ok: false, error: 'El kiosko está offline' });
        return;
      }

      const room = roomFor(cam.id);
      socket.join(room);                       // el operador entra a la room del kiosko
      socket.data.callRoom = room;
      activeCall = { kioskId: cam.id, operatorSocketId: socket.id, startedAt: Date.now() };

      console.log(`[CALL] ${socket.data.session.u} -> ${cam.id}`);
      socket.to(room).emit('call_incoming');
      io.to(BACKOFFICE_ROOM).emit('call_state', { active: true, kioskId: cam.id });
      if (cb) cb({ ok: true, room });
    });

    const terminateCall = (reason) => {
      const room = socket.data.callRoom;
      if (!room) return;
      socket.to(room).emit('call_ended');
      socket.leave(room);
      socket.data.callRoom = null;
      if (activeCall && activeCall.operatorSocketId === socket.id) {
        console.log(`[CALL] Finalizada (${reason})`);
        io.to(BACKOFFICE_ROOM).emit('call_state', { active: false, kioskId: activeCall.kioskId });
        activeCall = null;
      }
    };

    socket.on('end_call', () => terminateCall('colgada'));

    // ---------------------------------------------------------------------
    // Signaling. Se reenvia solo dentro de la room, nunca en broadcast global.
    // ---------------------------------------------------------------------
    const relay = (event) => (data) => {
      const room = socket.data.callRoom || (socket.data.kioskId ? roomFor(socket.data.kioskId) : null);
      if (!room) return;
      socket.to(room).emit(event, data && data.payload !== undefined ? data.payload : data);
    };

    socket.on('offer', relay('offer'));
    socket.on('answer', relay('answer'));
    socket.on('candidate', relay('candidate'));

    // Estado de camara/mic del operador -> el kiosko muestra avatar o video
    socket.on('media_state', (data) => {
      const room = socket.data.callRoom;
      if (!room) return;
      socket.to(room).emit('remote_media_state', data);
    });

    // ---------------------------------------------------------------------
    // Desconexion
    // ---------------------------------------------------------------------
    socket.on('disconnect', () => {
      if (socket.data.role === 'kiosk') {
        const set = kiosks.get(socket.data.kioskId);
        if (set) {
          set.delete(socket.id);
          if (set.size === 0) kiosks.delete(socket.data.kioskId);
        }
        console.log(`[SOCKET] Kiosko '${socket.data.kioskId}' offline`);
        broadcastPresence();
        // Si estaba en llamada, avisamos al operador
        if (activeCall && activeCall.kioskId === socket.data.kioskId) {
          io.to(BACKOFFICE_ROOM).emit('call_state', { active: false, kioskId: activeCall.kioskId, reason: 'kiosk_offline' });
          activeCall = null;
        }
      } else if (socket.data.role === 'backoffice') {
        terminateCall('operador desconectado');
        console.log('[SOCKET] Backoffice desconectado');
      }
    });
  });

  // -------------------------------------------------------------------------
  // API interna para el resto del servidor
  // -------------------------------------------------------------------------
  return {
    /** Emite una alarma (viene del webhook de Verkada). */
    emitAlarm(entry, extra = {}) {
      io.to(BACKOFFICE_ROOM).emit('alarm', { ...entry, ...extra });
    },
    /** Push periodico de salud + estado de streams. */
    emitHealth(payload) {
      io.to(BACKOFFICE_ROOM).emit('health', payload);
    },
    /** Saludo a una Persona de Interes -> popup en su kiosko. */
    emitPoiGreeting(kioskId, payload) {
      io.to(roomFor(kioskId)).emit('poi_greeting', payload);
    },
    /** El saludo tambien queda en la linea de tiempo del backoffice. */
    emitPoiEvent(entry) {
      io.to(BACKOFFICE_ROOM).emit('poi_event', entry);
    },
    /** Apariencia del kiosko actualizada -> se aplica en vivo, sin reiniciar. */
    emitAppearance(cfg) {
      io.emit('appearance_updated', cfg);
    },
    onlineKiosks,
    getActiveCall: () => activeCall,
  };
}

module.exports = { register };
