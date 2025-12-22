const socket = io();

// UI Elements
const btnToggle = document.getElementById('btn-toggle-call');
const btnMute = document.getElementById('btn-mute');
const btnCam = document.getElementById('btn-cam');
const btnText = document.querySelector('.btn-text');
const localVideo = document.getElementById('localVideo');
const remoteAudio = document.getElementById('remoteAudio');
// ALARM SYSTEM
const alarmAudio = document.getElementById('alarmAudio');
let isAlarmActive = false;

document.getElementById('btn-test-alarm').onclick = () => {
    socket.emit('test_alarm');
};

socket.on('alarm_trigger', (data) => {
    console.log("ALARM RECEIVED:", data);

    // 1. Play Sound
    if (data.sound) {
        alarmAudio.currentTime = 0;
        alarmAudio.play().catch(e => console.warn("Audio play blocked:", e));
    }

    // 2. Visual Effect (Persistent until clicked)
    const rtspPanel = document.querySelector('.rtsp-panel');
    rtspPanel.classList.add('alarm-active');
    isAlarmActive = true;

    // 3. Clear on Click
    rtspPanel.onclick = () => {
        if (isAlarmActive) {
            clearAlarmState();
        }
    };
});

function clearAlarmState() {
    const rtspPanel = document.querySelector('.rtsp-panel');
    rtspPanel.classList.remove('alarm-active');
    alarmAudio.pause();
    alarmAudio.currentTime = 0;
    isAlarmActive = false;
    rtspPanel.onclick = null; // Remove handler
}
const kioskStatus = document.getElementById('kiosk-status');
const canvas = document.getElementById('video-canvas');
const rtspStatus = document.getElementById('rtsp-status');

const rtcConfig = {
    iceServers: [
        { urls: 'stun:stun.l.google.com:19302' }
    ]
};

let peerConnection;
let localStream;
let isCallActive = false;
const ROOM_ID = 'sentinel-room';
let player = null;

// Init Socket
socket.emit('register', 'backoffice');

// Init JSMPEG Player
function initPlayer() {
    const url = `ws://${window.location.hostname}:9999`;
    rtspStatus.textContent = "Conectando al video...";

    if (player) {
        player.destroy();
    }

    player = new JSMpeg.Player(url, {
        canvas: canvas,
        autoplay: true,
        audio: false, // Video only from RTSP usually, or check source
        onSourceEstablished: () => {
            rtspStatus.style.display = 'none';
        },
        onSourceCompleted: () => {
            rtspStatus.textContent = "Desconectado";
            rtspStatus.style.display = 'block';
        }
    });
}

// Start player on load
initPlayer();

// Config Button
document.getElementById('btn-config-rtsp').onclick = () => {
    alert("Para cambiar la URL del RTSP, edita la variable GLOBAL en 'src/stream.js' en el servidor y reinicia el servicio.");
};

socket.on('disconnect', () => {
    kioskStatus.className = 'status-badge offline';
    kioskStatus.textContent = 'OFFLINE';
});

// Status Update from Server
socket.on('kiosk_status', (status) => {
    if (status.online) {
        kioskStatus.className = 'status-badge online';
        kioskStatus.textContent = 'ONLINE';
    } else {
        kioskStatus.className = 'status-badge offline';
        kioskStatus.textContent = 'OFFLINE';
    }
});


// Signaling
socket.on('answer', async (answer) => {
    if (peerConnection) {
        await peerConnection.setRemoteDescription(new RTCSessionDescription(answer));
    }
});

socket.on('candidate', async (candidate) => {
    if (peerConnection) {
        try {
            await peerConnection.addIceCandidate(new RTCIceCandidate(candidate));
        } catch (e) { console.error(e); }
    }
});

// ------------------------------------
// Handlers
// ------------------------------------

btnToggle.onclick = () => {
    if (!isCallActive) {
        startCall();
    } else {
        endCall();
    }
};

btnMute.onclick = toggleMute;
btnCam.onclick = toggleCam;


// ------------------------------------
// Logic
// ------------------------------------

// Initial State
let mediaState = {
    audio: true,
    video: true
};

