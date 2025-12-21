const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const cors = require('cors');
const Stream = require('node-rtsp-stream');
const fs = require('fs');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    cors: {
        origin: "*",
        methods: ["GET", "POST"]
    }
});

const PORT = 3000;
const RTSP_FilePath = path.join(__dirname, '../config.json');

// RTSP Stream Handler
let stream = null;

function startStream(url) {
    if (stream) {
        stream.stop();
    }

    if (!url || !url.startsWith('rtsp')) {
        console.log("Invalid RTSP URL, skipping stream start.");
        return;
    }

    console.log(`Starting RTSP Stream for: ${url}`);

    stream = new Stream({
        name: 'sentinel-stream',
        streamUrl: url,
        wsPort: 9999,
        ffmpegOptions: { // options ffmpeg flags
            '-stats': '', // an option with no neccessary value uses a blank string
            '-r': 30 // options with required values specify the value after the key
        }
    });
}

// Load initial config
let currentConfig = {};
if (fs.existsSync(RTSP_FilePath)) {
    try {
        currentConfig = JSON.parse(fs.readFileSync(RTSP_FilePath, 'utf8'));
        // Delay start slightly to ensure port availability
        setTimeout(() => startStream(currentConfig.rtspUrl), 2000);
    } catch (e) {
        console.error("Error loading config.json", e);
    }
}


// Middleware
app.use(cors());
app.use(express.static(path.join(__dirname, '../public')));

// Routes
// Redirect root to kiosk or offer a selection page? 
// For now, let's keep it simple: /kiosk and /backoffice paths are handled by static files if they exist,
// but we might want explicit routes.
app.get('/', (req, res) => {
    res.send('Sentinel Server Running. Go to /kiosk or /backoffice');
});

// Socket.io Signaling
let kioskSocketId = null;

io.on('connection', (socket) => {
    console.log('User connected:', socket.id);

    // Registration handling
    socket.on('register', (role) => {
        if (role === 'kiosk') {
            kioskSocketId = socket.id;
            socket.join('kiosk');
            console.log('Kiosk registered');
            // Notify all backoffices
            io.to('backoffice').emit('kiosk_status', { online: true });
        } else if (role === 'backoffice') {
            socket.join('backoffice');
            console.log('Backoffice registered');
            // Send current status to this new backoffice
            socket.emit('kiosk_status', { online: !!kioskSocketId });
        }
        // Both join the signaling room for calls
        socket.join('sentinel-room');
    });

    // RTSP Configuration
    socket.on('update_rtsp_url', (newUrl) => {
        console.log(`Updating RTSP URL to: ${newUrl}`);
        currentConfig.rtspUrl = newUrl;

        // Save to file
        fs.writeFile(RTSP_FilePath, JSON.stringify(currentConfig, null, 4), (err) => {
            if (err) console.error("Error saving config", err);
        });

        // Restart Stream
        startStream(newUrl);

        // Notify Backoffice
        io.to('backoffice').emit('rtsp_updated', newUrl);
    });

    socket.on('get_rtsp_config', () => {
        socket.emit('rtsp_config', currentConfig.rtspUrl);
    });

    // Signaling for WebRTC
    socket.on('offer', (data) => {
        socket.to(data.room).emit('offer', data.offer);
    });

    socket.on('answer', (data) => {
        socket.to(data.room).emit('answer', data.answer);
    });

    socket.on('candidate', (data) => {
        socket.to(data.room).emit('candidate', data.candidate);
    });

    // Call State Management
    socket.on('start_call', (room) => {
        console.log(`Call started in room ${room}`);
        io.to(room).emit('call_incoming');
    });

    socket.on('end_call', (room) => {
        console.log(`Call ended in room ${room}`);
        io.to(room).emit('call_ended');
    });

    // Media State Sync (Explicit)
    socket.on('media_state_change', (data) => {
        // data = { type: 'video' | 'audio', enabled: boolean, room: '...' }
        socket.to(data.room).emit('remote_media_state', data);
    });

    socket.on('disconnect', () => {
        console.log('User disconnected:', socket.id);
        if (socket.id === kioskSocketId) {
            kioskSocketId = null;
            io.to('backoffice').emit('kiosk_status', { online: false });
            console.log('Kiosk disconnected');
        }
    });
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Sentinel Server running on port ${PORT}`);
});
