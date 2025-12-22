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

    // Mini Buttons (Card specific)
    ['admin', 'tenis'].forEach(id => {
        setBtnMiniState(`btn-mute-${id}`, mediaState.audio);
        setBtnMiniState(`btn-cam-${id}`, mediaState.video);

        // Logo Overlay Logic
        const logo = document.getElementById(`logo-${id}`);
        if (logo) {
            if (!mediaState.video) logo.classList.remove('hidden');
            else logo.classList.add('hidden');
        }
    });
}

function setBtnState(btnId, isActive) {
    const btn = document.getElementById(btnId);
    if (!btn) return;

    if (isActive) {
        btn.classList.remove('off');
        btn.classList.add('active');
    } else {
        btn.classList.add('off');
        btn.classList.remove('active');
    }
}

function setBtnMiniState(btnId, isActive) {
    const btn = document.getElementById(btnId);
    if (!btn) return;

    if (isActive) {
        btn.classList.remove('off');
        btn.classList.add('active');
    } else {
        btn.classList.add('off');
        btn.classList.remove('active');
    }
}

// BIND EVENTS (Globals)
document.getElementById('btn-global-mute').onclick = toggleMute;
document.getElementById('btn-global-cam').onclick = toggleCam;

// BIND EVENTS (Card Specific)
['admin', 'tenis'].forEach(id => {
    const muteBtn = document.getElementById(`btn-mute-${id}`);
    if (muteBtn) muteBtn.onclick = toggleMute;
    const camBtn = document.getElementById(`btn-cam-${id}`);
    if (camBtn) camBtn.onclick = toggleCam;
    const endCallBtn = document.getElementById(`btn-end-call-${id}`);
    if (endCallBtn) endCallBtn.onclick = () => window.endCall();
});


// OPEN CALL (IN-CARD UI)
window.selectKiosk = (id) => {
    activeCallTarget = id;

    // Hide RTSP, Show Call UI
    document.getElementById(`wrapper-${id}`).style.display = 'none'; // Optional: hide canvas?
    // Actually, keep wrapper but maybe hidden? 
    // Plan: Overlay Call UI on top. 
    // Wrapper has canvas.
    // Call UI is absolute.
    // So just showing Call UI covers it.

    document.getElementById(`call-ui-${id}`).classList.remove('hidden');
    document.getElementById(`footer-${id}`).style.display = 'none'; // Hide idle user controls

    startCall(id);
};

// TEST ALARM
window.testAlarm = (id) => {
    socket.emit('test_alarm', id);
};

// END CALL ACTION
window.endCall = () => {
    const id = activeCallTarget;
    if (!id) return;

    activeCallTarget = null;
    const remoteAudio = document.getElementById(`remoteAudio-${id}`);

    if (peerConnection) {
        socket.emit('end_call', 'sentinel-room');
        peerConnection.close();
        peerConnection = null;
    }

    if (localStream) {
        localStream.getTracks().forEach(track => track.stop());
        localStream = null;
    }

    if (remoteAudio) remoteAudio.srcObject = null;

    // Reset UI
    document.getElementById(`call-ui-${id}`).classList.add('hidden');
    document.getElementById(`footer-${id}`).style.display = 'flex'; // Restore footer
    document.getElementById(`wrapper-${id}`).style.display = 'flex'; // Restore RTSP

    // Clear Local Video Src
    const localVidRef = document.getElementById(`localVideo-${id}`);
    if (localVidRef) localVidRef.srcObject = null;
}

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

        // Targeted Local Video (In PIP)
        const localVid = document.getElementById(`localVideo-${targetId}`);
        if (localVid) localVid.srcObject = localStream;

        localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));
    } catch (err) {
        console.error("Error media", err);
        alert("No se pudo acceder a Cámara/Micrófono");
        return;
    }

    // Targeted Remote Audio/Video
    const remoteAudio = document.getElementById(`remoteAudio-${targetId}`);
    const remoteVideo = document.getElementById(`remoteVideo-${targetId}`);

    peerConnection.ontrack = (event) => {
        // Handle Video Track
        if (event.track.kind === 'video') {
            if (remoteVideo.srcObject !== event.streams[0]) {
                remoteVideo.srcObject = event.streams[0];
            }
        }
        // Handle Audio Track
        if (event.track.kind === 'audio') {
            if (remoteAudio.srcObject !== event.streams[0]) {
                remoteAudio.srcObject = event.streams[0];
            }
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