// Initial Sync UI
updateMediaButtons();

async function startCall() {
    if (isAlarmActive) clearAlarmState(); // Stop alarm if calling
    isCallActive = true;
    updateUIState(true);
    document.querySelector('.idle-placeholder').classList.add('hidden'); // Hide idle screen

    socket.emit('start_call', ROOM_ID);

    peerConnection = new RTCPeerConnection(rtcConfig);

    try {
        localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });

        // Apply Initial State
        localStream.getAudioTracks()[0].enabled = mediaState.audio;
        localStream.getVideoTracks()[0].enabled = mediaState.video;

        localVideo.srcObject = localStream;
        localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));

        // Update UI (Avatar local check)
        updateLocalAvatar(mediaState.video);

        // Sync with Peer immediately
        socket.emit('media_state_change', { room: ROOM_ID, type: 'audio', enabled: mediaState.audio });
        socket.emit('media_state_change', { room: ROOM_ID, type: 'video', enabled: mediaState.video });

    } catch (err) {
        console.error("Error media", err);
        alert("No se pudo acceder a Cámara/Micrófono");
        endCall();
        return;
    }

    peerConnection.ontrack = (event) => {
        if (remoteAudio.srcObject !== event.streams[0]) {
            remoteAudio.srcObject = event.streams[0];
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
}

function endCall() {
    isCallActive = false;
    updateUIState(false);
    document.querySelector('.idle-placeholder').classList.remove('hidden'); // Show idle screen

    socket.emit('end_call', ROOM_ID);

    if (localStream) {
        localStream.getTracks().forEach(track => track.stop());
        localStream = null;
    }
    if (peerConnection) {
        peerConnection.close();
        peerConnection = null;
    }
    localVideo.srcObject = null;
    remoteAudio.srcObject = null;

    // resetMediaButtons(); // We do NOT reset state, user setting persists for comfort
}

// ------------------------------------
// UI State & Media Toggles
// ------------------------------------

function updateUIState(calling) {
    if (calling) {
        btnToggle.className = 'btn-toggle active';
        btnText.textContent = 'FINALIZAR';
    } else {
        btnToggle.className = 'btn-toggle idle';
        btnText.textContent = 'INICIAR LLAMADA';
    }
}

function toggleMute() {
    mediaState.audio = !mediaState.audio;

    // If active call, update track
    if (localStream) {
        const track = localStream.getAudioTracks()[0];
        if (track) track.enabled = mediaState.audio;
        socket.emit('media_state_change', { room: ROOM_ID, type: 'audio', enabled: mediaState.audio });
    }

    updateMediaButtons();
}

function toggleCam() {
    mediaState.video = !mediaState.video;

    // If active call, update track
    if (localStream) {
        const track = localStream.getVideoTracks()[0];
        if (track) track.enabled = mediaState.video;

        updateLocalAvatar(mediaState.video);
        socket.emit('media_state_change', { room: ROOM_ID, type: 'video', enabled: mediaState.video });
    }

    updateMediaButtons();
}

function updateLocalAvatar(isEnabled) {
    const videoWrapper = document.querySelector('.video-wrapper');
    if (isEnabled) {
        videoWrapper.classList.remove('avatar-mode');
    } else {
        videoWrapper.classList.add('avatar-mode');
    }
}

function updateMediaButtons() {
    // Buttons reflect the INTENDED state (mediaState), not just the track state

    // Mute
    if (mediaState.audio) {
        btnMute.className = 'btn-icon active'; // Normal/Active
        btnMute.title = "Mutear Micrófono";
    } else {
        btnMute.className = 'btn-icon off'; // Red/Off
        btnMute.title = "Activar Micrófono";
    }

    // Cam
    if (mediaState.video) {
        btnCam.className = 'btn-icon active';
        btnCam.title = "Apagar Cámara";
    } else {
        btnCam.className = 'btn-icon off';
        btnCam.title = "Encender Cámara";
    }
}

function resetMediaButtons() {
    // No longer used in endCall to preserve preference
    mediaState = { audio: true, video: true };
    updateMediaButtons();
}
