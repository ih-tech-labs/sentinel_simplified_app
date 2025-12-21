const socket = io();

// UI Elements
const btnToggle = document.getElementById('btn-toggle-call');
const btnMute = document.getElementById('btn-mute');
const btnCam = document.getElementById('btn-cam');
const btnToggle = document.getElementById('btn-toggle-call');
const btnMute = document.getElementById('btn-mute');
const btnCam = document.getElementById('btn-cam');
const btnText = document.querySelector('.btn-text');
const localVideo = document.getElementById('localVideo');
const remoteAudio = document.getElementById('remoteAudio');
const kioskStatus = document.getElementById('kiosk-status');
// RTSP Elements
const rtspCanvas = document.getElementById('rtsp-canvas');
const btnConfigRtsp = document.getElementById('btn-config-rtsp');
const configModal = document.getElementById('config-modal');
const rtspUrlInput = document.getElementById('rtsp-url-input');
const btnSaveConfig = document.getElementById('btn-save-config');
const btnCancelConfig = document.getElementById('btn-cancel-config');

let jsmpegPlayer = null;
const RTSP_WS_PORT = 9999;

// RTC Config
const rtcConfig = {
    iceServers: [
        { urls: 'stun:stun.l.google.com:19302' }
    ]
};

let peerConnection;
let localStream;
let isCallActive = false;
const ROOM_ID = 'sentinel-room';

// Init
socket.emit('register', 'backoffice');
socket.emit('get_rtsp_config'); // Request current RTSP URL

// ------------------------------------
// RTSP / Socket Handlers
// ------------------------------------

socket.on('rtsp_config', (url) => {
    if (url) {
        initPlayer(); // Player connects to fixed WS port, URL is handled by server proxy
        rtspUrlInput.value = url;
    }
});

socket.on('rtsp_updated', (url) => {
    console.log("RTSP URL Updated, reloading player...");
    if (jsmpegPlayer) {
        jsmpegPlayer.destroy();
        jsmpegPlayer = null;
    }
    // Give server a moment to restart stream
    setTimeout(initPlayer, 2000);
    rtspUrlInput.value = url;
});

function initPlayer() {
    if (jsmpegPlayer) return;
    const wsUrl = `ws://${window.location.hostname}:${RTSP_WS_PORT}`;
    console.log("Connecting JSMpeg to " + wsUrl);
    jsmpegPlayer = new JSMpeg.Player(wsUrl, {
        canvas: rtspCanvas,
        autoplay: true,
        audio: false // We use RTSP only for video usually
    });
}

// Modal Handlers
btnConfigRtsp.onclick = () => {
    configModal.classList.remove('hidden');
};

btnCancelConfig.onclick = () => {
    configModal.classList.add('hidden');
};

btnSaveConfig.onclick = () => {
    const newUrl = rtspUrlInput.value.trim();
    if (newUrl) {
        socket.emit('update_rtsp_url', newUrl);
        configModal.classList.add('hidden');
    }
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

async function startCall() {
    isCallActive = true;
    updateUIState(true);

    socket.emit('start_call', ROOM_ID);

    peerConnection = new RTCPeerConnection(rtcConfig);

    try {
        localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
        // Mute local playback to avoid echo
        localVideo.srcObject = localStream;

        localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));

        btnMute.disabled = false;
        btnCam.disabled = false;
        updateMediaButtons();

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

    btnMute.disabled = true;
    btnCam.disabled = true;
    resetMediaButtons();
}

// ------------------------------------
// UI State
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
    if (localStream) {
        const audioTrack = localStream.getAudioTracks()[0];
        audioTrack.enabled = !audioTrack.enabled;
        updateMediaButtons();
        // Notify Peer
        socket.emit('media_state_change', { room: ROOM_ID, type: 'audio', enabled: audioTrack.enabled });
    }
}

function toggleCam() {
    if (localStream) {
        const videoTrack = localStream.getVideoTracks()[0];
        videoTrack.enabled = !videoTrack.enabled;
        updateMediaButtons();

        // Update Local Avatar
        updateLocalAvatar(videoTrack.enabled);

        // Notify Peer
        socket.emit('media_state_change', { room: ROOM_ID, type: 'video', enabled: videoTrack.enabled });
    }
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
    if (!localStream) return;
    const audioTrack = localStream.getAudioTracks()[0];
    const videoTrack = localStream.getVideoTracks()[0];

    // Mute
    if (audioTrack && audioTrack.enabled) {
        btnMute.className = 'btn-icon active';
        btnMute.title = "Mutear Micrófono";
    } else {
        btnMute.className = 'btn-icon off';
        btnMute.title = "Activar Micrófono";
    }

    // Cam
    if (videoTrack && videoTrack.enabled) {
        btnCam.className = 'btn-icon active';
        btnCam.title = "Apagar Cámara";
    } else {
        btnCam.className = 'btn-icon off';
        btnCam.title = "Encender Cámara";
    }
}

function resetMediaButtons() {
    btnMute.className = 'btn-icon';
    btnCam.className = 'btn-icon';
}
