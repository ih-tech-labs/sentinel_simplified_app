const socket = io();

// UI Elements
const btnToggle = document.getElementById('btn-toggle-call');
const btnMute = document.getElementById('btn-mute');
const btnCam = document.getElementById('btn-cam');
const btnText = document.querySelector('.btn-text');
const localVideo = document.getElementById('localVideo');
const remoteAudio = document.getElementById('remoteAudio');
const kioskStatus = document.getElementById('kiosk-status');
const audioPanel = document.querySelector('.audio-panel');

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
        audioPanel.classList.add('on-call');
    } else {
        btnToggle.className = 'btn-toggle idle';
        btnText.textContent = 'INICIAR LLAMADA';
        audioPanel.classList.remove('on-call');
    }
}

function toggleMute() {
    if (localStream) {
        const audioTrack = localStream.getAudioTracks()[0];
        audioTrack.enabled = !audioTrack.enabled;
        updateMediaButtons();
    }
}

function toggleCam() {
    if (localStream) {
        const videoTrack = localStream.getVideoTracks()[0];
        videoTrack.enabled = !videoTrack.enabled;
        updateMediaButtons();
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
