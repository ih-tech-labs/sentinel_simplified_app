const socket = io();

// UI Elements
const idleUI = document.getElementById('idle-ui');
const callUI = document.getElementById('call-ui');
const remoteVideo = document.getElementById('remoteVideo');
const bgVideo = document.getElementById('bgVideo');
const clockDisplay = document.getElementById('clock-display');
const dateDisplay = document.getElementById('date-display');

// WebRTC Configuration
const rtcConfig = {
    iceServers: [
        { urls: 'stun:stun.l.google.com:19302' }
    ]
};

let peerConnection;
let localStream;

// --- Clock Logic ---
function updateClock() {
    const now = new Date();
    // Format: HH:MM
    const timeString = now.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' });
    clockDisplay.textContent = timeString;

    // Format: Dayname, DD of montname
    const options = { weekday: 'long', day: 'numeric', month: 'long' };
    const dateString = now.toLocaleDateString('es-AR', options);
    // Capitalize first letter
    dateDisplay.textContent = dateString.charAt(0).toUpperCase() + dateString.slice(1);
}
setInterval(updateClock, 1000);
updateClock();

// --- Weather Logic (OpenMeteo) ---
async function updateWeather() {
    try {
        // Buenos Aires Lat/Long
        const lat = -34.6037;
        const lon = -58.3816;
        const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=America%2FSao_Paulo`;

        const response = await fetch(url);
        const data = await response.json();

        const currentTemp = Math.round(data.current.temperature_2m);
        const code = data.current.weather_code;
        const max = Math.round(data.daily.temperature_2m_max[0]);
        const min = Math.round(data.daily.temperature_2m_min[0]);

        // Basic WMO code mapping
        let icon = '☀️';
        let desc = 'Despejado';

        if (code > 0 && code <= 3) { icon = '⛅'; desc = 'Parcialmente Nublado'; }
        else if (code > 40 && code < 60) { icon = '🌫️'; desc = 'Niebla'; }
        else if (code >= 60 && code < 80) { icon = '🌧️'; desc = 'Lluvioso'; }
        else if (code >= 80) { icon = '⛈️'; desc = 'Tormenta'; }

        document.querySelector('.temp').textContent = `${currentTemp}°`;
        document.querySelector('.desc').textContent = desc;
        document.querySelector('.weather-icon').textContent = icon;
        document.querySelector('.range').textContent = `H:${max}° L:${min}°`;

    } catch (e) {
        console.error("Weather error:", e);
    }
}
updateWeather();
setInterval(updateWeather, 600000); // 10 mins

// --- Socket & WebRTC Logic ---

// Join Room
const ROOM_ID = 'sentinel-room';
socket.emit('join', ROOM_ID);

socket.on('call_incoming', async () => {
    console.log("Incoming Call...");

    // UI Transition
    idleUI.classList.add('blurred');
    callUI.classList.remove('hidden');
    bgVideo.pause(); // Optional: pause BG video to save resources

    // Initialize WebRTC
    await startCall();
});

socket.on('call_ended', () => {
    console.log("Call Ended");
    endCall();
});

async function startCall() {
    peerConnection = new RTCPeerConnection(rtcConfig);

    // Get Microphone access only (Kiosk sends audio, receives A/V)
    try {
        localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
        localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));
    } catch (err) {
        console.error("Error accessing microphone:", err);
    }

    // Handle incoming stream (Audio + Video from Backoffice)
    peerConnection.ontrack = (event) => {
        if (remoteVideo.srcObject !== event.streams[0]) {
            remoteVideo.srcObject = event.streams[0];
            console.log("Received remote stream");
        }
    };

    // ICE Candidates
    peerConnection.onicecandidate = (event) => {
        if (event.candidate) {
            socket.emit('candidate', { room: ROOM_ID, candidate: event.candidate });
        }
    };

    // Signaling Handlers
    socket.on('offer', async (offer) => {
        await peerConnection.setRemoteDescription(new RTCSessionDescription(offer));
        const answer = await peerConnection.createAnswer();
        await peerConnection.setLocalDescription(answer);
        socket.emit('answer', { room: ROOM_ID, answer: answer });
    });

    socket.on('candidate', async (candidate) => {
        try {
            await peerConnection.addIceCandidate(new RTCIceCandidate(candidate));
        } catch (e) {
            console.error("Error adding IceCandidate", e);
        }
    });
}

function endCall() {
    // UI Reset
    idleUI.classList.remove('blurred');
    callUI.classList.add('hidden');
    bgVideo.play();

    // Close WebRTC
    if (peerConnection) {
        peerConnection.close();
        peerConnection = null;
    }
    if (localStream) {
        localStream.getTracks().forEach(track => track.stop());
        localStream = null;
    }
    remoteVideo.srcObject = null;

    // Cleanup Listeners
    socket.off('offer');
    socket.off('candidate');
}
