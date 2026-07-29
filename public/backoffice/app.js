/* ==========================================================================
   Sentinel Backoffice · v5
   ========================================================================== */
(function () {
  'use strict';

  // ------------------------------------------------------------------ estado
  const state = {
    user: '--',
    cameras: [],
    presence: {},
    events: [],
    filters: { kiosk: 'all', severity: 'all' },
    call: null,             // { kioskId, pc, localStream, startedAt, timer }
    media: { audio: true, video: true },
    players: {},            // kioskId -> JSMpeg.Player
    audioUnlocked: false,
    alarming: new Set(),    // kioskIds con alarma sin reconocer
  };

  // Tope de eventos que el navegador guarda y dibuja. El historial completo
  // vive en el servidor (data/events.jsonl); acá sólo interesa lo reciente,
  // y cada evento de más es un nodo del DOM que hay que repintar.
  const MAX_EVENTS = 200;

  const $ = (id) => document.getElementById(id);
  const socket = io({ transports: ['websocket', 'polling'], reconnectionDelayMax: 8000 });

  // ==========================================================================
  // Utilidades
  // ==========================================================================

  const pad = (n) => String(n).padStart(2, '0');

  function fmtTime(ts) {
    const d = new Date(ts);
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  function fmtRelative(ts) {
    const s = Math.floor((Date.now() - ts) / 1000);
    if (s < 60) return 'ahora';
    if (s < 3600) return `${Math.floor(s / 60)}m`;
    if (s < 86400) return `${Math.floor(s / 3600)}h`;
    return `${Math.floor(s / 86400)}d`;
  }

  function fmtDuration(sec) {
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (h > 0) return `${h}h ${pad(m)}m`;
    return `${m}m ${pad(sec % 60)}s`;
  }

  function fmtBytes(b) {
    if (!b) return '0';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.min(Math.floor(Math.log(b) / Math.log(1024)), u.length - 1);
    return `${(b / Math.pow(1024, i)).toFixed(i === 0 ? 0 : 1)}${u[i]}`;
  }

  /** Escapa texto que viene del servidor antes de meterlo en el DOM. */
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
  }

  const ICONS = {
    phone: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6A19.79 19.79 0 0 1 2.12 4.18 2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.9.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92Z"/></svg>',
    hangup: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6A19.79 19.79 0 0 1 2.12 4.18 2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.9.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92Z"/><line x1="2" y1="22" x2="22" y2="2"/></svg>',
    mic: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="22"/></svg>',
    micOff: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="2" y1="2" x2="22" y2="22"/><path d="M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V5a3 3 0 0 0-5.94-.6"/><path d="M17 16.95A7 7 0 0 1 5 12v-2m14 0v2a7 7 0 0 1-.11 1.23"/><line x1="12" y1="19" x2="12" y2="22"/></svg>',
    cam: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m23 7-7 5 7 5V7Z"/><rect x="1" y="5" width="15" height="14" rx="2"/></svg>',
    camOff: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 16v2a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2m3-3 15 15M23 7l-7 5"/></svg>',
    bell: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>',
    user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="34" height="34"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>',
  };

  const SWATCH = {
    off: '#1c2838', white: '#f8fafc', warm: '#fde68a', blue: '#3b82f6',
    green: '#22c55e', red: '#ef4444', yellow: '#f59e0b',
    siren: '#dc2626', emergency: '#f97316',
  };

  // Copia local de los presets del servidor. La lista es estática y sirve
  // para dibujar la botonera aunque el fetch falle: un panel vacío no le dice
  // nada a nadie y es imposible de diagnosticar a distancia.
  const PRESETS_FALLBACK = [
    { key: 'off', label: 'Apagar todo', kind: 'off' },
    { key: 'white', label: 'Luz blanca', kind: 'light' },
    { key: 'warm', label: 'Luz cálida', kind: 'light' },
    { key: 'blue', label: 'Azul', kind: 'light' },
    { key: 'green', label: 'Verde', kind: 'light' },
    { key: 'red', label: 'Rojo', kind: 'light' },
    { key: 'yellow', label: 'Ámbar', kind: 'light' },
    { key: 'siren', label: 'Sirena', kind: 'alarm' },
    { key: 'emergency', label: 'Emergencia', kind: 'alarm' },
  ];

  // ==========================================================================
  // Reloj
  // ==========================================================================

  setInterval(() => {
    const d = new Date();
    $('clock').textContent = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }, 1000);

  // ==========================================================================
  // Construcción de tarjetas
  // ==========================================================================

  function buildCards() {
    const grid = $('cam-grid');
    grid.innerHTML = '';

    // Con un solo puesto la grilla queda vacía y la tarjeta perdida en el medio.
    // El modo "single" la centra, la agranda y trata el video como protagonista.
    const single = state.cameras.length === 1;
    grid.classList.toggle('single', single);
    document.body.classList.toggle('mono-cam', single);

    state.cameras.forEach((cam) => {
      const id = cam.id;
      const card = document.createElement('article');
      card.className = 'cam-card';
      card.id = `card-${id}`;
      card.innerHTML = `
        <div class="cam-head">
          <div class="cam-title">
            <span class="cam-name">${esc(cam.name)}</span>
            <span class="cam-zone">${esc(cam.zone || cam.id)}</span>
          </div>
          <div class="cam-badges">
            <span class="badge-state offline" id="state-${id}">OFFLINE</span>
          </div>
        </div>

        <div class="cam-stage" id="stage-${id}">
          <canvas id="canvas-${id}"></canvas>
          <div class="stage-tag"><span class="rec"></span>${esc(cam.shortName || id.toUpperCase())}</div>
          <div class="stage-msg" id="msg-${id}"><div class="spinner"></div><span>Conectando</span></div>

          <div class="call-layer" id="call-${id}">
            <video class="remote-video" id="remote-${id}" autoplay playsinline></video>
            <audio id="audio-${id}" autoplay></audio>
            <div class="call-timer" id="timer-${id}">00:00</div>
            <div class="call-pip">
              <video id="local-${id}" autoplay playsinline muted></video>
              <div class="pip-off" id="pipoff-${id}">${ICONS.user}</div>
            </div>
          </div>
        </div>

        <div class="cam-foot" id="foot-${id}"></div>
      `;
      grid.appendChild(card);
    });

    // Los pies se generan con callFooter(): una sola definición del markup
    state.cameras.forEach((cam) => callFooter(cam.id, false));

    grid.onclick = (e) => {
      const btn = e.target.closest('button[data-act]');
      if (!btn) return;
      const { act, id } = btn.dataset;
      if (act === 'call') startCall(id);
      else if (act === 'hangup') endCall();
      else if (act === 'test') socket.emit('test_alarm', id);
      else if (act === 'mute') toggleMedia('audio');
      else if (act === 'cam') toggleMedia('video');
    };

    // Click en la tarjeta silencia su alarma
    state.cameras.forEach((cam) => {
      const card = $(`card-${cam.id}`);
      card.addEventListener('click', () => clearAlarm(cam.id));
    });

    // Encabezado acorde a la cantidad de puestos
    const head = document.querySelector('.section-head h2');
    if (head) head.textContent = single ? esc(state.cameras[0].name) : 'Puestos de Monitoreo';

    // El filtro por puesto sólo tiene sentido con más de uno
    const sel = $('f-kiosk');
    if (single) {
      sel.style.display = 'none';
      $('f-sev').parentElement.classList.add('one-col');
    } else {
      sel.style.display = '';
      $('f-sev').parentElement.classList.remove('one-col');
      sel.innerHTML = '<option value="all">Todos los puestos</option>' +
        state.cameras.map((c) => `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join('');
    }
  }

  // ==========================================================================
  // Streams (jsmpeg sobre WebSocket autenticado)
  // ==========================================================================

  function streamUrl(id) {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${proto}//${location.host}/stream/${id}`;
  }

  function startPlayers() {
    if (typeof JSMpeg === 'undefined') {
      console.error('jsmpeg no cargó');
      state.cameras.forEach((c) => setStageMsg(c.id, 'Reproductor no disponible', false));
      return;
    }

    state.cameras.forEach((cam) => {
      const canvas = $(`canvas-${cam.id}`);
      if (!canvas) return;
      try {
        state.players[cam.id] = new JSMpeg.Player(streamUrl(cam.id), {
          canvas,
          autoplay: true,
          audio: false,
          videoBufferSize: 512 * 1024,
          // Sin WebGL en algunos drivers de RPi el canvas 2D es más estable,
          // pero dejamos que jsmpeg elija y caiga solo a 2D si hace falta.
          onSourceEstablished: () => setStageMsg(cam.id, null),
          onSourceCompleted: () => setStageMsg(cam.id, 'Señal interrumpida', false),
          onStalled: () => setStageMsg(cam.id, 'Reconectando', true),
        });
      } catch (err) {
        console.error(`Player ${cam.id}:`, err);
        setStageMsg(cam.id, 'Error de reproductor', false);
      }
    });
  }

  function setStageMsg(id, text, spinner) {
    const el = $(`msg-${id}`);
    if (!el) return;
    if (text === null) {
      el.classList.add('hidden');
      return;
    }
    el.classList.remove('hidden');
    el.innerHTML = (spinner === false ? '' : '<div class="spinner"></div>') + `<span>${esc(text)}</span>`;
  }

  // ==========================================================================
  // Presencia
  // ==========================================================================

  function renderPresence() {
    let online = 0;
    state.cameras.forEach((cam) => {
      const isOn = Boolean(state.presence[cam.id]);
      if (isOn) online++;
      const badge = $(`state-${cam.id}`);
      if (badge) {
        badge.className = `badge-state ${isOn ? 'online' : 'offline'}`;
        badge.textContent = isOn ? 'ONLINE' : 'OFFLINE';
      }
      const callBtn = document.querySelector(`button[data-act="call"][data-id="${cam.id}"]`);
      if (callBtn) callBtn.disabled = !isOn || Boolean(state.call);
    });

    const total = state.cameras.length;
    $('cam-count').textContent = total === 1
      ? (online ? 'Puesto en línea' : 'Puesto fuera de línea')
      : `${online} / ${total} activos`;
  }

  // ==========================================================================
  // Alarmas
  // ==========================================================================

  function triggerAlarm(evt) {
    if (evt.kioskId) {
      const card = $(`card-${evt.kioskId}`);
      if (card) card.classList.add('alarm');
      state.alarming.add(evt.kioskId);
    }
    if (evt.sound) playAlarm();
    refreshAlertBar();
  }

  function clearAlarm(kioskId) {
    if (!state.alarming.has(kioskId)) return;
    state.alarming.delete(kioskId);
    const card = $(`card-${kioskId}`);
    if (card) card.classList.remove('alarm');
    if (state.alarming.size === 0) stopAlarm();
    refreshAlertBar();
  }

  function clearAllAlarms() {
    state.alarming.forEach((id) => {
      const card = $(`card-${id}`);
      if (card) card.classList.remove('alarm');
    });
    state.alarming.clear();
    stopAlarm();
    refreshAlertBar();
  }

  function refreshAlertBar() {
    const bar = $('alert-bar');
    if (state.alarming.size === 0) {
      bar.classList.remove('show');
      return;
    }
    const names = state.cameras
      .filter((c) => state.alarming.has(c.id))
      .map((c) => c.name.toUpperCase());
    $('alert-bar-text').textContent = `ALARMA ACTIVA · ${names.join(' · ')}`;
    bar.classList.add('show');
  }

  // La alarma suena 5 segundos y se corta sola. Antes quedaba en loop hasta
  // que alguien la reconociera: con varias alarmas seguidas era insoportable
  // y terminaba con el operador silenciando la pestaña, que es lo peor que
  // puede pasar en un sistema de monitoreo.
  const ALARM_SECONDS = 5;
  let alarmTimer = null;

  function playAlarm() {
    const a = $('alarmAudio');
    if (alarmTimer) { clearTimeout(alarmTimer); alarmTimer = null; }
    a.currentTime = 0;
    a.loop = true;
    a.play().catch(() => {
      // El navegador bloquea autoplay hasta la primera interacción del usuario
      $('audio-gate').classList.add('show');
    });
    alarmTimer = setTimeout(stopAlarm, ALARM_SECONDS * 1000);
  }

  function stopAlarm() {
    if (alarmTimer) { clearTimeout(alarmTimer); alarmTimer = null; }
    const a = $('alarmAudio');
    a.pause();
    a.loop = false;
    a.currentTime = 0;
  }

  $('audio-gate-btn').onclick = () => {
    const a = $('alarmAudio');
    a.play().then(() => {
      a.pause();
      a.currentTime = 0;
      state.audioUnlocked = true;
      $('audio-gate').classList.remove('show');
    }).catch(() => { });
  };

  $('alert-bar-ack').onclick = (e) => {
    e.stopPropagation();
    socket.emit('ack_all');
    clearAllAlarms();
  };

  // ==========================================================================
  // Timeline de eventos
  // ==========================================================================

  function renderTimeline() {
    const box = $('timeline');
    const { kiosk, severity } = state.filters;

    const list = state.events.filter((e) =>
      (kiosk === 'all' || e.kioskId === kiosk) &&
      (severity === 'all' || e.severity === severity)
    ).slice(0, MAX_EVENTS);

    if (!list.length) {
      box.innerHTML = '<div class="empty">Sin eventos</div>';
      return;
    }

    box.innerHTML = list.map((e) => `
      <div class="evt sev-${esc(e.severity)}${e.ack ? ' acked' : ''}" data-id="${esc(e.id)}">
        <div class="evt-rail"></div>
        <div class="evt-main">
          <div class="evt-top">
            <span class="evt-cam">${esc(e.camera)}</span>
            <span class="evt-time" title="${esc(new Date(e.ts).toLocaleString('es-AR'))}">${fmtTime(e.ts)} · ${fmtRelative(e.ts)}</span>
          </div>
          <div class="evt-detail">${esc(e.details || e.type)}</div>
        </div>
        <button class="evt-ack" title="Reconocer">✓</button>
      </div>
    `).join('');

    box.querySelectorAll('.evt-ack').forEach((btn) => {
      btn.onclick = () => {
        const id = btn.closest('.evt').dataset.id;
        socket.emit('ack_event', id);
        const evt = state.events.find((e) => e.id === id);
        if (evt) {
          evt.ack = true;
          if (evt.kioskId) clearAlarm(evt.kioskId);
          renderTimeline();
        }
      };
    });
  }

  function renderStats(stats) {
    if (!stats) return;
    const badge = $('evt-pending');
    badge.textContent = stats.pending;
    badge.classList.toggle('hot', stats.pending > 0);
  }

  $('f-kiosk').onchange = (e) => { state.filters.kiosk = e.target.value; renderTimeline(); };
  $('f-sev').onchange = (e) => { state.filters.severity = e.target.value; renderTimeline(); };
  $('btn-ack-all').onclick = () => { socket.emit('ack_all'); state.events.forEach((e) => e.ack = true); clearAllAlarms(); renderTimeline(); };

  // Refresca los "hace X" cada 30s sin re-render completo
  setInterval(() => {
    if (state.events.length) renderTimeline();
  }, 30000);

  // ==========================================================================
  // Telemetría
  // ==========================================================================

  function renderHealth(h) {
    if (!h || !h.system) return;
    const s = h.system;

    const set = (id, value, cls) => {
      const el = $(id);
      el.textContent = value;
      el.className = 'tele-v' + (cls ? ' ' + cls : '');
    };

    const lvl = (v, warn, crit) => (v == null ? '' : v >= crit ? 'crit' : v >= warn ? 'warn' : 'ok');

    set('m-cpu', s.cpu == null ? '--' : `${s.cpu}%`, lvl(s.cpu, 70, 90));
    set('m-temp', s.temp == null ? '--' : `${s.temp}°`, lvl(s.temp, 68, 80));
    set('m-ram', s.memory ? `${s.memory.percent}%` : '--', lvl(s.memory && s.memory.percent, 80, 92));
    set('m-disk', s.disk ? `${s.disk.percent}%` : '--', lvl(s.disk && s.disk.percent, 85, 95));
    set('m-uptime', fmtDuration(s.uptimeProcess));

    if (h.kiosks) { state.presence = h.kiosks; renderPresence(); }
    if (h.events) renderStats(h.events);

    // Estado de los streams sobre el cartel de cada cámara
    if (Array.isArray(h.streams)) {
      h.streams.forEach((st) => {
        if (st.status === 'live') return;                       // el player maneja el cartel
        if (st.status === 'retrying') setStageMsg(st.id, 'Reconectando cámara', true);
        else if (st.status === 'error') setStageMsg(st.id, 'Error de cámara', false);
      });
    }
  }

  // ==========================================================================
  // Control de dispositivos (Arduino)
  // ==========================================================================

  function renderPresets(presets) {
    const grid = $('preset-grid');
    if (!grid) return;
    grid.innerHTML = presets.map((p) => `
      <button class="preset" data-preset="${esc(p.key)}" data-kind="${esc(p.kind)}" title="${esc(p.label)}">
        <span class="swatch" style="background:${SWATCH[p.key] || '#334155'}"></span>
        <span>${esc(p.label)}</span>
      </button>
    `).join('');
    grid.onclick = async (e) => {
      const btn = e.target.closest('button[data-preset]');
      if (btn) await sendPreset(btn);
    };
  }

  async function loadPresets() {
    // Se dibuja PRIMERO con la lista local. Si el servidor responde, se
    // reemplaza por la suya. Así la botonera aparece siempre, incluso si la
    // API falla o tarda.
    renderPresets(PRESETS_FALLBACK);
    try {
      const res = await fetch('/api/devices/presets');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const presets = await res.json();
      if (Array.isArray(presets) && presets.length) renderPresets(presets);
    } catch (err) {
      console.warn('[presets]', err);
      const fb = $('gpio-feedback');
      if (fb) {
        fb.className = 'gpio-feedback bad';
        fb.textContent = 'No se pudo consultar el servidor (' + err.message + ')';
      }
    }
  }

  async function sendPreset(btn) {
    const key = btn.dataset.preset;
    const fb = $('gpio-feedback');
    document.querySelectorAll('.preset').forEach((b) => b.disabled = true);
    fb.className = 'gpio-feedback';
    fb.textContent = 'Enviando...';

    try {
      const res = await fetch(`/api/devices/preset/${encodeURIComponent(key)}`, { method: 'POST' });
      const data = await res.json();
      if (res.ok && data.ok) {
        fb.className = 'gpio-feedback ok';
        fb.textContent = `✓ ${data.label} (${data.via})`;
        $('gpio-state').className = 'dot-state ok';
      } else {
        fb.className = 'gpio-feedback bad';
        fb.textContent = `✗ ${data.error || 'Falló el comando'}`;
        $('gpio-state').className = 'dot-state bad';
      }
    } catch (err) {
      fb.className = 'gpio-feedback bad';
      fb.textContent = '✗ Sin conexión con el servidor';
      $('gpio-state').className = 'dot-state bad';
    } finally {
      document.querySelectorAll('.preset').forEach((b) => b.disabled = false);
      setTimeout(() => { if (fb.textContent.startsWith('✓')) fb.textContent = ''; }, 4000);
    }
  }

  // ==========================================================================
  // WebRTC
  // ==========================================================================

  const RTC_CONFIG = {
    // Todo es LAN: los candidatos host alcanzan. Se deja un STUN publico por
    // si algun dia el backoffice se abre desde afuera por el tunel.
    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
    iceCandidatePoolSize: 0,
  };

  // Los controles de micrófono y cámara están SIEMPRE visibles, en llamada y
  // fuera de ella. Fuera de la llamada dejan preconfigurado con qué estado
  // arranca la próxima: si vas a llamar con la cámara apagada, lo decidís
  // antes y no en el medio de la conversación.
  function callFooter(id, inCall) {
    const foot = $(`foot-${id}`);
    if (!foot) return;
    const media = `
      <button class="btn btn-icon" data-act="mute" data-id="${id}" title="Micrófono">${ICONS.mic}</button>
      <button class="btn btn-icon" data-act="cam" data-id="${id}" title="Cámara">${ICONS.cam}</button>
    `;
    if (inCall) {
      foot.innerHTML = media + `
        <button class="btn btn-danger" data-act="hangup" data-id="${id}">${ICONS.hangup}<span>Colgar</span></button>
      `;
    } else {
      foot.innerHTML = `
        <button class="btn btn-primary" data-act="call" data-id="${id}">${ICONS.phone}<span>Llamar</span></button>
      ` + media + `
        <button class="btn btn-icon" data-act="test" data-id="${id}" title="Alarma de prueba">${ICONS.bell}</button>
      `;
    }
    syncMediaButtons();
  }

  // Sincroniza los botones de TODAS las tarjetas: el estado de micrófono y
  // cámara es del operador, no de una cámara en particular.
  function syncMediaButtons() {
    document.querySelectorAll('button[data-act="mute"]').forEach((btn) => {
      btn.innerHTML = state.media.audio ? ICONS.mic : ICONS.micOff;
      btn.classList.toggle('muted', !state.media.audio);
      btn.title = state.media.audio ? 'Silenciar micrófono' : 'Activar micrófono';
    });
    document.querySelectorAll('button[data-act="cam"]').forEach((btn) => {
      btn.innerHTML = state.media.video ? ICONS.cam : ICONS.camOff;
      btn.classList.toggle('muted', !state.media.video);
      btn.title = state.media.video ? 'Apagar cámara' : 'Encender cámara';
    });
    const id = state.call && state.call.kioskId;
    if (id) {
      const pipOff = $(`pipoff-${id}`);
      if (pipOff) pipOff.classList.toggle('show', !state.media.video);
    }
  }

  function toggleMedia(kind) {
    state.media[kind] = !state.media[kind];
    const call = state.call;
    if (call && call.localStream) {
      const tracks = kind === 'audio' ? call.localStream.getAudioTracks() : call.localStream.getVideoTracks();
      tracks.forEach((t) => { t.enabled = state.media[kind]; });
    }
    // Sólo tiene sentido avisarle al kiosko si hay una llamada en curso
    if (kind === 'video' && call) {
      socket.emit('media_state', { type: 'video', enabled: state.media.video });
    }
    syncMediaButtons();
  }

  async function startCall(kioskId) {
    if (state.call) return;
    if (!state.presence[kioskId]) return;

    let localStream;
    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        video: { width: { ideal: 640 }, height: { ideal: 480 }, frameRate: { ideal: 20, max: 24 } },
      });
    } catch (err) {
      alert('No se pudo acceder a cámara/micrófono.\n\n' + err.message);
      return;
    }

    socket.emit('start_call', kioskId, async (ack) => {
      if (!ack || !ack.ok) {
        localStream.getTracks().forEach((t) => t.stop());
        alert(ack && ack.error ? ack.error : 'No se pudo iniciar la llamada.');
        return;
      }

      try {

      const pc = new RTCPeerConnection(RTC_CONFIG);
      state.call = { kioskId, pc, localStream, startedAt: Date.now(), timer: null, pendingIce: [] };

      localStream.getAudioTracks().forEach((t) => { t.enabled = state.media.audio; });
      localStream.getVideoTracks().forEach((t) => { t.enabled = state.media.video; });
      localStream.getTracks().forEach((t) => pc.addTrack(t, localStream));

      $(`local-${kioskId}`).srcObject = localStream;
      $(`call-${kioskId}`).classList.add('active');
      callFooter(kioskId, true);
      renderPresence();

      pc.ontrack = (e) => {
        const stream = e.streams[0];
        if (e.track.kind === 'audio') {
          const el = $(`audio-${kioskId}`);
          if (el.srcObject !== stream) el.srcObject = stream;
        } else {
          const el = $(`remote-${kioskId}`);
          if (el.srcObject !== stream) el.srcObject = stream;
          // Recién acá tapamos el RTSP. Si el kiosko no manda video (es lo
          // normal: sólo tiene micrófono), el operador sigue viendo la cámara
          // durante toda la llamada en vez de un rectángulo negro.
          const showVideo = () => $(`call-${kioskId}`).classList.add('has-remote-video');
          if (!e.track.muted) showVideo();
          e.track.onunmute = showVideo;
          e.track.onmute = () => $(`call-${kioskId}`).classList.remove('has-remote-video');
        }
      };

      pc.onicecandidate = (e) => {
        if (e.candidate) socket.emit('candidate', e.candidate);
      };

      pc.onconnectionstatechange = () => {
        if (['failed', 'closed'].includes(pc.connectionState)) endCall();
      };

      // Cronómetro
      state.call.timer = setInterval(() => {
        const el = $(`timer-${kioskId}`);
        if (!el || !state.call) return;
        const s = Math.floor((Date.now() - state.call.startedAt) / 1000);
        el.textContent = `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
      }, 1000);

      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      socket.emit('offer', offer);
      // Le informamos al kiosko el estado inicial de la cámara para que no
      // muestre una pantalla negra si arrancamos con la cámara apagada.
      socket.emit('media_state', { type: 'video', enabled: state.media.video });

      } catch (err) {
        // Sin esto, un error acá dejaba la llamada a medio armar y en silencio:
        // el kiosko mostraba la pantalla de llamada pero nunca llegaba el video,
        // y en el backoffice no aparecían los controles.
        console.error('[rtc] startCall:', err);
        alert('No se pudo establecer la llamada.\n\n' + (err && err.message ? err.message : err));
        endCall();
      }
    });
  }

  function endCall() {
    const call = state.call;
    if (!call) return;
    const { kioskId } = call;

    socket.emit('end_call');
    if (call.timer) clearInterval(call.timer);
    if (call.pc) { try { call.pc.close(); } catch (_) { } }
    if (call.localStream) call.localStream.getTracks().forEach((t) => t.stop());

    const local = $(`local-${kioskId}`); if (local) local.srcObject = null;
    const remote = $(`remote-${kioskId}`); if (remote) remote.srcObject = null;
    const audio = $(`audio-${kioskId}`); if (audio) audio.srcObject = null;
    const layer = $(`call-${kioskId}`);
    if (layer) { layer.classList.remove('active'); layer.classList.remove('has-remote-video'); }
    const timer = $(`timer-${kioskId}`); if (timer) timer.textContent = '00:00';

    state.call = null;
    callFooter(kioskId, false);
    renderPresence();
  }

  socket.on('answer', async (answer) => {
    const call = state.call;
    if (!call || !call.pc) return;
    if (call.pc.signalingState !== 'have-local-offer') return;
    try {
      await call.pc.setRemoteDescription(new RTCSessionDescription(answer));
      for (const c of call.pendingIce) {
        try { await call.pc.addIceCandidate(new RTCIceCandidate(c)); } catch (_) { }
      }
      call.pendingIce = [];
    } catch (err) {
      console.error('answer:', err);
    }
  });

  socket.on('candidate', async (candidate) => {
    const call = state.call;
    if (!call || !call.pc) return;
    // Si todavía no hay descripción remota, encolamos en vez de descartar
    if (!call.pc.remoteDescription) { call.pendingIce.push(candidate); return; }
    try { await call.pc.addIceCandidate(new RTCIceCandidate(candidate)); } catch (_) { }
  });

  socket.on('call_ended', () => endCall());

  socket.on('call_state', (s) => {
    if (!s.active && state.call && state.call.kioskId === s.kioskId) endCall();
  });

  // ==========================================================================
  // Socket lifecycle
  // ==========================================================================

  function setLink(status, label) {
    const el = $('link-state');
    el.className = `link-state ${status}`;
    $('link-label').textContent = label;
  }

  socket.on('connect', () => {
    setLink('online', 'EN LÍNEA');
    socket.emit('register', 'backoffice', (ack) => {
      if (ack && !ack.ok && ack.error === 'unauthorized') location.replace('/login/');
    });
  });

  socket.on('disconnect', () => {
    setLink('offline', 'SIN CONEXIÓN');
    state.presence = {};
    renderPresence();
  });

  socket.on('connect_error', () => setLink('offline', 'RECONECTANDO'));
  socket.on('force_logout', () => location.replace('/login/'));

  socket.on('bootstrap', (data) => {
    state.user = data.user;
    state.cameras = data.cameras || [];
    state.presence = data.presence || {};
    state.events = (data.events || []).slice(0, MAX_EVENTS);

    $('user-name').textContent = data.user;

    if (data.site) {
      const chip = $('site-name');
      if (chip) chip.textContent = data.site;
      document.title = `${data.site} · Centro de Monitoreo`;
    }
    // Cada paso en su propio try: antes, si buildCards o startPlayers tiraban,
    // loadPresets nunca llegaba a correr y el panel de dispositivos quedaba
    // vacío sin ninguna pista de por qué.
    const paso = (nombre, fn) => {
      try { fn(); } catch (err) { console.error('[bootstrap] ' + nombre + ':', err); }
    };
    paso('presets', loadPresets);
    paso('tarjetas', buildCards);
    paso('presencia', renderPresence);
    paso('eventos', renderTimeline);
    paso('contadores', () => renderStats(data.stats));
    paso('reproductores', startPlayers);

    // Si quedaron eventos sin reconocer al abrir, los marcamos visualmente
    state.events.filter((e) => !e.ack && e.severity === 'alert').forEach((e) => {
      if (e.kioskId && Date.now() - e.ts < 5 * 60 * 1000) {
        state.alarming.add(e.kioskId);
        const card = $(`card-${e.kioskId}`);
        if (card) card.classList.add('alarm');
      }
    });
    refreshAlertBar();
  });

  socket.on('kiosk_presence', (p) => { state.presence = p; renderPresence(); });

  socket.on('alarm', (evt) => {
    state.events.unshift(evt);
    if (state.events.length > MAX_EVENTS) state.events.length = MAX_EVENTS;
    renderTimeline();
    triggerAlarm(evt);
  });

  socket.on('event_acked', ({ id }) => {
    const evt = state.events.find((e) => e.id === id);
    if (evt) { evt.ack = true; renderTimeline(); }
  });

  socket.on('events_acked_all', () => {
    state.events.forEach((e) => { e.ack = true; });
    clearAllAlarms();
    renderTimeline();
  });

  socket.on('health', renderHealth);

  // ==========================================================================
  // Sesión
  // ==========================================================================

  $('btn-logout').onclick = async () => {
    if (state.call) endCall();
    try { await fetch('/api/logout', { method: 'POST' }); } catch (_) { }
    location.replace('/login/');
  };

  // Cortar la llamada limpio si se cierra la pestaña
  window.addEventListener('beforeunload', () => { if (state.call) socket.emit('end_call'); });

  // Atajo: ESC cuelga
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && state.call) endCall();
  });

})();
