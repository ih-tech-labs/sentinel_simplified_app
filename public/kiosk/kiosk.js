/* ==========================================================================
   Sentinel Kiosk · v5

   Cambios de fondo respecto de la v4:

   1. Los listeners de signaling (`offer`, `candidate`, `remote_media_state`)
      se registraban DENTRO de startCall(). Cada llamada dejaba un listener más:
      a la quinta llamada un mismo ICE candidate se procesaba cinco veces y el
      proceso de Chromium iba creciendo hasta que el kiosko se ponía lento.
      Ahora se registran UNA sola vez y consultan el estado actual.

   2. El video de fondo se pausaba durante la llamada y a veces no volvía
      (Chromium descarta el decoder si la pestaña pierde foco). Ahora hay un
      watchdog que verifica que siga avanzando y lo revive si se congela.

   3. Reintento de autoplay: si Chromium bloquea el arranque del video, se
      reintenta en vez de quedar con pantalla negra para siempre.
   ========================================================================== */
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);

  const el = {
    bg: $('bgVideo'),
    idle: $('idle'),
    call: $('call'),
    stage: $('call-stage'),
    remote: $('remoteVideo'),
    clock: $('clock'),
    date: $('date'),
    sdot: document.querySelector('.statusline'),
    slabel: $('slabel'),
    timer: $('call-timer'),
    wIcon: $('w-icon'),
    wTemp: $('w-temp'),
    wDesc: $('w-desc'),
    wRange: $('w-range'),
    wCity: $('w-city'),
  };

  const KIOSK_ID = new URLSearchParams(location.search).get('id') || 'admin';

  const state = {
    pc: null,
    enterPromise: null,
    localStream: null,
    inCall: false,
    remoteVideoOn: true,   // lo que el operador declara sobre su cámara
    callStartedAt: 0,
    callTimer: null,
    pendingIce: [],
  };

  // ==========================================================================
  // Reloj y fecha
  // ==========================================================================

  let lastMinute = -1;
  function tick() {
    const now = new Date();
    const m = now.getMinutes();
    if (m !== lastMinute) {
      lastMinute = m;
      el.clock.textContent = now.toLocaleTimeString('es-AR', {
        hour: '2-digit', minute: '2-digit', hour12: false,
      });
      const d = now.toLocaleDateString('es-AR', { weekday: 'long', day: 'numeric', month: 'long' });
      el.date.textContent = d.charAt(0).toUpperCase() + d.slice(1);
    }
  }
  tick();
  // Cada 10s alcanza: solo repintamos cuando cambia el minuto, así evitamos
  // 86.400 reflows por día sobre el video.
  setInterval(tick, 10000);

  // ==========================================================================
  // Clima
  // ==========================================================================

  const WMO = [
    { max: 0, icon: 'sun', desc: 'Despejado' },
    { max: 3, icon: 'cloud-sun', desc: 'Parcialmente nublado' },
    { max: 48, icon: 'fog', desc: 'Niebla' },
    { max: 57, icon: 'rain', desc: 'Llovizna' },
    { max: 67, icon: 'rain', desc: 'Lluvia' },
    { max: 77, icon: 'snow', desc: 'Nieve' },
    { max: 82, icon: 'rain', desc: 'Chaparrones' },
    { max: 99, icon: 'storm', desc: 'Tormenta' },
  ];

  const SVG = {
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    'cloud-sun': '<path d="M12 2v2M4.2 5.6l1.4 1.4M2 13h2M19.8 5.6l-1.4 1.4"/><circle cx="12" cy="11" r="3"/><path d="M17 20H8a4 4 0 0 1 0-8 5 5 0 0 1 9.6 1.3A3.4 3.4 0 0 1 17 20Z"/>',
    fog: '<path d="M5 15h14M4 19h16M6.5 11a5 5 0 0 1 9.7-1.4A3.5 3.5 0 0 1 17.5 11"/>',
    rain: '<path d="M17 14H8a4 4 0 0 1 0-8 5 5 0 0 1 9.6 1.3A3.4 3.4 0 0 1 17 14Z"/><path d="M9 18l-1 3M13 18l-1 3M17 18l-1 3"/>',
    snow: '<path d="M17 13H8a4 4 0 0 1 0-8 5 5 0 0 1 9.6 1.3A3.4 3.4 0 0 1 17 13Z"/><path d="M9 17h.01M12 19h.01M15 17h.01M12 15h.01"/>',
    storm: '<path d="M17 12H8a4 4 0 0 1 0-8 5 5 0 0 1 9.6 1.3A3.4 3.4 0 0 1 17 12Z"/><path d="m12 15-2 4h3l-1.5 4"/>',
  };

  function weatherFor(code) {
    for (const w of WMO) if (code <= w.max) return w;
    return WMO[0];
  }

  async function updateWeather() {
    const url = 'https://api.open-meteo.com/v1/forecast'
      + '?latitude=-34.6037&longitude=-58.3816'
      + '&current=temperature_2m,weather_code'
      + '&daily=temperature_2m_max,temperature_2m_min'
      + '&timezone=America%2FArgentina%2FBuenos_Aires';

    try {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 8000);
      const res = await fetch(url, { signal: ctrl.signal, cache: 'no-store' });
      clearTimeout(t);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const d = await res.json();

      const w = weatherFor(d.current.weather_code);
      el.wTemp.textContent = `${Math.round(d.current.temperature_2m)}°`;
      el.wDesc.textContent = w.desc;
      el.wRange.textContent = `Máx ${Math.round(d.daily.temperature_2m_max[0])}° · Mín ${Math.round(d.daily.temperature_2m_min[0])}°`;
      el.wIcon.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"
        stroke-linecap="round" stroke-linejoin="round">${SVG[w.icon]}</svg>`;
    } catch (err) {
      // Sin internet el kiosko igual funciona: dejamos el último valor visible
      console.warn('[weather]', err.message);
    }
  }
  updateWeather();
  setInterval(updateWeather, 15 * 60 * 1000);

  // ==========================================================================
  // Watchdog del video de fondo
  // ==========================================================================

  function ensureBgPlaying() {
    const v = el.bg;
    if (!v) return;
    if (v.paused || v.ended) {
      v.play().catch(() => {
        // Chromium puede bloquear autoplay: reintentamos en el próximo ciclo
      });
    }
  }

  // Si el tiempo del video no avanza en 5 s, está congelado: lo reiniciamos.
  let lastBgTime = -1;
  let stuckCount = 0;
  setInterval(() => {
    const v = el.bg;
    if (!v || state.inCall) return;
    ensureBgPlaying();
    if (v.readyState < 2) return;

    if (Math.abs(v.currentTime - lastBgTime) < 0.05) {
      stuckCount++;
      if (stuckCount >= 2) {
        console.warn('[bg] Video congelado, reiniciando');
        stuckCount = 0;
        const t = v.currentTime;
        v.load();
        v.currentTime = t;
        v.play().catch(() => { });
      }
    } else {
      stuckCount = 0;
    }
    lastBgTime = v.currentTime;
  }, 5000);

  el.bg.addEventListener('error', () => {
    console.error('[bg] Error de video, recargando en 3s');
    setTimeout(() => el.bg.load(), 3000);
  });

  // Chromium a veces suspende el decoder al recuperar el foco
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && !state.inCall) ensureBgPlaying();
  });
  window.addEventListener('focus', () => { if (!state.inCall) ensureBgPlaying(); });
  document.addEventListener('click', ensureBgPlaying, { once: true });
  ensureBgPlaying();

  // ==========================================================================
  // Socket
  // ==========================================================================

  const socket = io({
    transports: ['websocket', 'polling'],
    reconnection: true,
    reconnectionDelay: 1000,
    reconnectionDelayMax: 10000,
  });

  function setStatus(kind, label) {
    el.sdot.className = `statusline ${kind}`;
    el.slabel.textContent = label;
  }

  socket.on('connect', () => {
    setStatus('ok', 'Sistema activo');
    socket.emit('register', { role: 'kiosk', id: KIOSK_ID }, (ack) => {
      if (ack && !ack.ok) setStatus('bad', 'Puesto no configurado');
    });
  });

  socket.on('disconnect', () => setStatus('bad', 'Sin conexión'));
  socket.on('connect_error', () => setStatus('bad', 'Reconectando'));

  // ==========================================================================
  // WebRTC — listeners registrados UNA sola vez
  // ==========================================================================

  const RTC_CONFIG = { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] };

  socket.on('call_incoming', () => {
    if (state.inCall) return;
    enterCall();
  });

  socket.on('call_ended', () => leaveCall());

  socket.on('offer', async (offer) => {
    // Esperamos a que enterCall() esté COMPLETO, no sólo empezado.
    // Antes se comprobaba `if (!state.pc)`, pero state.pc se asigna al principio
    // de enterCall y los handlers al final, después de pedir el micrófono. Si la
    // oferta llegaba en el medio, setRemoteDescription disparaba los eventos de
    // track sin que pc.ontrack existiera todavía: se perdían y el kiosko nunca
    // mostraba al operador.
    await enterCall();
    if (!state.pc) return;
    try {
      await state.pc.setRemoteDescription(new RTCSessionDescription(offer));
      for (const c of state.pendingIce) {
        try { await state.pc.addIceCandidate(new RTCIceCandidate(c)); } catch (_) { }
      }
      state.pendingIce = [];
      const answer = await state.pc.createAnswer();
      await state.pc.setLocalDescription(answer);
      socket.emit('answer', answer);
    } catch (err) {
      console.error('[rtc] offer:', err);
    }
  });

  socket.on('candidate', async (candidate) => {
    if (!state.pc || !state.pc.remoteDescription) {
      state.pendingIce.push(candidate);
      return;
    }
    try { await state.pc.addIceCandidate(new RTCIceCandidate(candidate)); } catch (_) { }
  });

  // Estado declarado por el operador. Es la fuente de verdad de si tiene la
  // cámara prendida; los eventos mute/unmute del track son sólo una pista de
  // si están llegando cuadros en este instante.
  socket.on('remote_media_state', (data) => {
    if (data && data.type === 'video') {
      state.remoteVideoOn = Boolean(data.enabled);
      setAvatar(!state.remoteVideoOn);
    }
  });

  function setAvatar(show) {
    el.stage.classList.toggle('avatar-on', show);
  }

  // enterCall() puede dispararse por dos caminos casi simultáneos —
  // 'call_incoming' y 'offer'— así que se memoriza la promesa: el segundo
  // llamador espera a la misma inicialización en vez de arrancar otra o de
  // seguir de largo con una conexión a medio construir.
  function enterCall() {
    if (!state.enterPromise) {
      state.enterPromise = _enterCall().catch((err) => {
        console.error('[rtc] enterCall:', err);
        state.enterPromise = null;
      });
    }
    return state.enterPromise;
  }

  async function _enterCall() {
    if (state.pc) return;
    state.inCall = true;

    el.idle.classList.add('away');
    el.call.classList.add('active');
    setAvatar(true); // arrancamos con avatar: evita el flash de pantalla negra

    // Bajamos el video de fondo a un cuadro cada mucho en vez de pausarlo:
    // pausar y despausar es justo lo que a veces dejaba el decoder colgado.
    try { el.bg.pause(); } catch (_) { }

    state.callStartedAt = Date.now();
    el.timer.textContent = '00:00';
    state.callTimer = setInterval(() => {
      const s = Math.floor((Date.now() - state.callStartedAt) / 1000);
      el.timer.textContent = `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
    }, 1000);

    const pc = new RTCPeerConnection(RTC_CONFIG);

    // TODOS los handlers se enganchan ANTES de cualquier await. Si se dejan
    // para después, una oferta que llegue mientras se pide el micrófono
    // dispara los eventos de track sin nadie escuchando y el video se pierde
    // para siempre: la llamada se establece pero la pantalla queda en negro.
    pc.ontrack = (e) => {
      const stream = e.streams[0];
      if (el.remote.srcObject !== stream) {
        el.remote.srcObject = stream;
        // El play puede fallar por la política de autoplay. Reintentamos con
        // el primer toque de pantalla, por si el kiosko no se lanzó con
        // --autoplay-policy=no-user-gesture-required.
        el.remote.play().catch(() => {
          document.addEventListener('click', () => el.remote.play().catch(() => { }), { once: true });
          document.addEventListener('touchstart', () => el.remote.play().catch(() => { }), { once: true });
        });
      }
      if (e.track.kind === 'video') {
        // El track llega 'muted' hasta que corren los primeros cuadros:
        // en cuanto lleguen, mostramos el video si el operador dice tener la
        // cámara prendida.
        if (!e.track.muted && state.remoteVideoOn) setAvatar(false);
        e.track.onunmute = () => { if (state.remoteVideoOn) setAvatar(false); };
        e.track.onmute = () => setAvatar(true);
      }
    };

    pc.onicecandidate = (e) => { if (e.candidate) socket.emit('candidate', e.candidate); };

    pc.onconnectionstatechange = () => {
      if (['failed', 'disconnected', 'closed'].includes(pc.connectionState)) {
        console.warn('[rtc] conexión', pc.connectionState);
        if (pc.connectionState !== 'disconnected') leaveCall();
      }
    };

    state.pc = pc;

    try {
      state.localStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        video: false,
      });
      state.localStream.getTracks().forEach((t) => pc.addTrack(t, state.localStream));
    } catch (err) {
      console.error('[rtc] micrófono:', err);
      // Seguimos igual: el vecino escucha al operador aunque no pueda responder
    }
  }

  function leaveCall() {
    if (!state.inCall && !state.pc) return;
    state.inCall = false;

    state.enterPromise = null;
    state.remoteVideoOn = true;
    if (state.callTimer) { clearInterval(state.callTimer); state.callTimer = null; }
    if (state.pc) { try { state.pc.close(); } catch (_) { } state.pc = null; }
    if (state.localStream) {
      state.localStream.getTracks().forEach((t) => t.stop());
      state.localStream = null;
    }
    state.pendingIce = [];
    el.remote.srcObject = null;

    el.call.classList.remove('active');
    el.idle.classList.remove('away');
    setAvatar(false);

    // Damos un instante a la transición antes de reanudar el fondo
    setTimeout(ensureBgPlaying, 120);
  }

  // ==========================================================================
  // Higiene de kiosko
  // ==========================================================================

  // Nada de menú contextual ni de zoom por gestos en una pantalla pública
  document.addEventListener('contextmenu', (e) => e.preventDefault());
  document.addEventListener('gesturestart', (e) => e.preventDefault());
  document.addEventListener('dblclick', (e) => e.preventDefault());

  // Recarga preventiva de madrugada: limpia cualquier fuga acumulada del
  // navegador tras semanas encendido. Solo si no hay una llamada en curso.
  setInterval(() => {
    const now = new Date();
    if (now.getHours() === 4 && now.getMinutes() === 30 && !state.inCall) {
      console.log('[kiosk] Recarga programada');
      location.reload();
    }
  }, 60000);

})();
