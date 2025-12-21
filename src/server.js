const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const cors = require('cors');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    cors: {
        origin: "*",
        methods: ["GET", "POST"]
    }
});

const PORT = 3000;

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
