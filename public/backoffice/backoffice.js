const socket = io();

const btnCall = document.getElementById('btn-call');
const btnHangup = document.getElementById('btn-hangup');
const btnMute = document.getElementById('btn-mute');
const btnCam = document.getElementById('btn-cam');
const localVideo = document.getElementById('localVideo');
const remoteAudio = document.getElementById('remoteAudio');
const kioskStatus = document.getElementById('kiosk-status');

const rtcConfig = {
    iceServers: [
        { urls: 'stun:stun.l.google.com:19302' }
    ]
};

let peerConnection;
let localStream;
const ROOM_ID = 'sentinel-room';

socket.emit('join', ROOM_ID);

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

// Controls
btnCall.onclick = startCall;
btnHangup.onclick = endCall;

btnMute.onclick = () => {
    if (localStream) {
        const audioTrack = localStream.getAudioTracks()[0];
        audioTrack.enabled = !audioTrack.enabled;

        // Update UI
        if (audioTrack.enabled) {
            btnMute.classList.remove('muted');
            btnMute.innerHTML = '<i class="ph-fill ph-microphone"></i>';
        } else {
            btnMute.classList.add('muted');
            btnMute.innerHTML = '<i class="ph-fill ph-microphone-slash"></i>';
        }
    }
};

btnCam.onclick = () => {
    if (localStream) {
        const videoTrack = localStream.getVideoTracks()[0];
        videoTrack.enabled = !videoTrack.enabled;

        // Update UI
        if (videoTrack.enabled) {
            btnCam.classList.remove('muted'); // Reuse muted style for red state if needed, or just default
            btnCam.innerHTML = '<i class="ph-fill ph-video-camera"></i>';
            btnCam.style.color = ''; // reset
        } else {
            btnCam.innerHTML = '<i class="ph-fill ph-video-camera-slash"></i>';
            btnCam.style.color = '#ef5350';
        }
    }
};

async function startCall() {
    // Swap buttons
    btnCall.style.display = 'none';
    btnHangup.style.display = 'flex';
    btnHangup.disabled = false;

    // Notify Kiosk
    socket.emit('start_call', ROOM_ID);

    // Setup WebRTC
    peerConnection = new RTCPeerConnection(rtcConfig);

    // Get Media (Audio + Video)
    try {
        localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
        localVideo.srcObject = localStream;
        localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));
    } catch (err) {
        console.error("Error accessing media:", err);
        alert("Error accessing Camera/Microphone");
        endCall();
        return;
    }

    // Handle Incoming Audio
    peerConnection.ontrack = (event) => {
        if (remoteAudio.srcObject !== event.streams[0]) {
            remoteAudio.srcObject = event.streams[0];
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
    // UI Reset
    btnCall.style.display = 'flex';
    btnHangup.style.display = 'none';
    btnHangup.disabled = true;

    socket.emit('end_call', ROOM_ID);

    if (peerConnection) {
        peerConnection.close();
        peerConnection = null;
    }
    if (localStream) {
        localStream.getTracks().forEach(track => track.stop());
        localStream = null;
    }
    localVideo.srcObject = null;
    remoteAudio.srcObject = null;
}
