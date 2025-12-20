const socket = io();

// UI Elements
const btnToggle = document.getElementById('btn-toggle-call');
const btnMute = document.getElementById('btn-mute');
const btnCam = document.getElementById('btn-cam');
const toggleText = document.getElementById('toggle-text');
const localVideo = document.getElementById('localVideo');
const remoteAudio = document.getElementById('remoteAudio');
const kioskStatus = document.getElementById('kiosk-status');
const visualizer = document.getElementById('audio-visualizer');

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
socket.emit('join', ROOM_ID);

// ------------------------------------
// Socket Listeners
// ------------------------------------
socket.on('connect', () => {
    // console.log("Connected");
});

socket.on('disconnect', () => {
    kioskStatus.className = 'offline';
    kioskStatus.textContent = 'OFFLINE';
});

// Since we don't have a specific "Kiosk Joined" event in existing server, 
// we assume Kiosk is there if user initiates. 
// A robust version would listen for 'user_joined' but for now we follow existing logic.

// WebRTC Signaling
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
// Button Handlers
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
// Call Logic
// ------------------------------------

async function startCall() {
    isCallActive = true;
    updateUIState(true);

    // Notify Kiosk
    socket.emit('start_call', ROOM_ID);

    // Setup WebRTC
    peerConnection = new RTCPeerConnection(rtcConfig);

    // Get Media
    try {
        localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
        localVideo.srcObject = localStream;
        localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));

        // Init Secondary Buttons State
        btnMute.disabled = false;
        btnCam.disabled = false;
        updateMediaButtons();

    } catch (err) {
        console.error("Error accessing media:", err);
        alert("Error: No se pudo acceder a Cámara/Micrófono.");
        endCall(); // Revert
        return;
    }

    // Handle Incoming Audio
    peerConnection.ontrack = (event) => {
        if (remoteAudio.srcObject !== event.streams[0]) {
            remoteAudio.srcObject = event.streams[0];
            // Activate Visualizer Animation class
            visualizer.classList.add('audio-active');
        }
    };

    // ICE
    peerConnection.onicecandidate = (event) => {
        if (event.candidate) {
            socket.emit('candidate', { room: ROOM_ID, candidate: event.candidate });
        }
    };

    // Create Offer
    const offer = await peerConnection.createOffer();
    await peerConnection.setLocalDescription(offer);
    socket.emit('offer', { room: ROOM_ID, offer: offer });
}

function endCall() {
    isCallActive = false;
    updateUIState(false);

    socket.emit('end_call', ROOM_ID);

    // Stop Media
    if (localStream) {
        localStream.getTracks().forEach(track => track.stop());
        localStream = null;
    }

    // Close Peer
    if (peerConnection) {
        peerConnection.close();
        peerConnection = null;
    }

    localVideo.srcObject = null;
    remoteAudio.srcObject = null;

    // Reset Buttons
    btnMute.disabled = true;
    btnCam.disabled = true;
    visualizer.classList.remove('audio-active');

    resetMediaButtons();
}

// ------------------------------------
// UI Helpers
// ------------------------------------

function updateUIState(calling) {
    if (calling) {
        document.body.classList.add('on-call');

        // Button becomes END CALL
        btnToggle.className = 'btn-main active';
        toggleText.textContent = 'FINALIZAR';

    } else {
        document.body.classList.remove('on-call');

        // Button becomes START
        btnToggle.className = 'btn-main idle';
        toggleText.textContent = 'INICIAR';
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

    // Mute Button
    if (audioTrack && audioTrack.enabled) {
        btnMute.className = 'btn-sec on'; // Active/On
    } else {
        btnMute.className = 'btn-sec off'; // Muted
    }

    // Cam Button
    if (videoTrack && videoTrack.enabled) {
        btnCam.className = 'btn-sec on';
    } else {
        btnCam.className = 'btn-sec off';
    }
}

function resetMediaButtons() {
    btnMute.className = 'btn-sec';
    btnCam.className = 'btn-sec';
}
