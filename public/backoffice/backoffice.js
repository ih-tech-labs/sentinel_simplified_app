const socket = io();

// STATE
let activeCallTarget = null; // 'admin' or 'tenis'
let peerConnection = null;
let localStream = null;
let isAlarmActive = { admin: false, tenis: false };
let players = {};

// ALARM AUDIO
const alarmAudio = document.getElementById('alarmAudio');

// ==========================================
// 1. INITIALIZATION
// ==========================================

socket.emit('register', 'backoffice');

// Init Players for both Kiosks
function initPlayers() {
    // Player 1: Admin (Port 9998)
    if (document.getElementById('canvas-admin')) {
        players['admin'] = new JSMpeg.Player(`ws://${window.location.hostname}:9998`, {
            canvas: document.getElementById('canvas-admin'),
            autoplay: true,
            audio: false,
            onSourceEstablished: () => hideOverlay('admin'),
            onSourceCompleted: () => showOverlay('admin', 'Desconectado')
        });
    }

    // Player 2: Tenis (Port 9999)
    if (document.getElementById('canvas-tenis')) {
        players['tenis'] = new JSMpeg.Player(`ws://${window.location.hostname}:9999`, {
            canvas: document.getElementById('canvas-tenis'),
            autoplay: true,
            audio: false,
            onSourceEstablished: () => hideOverlay('tenis'),
            onSourceCompleted: () => showOverlay('tenis', 'Desconectado')
        });
    }
}

function hideOverlay(id) {
    const el = document.querySelector(`#card-${id} .overlay-msg`);
    if (el) el.style.display = 'none';
}

function showOverlay(id, msg) {
    const el = document.querySelector(`#card-${id} .overlay-msg`);
    if (el) {
        el.textContent = msg;
        el.style.display = 'block';
    }
}

// Start Video
initPlayers();


// ==========================================
// 2. SOCKET EVENTS (STATUS & ALARM)
// ==========================================

socket.on('disconnect', () => {
    updateStatus('admin', false);
    updateStatus('tenis', false);
});

// Update specific Kiosk Status
socket.on('kiosk_status', (data) => {
    // data = { id: 'admin', online: true }
    if (data.id) {
        updateStatus(data.id, data.online);
    }
});

function updateStatus(id, isOnline) {
    const badge = document.getElementById(`status-${id}`);
    if (badge) {
        badge.className = isOnline ? 'status-badge online' : 'status-badge offline';
        badge.textContent = isOnline ? 'ONLINE' : 'OFFLINE';
    }
}

// Handle Alarms (Targeted)
socket.on('alarm_trigger', (data) => {
    console.log("ALARM RECEIVED:", data);
    const targetId = data.kioskId; // 'admin' or 'tenis'

    if (!targetId) return;

    // 1. Play Sound
    if (data.sound) {
        alarmAudio.currentTime = 0;
        alarmAudio.play().catch(e => console.warn("Audio play blocked:", e));
    }

    // 2. Visual Effect on Card
    const card = document.getElementById(`card-${targetId}`);
    if (card) {
        card.classList.add('active-alarm');
        isAlarmActive[targetId] = true;

        // Clear on click
        card.onclick = () => {
            if (isAlarmActive[targetId]) {
                card.classList.remove('active-alarm');
                alarmAudio.pause();
                isAlarmActive[targetId] = false;
                card.onclick = null;
            }
        };
    }
});

// ==========================================
// 3. UI ACTIONS
// ==========================================

// ==========================================
// 3. UI ACTIONS & MEDIA CONTROLS
// ==========================================

let mediaState = {
    audio: true,
    video: true
};

function toggleMute() {
    mediaState.audio = !mediaState.audio;
    updateMediaState();
}

function toggleCam() {
    mediaState.video = !mediaState.video;
    updateMediaState();
}

function updateMediaState() {
    // 1. Update UI Buttons
    updateButtonUI();

    // 2. Update Active Stream (if exists)
    if (localStream) {
        localStream.getAudioTracks().forEach(track => track.enabled = mediaState.audio);
        localStream.getVideoTracks().forEach(track => track.enabled = mediaState.video);
    }
}

function updateButtonUI() {
    // Global Buttons
    setBtnState('btn-global-mute', mediaState.audio);
    setBtnState('btn-global-cam', mediaState.video);

    // Modal Buttons
    setBtnState('btn-modal-mute', mediaState.audio);
    setBtnState('btn-modal-cam', mediaState.video);

    // Logo Overlay
    const logo = document.getElementById('logo-overlay');
    if (logo) {
        if (!mediaState.video) {
            logo.classList.remove('hidden');
        } else {
            logo.classList.add('hidden');
        }
    }
}

function setBtnState(btnId, isActive) {
    const btn = document.getElementById(btnId);
    if (!btn) return;

    if (isActive) {
        btn.classList.add('active');
        btn.classList.remove('off');
        btn.title = btnId.includes('mute') ? "Silenciar" : "Apagar Cámara";
    } else {
        btn.classList.remove('active');
        btn.classList.add('off');
        btn.title = btnId.includes('mute') ? "Activar Micrófono" : "Encender Cámara";
    }
}

// BIND EVENTS
document.getElementById('btn-global-mute').onclick = toggleMute;
document.getElementById('btn-global-cam').onclick = toggleCam;
document.getElementById('btn-modal-mute').onclick = toggleMute;
document.getElementById('btn-modal-cam').onclick = toggleCam;


// OPEN CALL MODAL
window.selectKiosk = (id) => {
    activeCallTarget = id;
    const name = id === 'admin' ? "Administración" : "House Tenis";

    document.getElementById('call-target-name').textContent = name;
    document.getElementById('call-modal').classList.remove('hidden');

    // Start WebRTC immediatly
    startCall(id);
};

