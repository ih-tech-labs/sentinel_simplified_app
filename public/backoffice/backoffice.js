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
        btnMute.textContent = audioTrack.enabled ? '🎤 Mute Mic' : '🎤 Unmute';
        btnMute.style.background = audioTrack.enabled ? '#444' : '#f44336';
    }
};

btnCam.onclick = () => {
    if (localStream) {
        const videoTrack = localStream.getVideoTracks()[0];
        videoTrack.enabled = !videoTrack.enabled;
        btnCam.textContent = videoTrack.enabled ? '📷 Camera Off' : '📷 Camera On';
        btnCam.style.background = videoTrack.enabled ? '#444' : '#f44336';
    }
};

async function startCall() {
    btnCall.disabled = true;
    btnHangup.disabled = false;
    btnMute.disabled = false;
    btnCam.disabled = false;

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
    btnCall.disabled = false;
    btnHangup.disabled = true;
    btnMute.disabled = true;
    btnCam.disabled = true;

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
