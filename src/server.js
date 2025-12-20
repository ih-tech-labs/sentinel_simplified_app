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
io.on('connection', (socket) => {
    console.log('User connected:', socket.id);

    socket.on('join', (room) => {
        socket.join(room);
        console.log(`User ${socket.id} joined room: ${room}`);

        // Notify others in room that a peer joined (Simple presence check)
        // If this is the kiosk joining (we can infer or pass type), notify backoffice
        // For simplicity, just tell everyone "peer_joined"
        socket.to(room).emit('peer_joined');
    });

    // Simple ping-pong for status check
    socket.on('ping_status', (room) => {
        socket.to(room).emit('ping_req');
    });

    socket.on('ping_res', (room) => {
        socket.to(room).emit('peer_active');
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

    socket.on('disconnect', () => {
        console.log('User disconnected:', socket.id);
    });
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Sentinel Server running on port ${PORT}`);
});