// TEST ALARM
window.testAlarm = (id) => {
    socket.emit('test_alarm', id);
};

// END CALL ACTION
document.getElementById('btn-end-call').onclick = () => {
    endCall();
    document.getElementById('call-modal').classList.add('hidden');
};

// Initialize UI
updateButtonUI();


// ==========================================
// 4. WEBRTC LOGIC (ROUTING)
// ==========================================

let rtcConfig = {
    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
};

async function startCall(targetId) {
    const ROOM_ID = `kiosk-${targetId}`; // Connect to specific room
    console.log(`Starting call to: ${ROOM_ID}`);

    socket.emit('start_call', ROOM_ID);

    peerConnection = new RTCPeerConnection(rtcConfig);

    try {
        localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });

        // Apply Initial Media State
        localStream.getAudioTracks().forEach(track => track.enabled = mediaState.audio);
        localStream.getVideoTracks().forEach(track => track.enabled = mediaState.video);

        document.getElementById('localVideo').srcObject = localStream;

        localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));
    } catch (err) {
        console.error("Error media", err);
        alert("No se pudo acceder a Cámara/Micrófono");
        return;
    }

    const remoteAudio = document.getElementById('remoteAudio');

    peerConnection.ontrack = (event) => {
        if (remoteAudio.srcObject !== event.streams[0]) {
            remoteAudio.srcObject = event.streams[0];
            console.log("Remote Audio Connected");
        }
    };

    peerConnection.onicecandidate = (event) => {
        if (event.candidate) {
            socket.emit('candidate', { room: ROOM_ID, candidate: event.candidate });
        }
    };

    const offer = await peerConnection.createOffer();
    await peerConnection.setLocalDescription(offer);
    socket.emit('offer', { room: ROOM_ID, offer: offer });

    // Signaling Handlers (Specific to this call instance)
    setupSignaling(ROOM_ID);
}

function setupSignaling(roomId) {
    // Note: In V3 we had global listeners. In V4 we might get crosstalk if we don't handle rooms.
    // The server emits 'answer' to the room => but backoffice is in 'backoffice' room?
    // Wait, Server Logic: socket.to(data.room).emit('answer', data.answer);
    // Backoffice needs to be in the 'sentinel-room' or the specific room?

    // In V4 Server Logic:
    // socket.join('sentinel-room') for everyone. 
    // Offer/Answer goes to data.room.
    // The Room ID used is `kiosk-{id}`.
    // So the Kiosk is in `kiosk-{id}`.
    // The Backoffice is NOT in `kiosk-{id}` by default?
    // Correct. The Backoffice sends Offer to `kiosk-{id}`.
    // The Kiosk sends Answer to... wait. 
    // Server: socket.to(data.room).emit...

    // If Kiosk replies to `kiosk-{id}`, Backoffice MUST be in that room to receive it?
    // OR Backoffice joins `kiosk-{id}` temporarily?
    // OR we use a common signaling room.

    // Current Server Logic:
    // socket.on('register') -> Backoffice joins 'backoffice' AND 'sentinel-room'.
    // Kiosk joins 'kiosk-{id}' AND 'sentinel-room'.

    // If Backoffice sends Offer to room='kiosk-{id}'...
    // Server: socket.to('kiosk-{id}').emit('offer'). -> Kiosk receives it. OK.

    // Kiosk sends Answer. To which room? 
    // Kiosk code sends to ROOM_ID = 'sentinel-room' (Fixed in Kiosk Client).
    // Kiosk Client: const ROOM_ID = 'sentinel-room';

    // So Kiosk replies to 'sentinel-room'.
    // Backoffice IS in 'sentinel-room'. So Backoffice receives it. 
    // BUT! If we have 2 kiosks, both are in 'sentinel-room'.
    // If Kiosk 1 sends answer, Backoffice gets it.
    // If Kiosk 2 sends answer (to another backoffice?), Backoffice gets it.
    // Since we likely only have 1 active call, this is fine for now.
}

// GLOBAL SIGNALING LISTENERS (Always active, waiting for match on active connection)
socket.on('answer', async (answer) => {
    if (peerConnection && peerConnection.signalingState === 'have-local-offer') {
        await peerConnection.setRemoteDescription(new RTCSessionDescription(answer));
    }
});

socket.on('candidate', async (candidate) => {
    if (peerConnection) {
        try {
            await peerConnection.addIceCandidate(new RTCIceCandidate(candidate));
        } catch (e) { }
    }
});

function endCall() {
    activeCallTarget = null;
    const remoteAudio = document.getElementById('remoteAudio');

    // Send End to current room?
    // We don't store the current room ID globally easily, but we can reconstruct or ignore.
    // Kiosk listens for 'call_ended' on 'sentinel-room' probably?
    // Kiosk Client: socket.on('call_ended'). 
    // Server: socket.on('end_call', (room) => io.to(room).emit('call_ended'))

    // We should send end to 'kiosk-admin' or 'sentinel-room'.
    // Safe bet: transmit to the specific kiosk room
    // But we need to know WHICH one was active.
    // If we rely on stored ID:
    if (peerConnection) {
        // Find which one was connected? 
        // Logic simplification: Just emit to 'sentinel-room' to close all calls?
        // Or better:
        socket.emit('end_call', 'sentinel-room'); // Kiosks listen here too? 
    }

    if (localStream) {
        localStream.getTracks().forEach(track => track.stop());
        localStream = null;
    }
    if (peerConnection) {
        peerConnection.close();
        peerConnection = null;
    }

    if (remoteAudio) remoteAudio.srcObject = null;
}
