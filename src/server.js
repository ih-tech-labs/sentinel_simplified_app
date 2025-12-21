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
let isKioskOnline = false;

// Middleware
app.use(cors());
app.use(express.static(path.join(__dirname, '../public')));

// Routes
app.get('/', (req, res) => {
    res.send('Sentinel Server Running. Go to /kiosk or /backoffice');
});

// Socket.io Signaling
io.on('connection', (socket) => {
    // console.log('User connected:', socket.id);

    // Registration to track presence
    socket.on('register', (type) => {
        if (type === 'kiosk') {
            socket.join('kiosk_room');
            isKioskOnline = true;
            socket.type = 'kiosk';
            // Notify backoffice
            io.to('backoffice_room').emit('kiosk_status', 'online');
            console.log("Kiosk Registered (Online)");
        } else if (type === 'backoffice') {
            socket.join('backoffice_room');
            socket.type = 'backoffice';
            // Send current status immediately
            socket.emit('kiosk_status', isKioskOnline ? 'online' : 'offline');
            console.log("Backoffice Registered");
        }
    });

    socket.on('join', (room) => {
        socket.join(room);
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

    // Events
    socket.on('camera_state', (state) => {
        // Broadcast to room (Sentinel room)
        socket.to('sentinel-room').emit('camera_state', state);
    });

    // Call State Management
    socket.on('start_call', (room) => {
        io.to(room).emit('call_incoming');
    });

    socket.on('end_call', (room) => {
        io.to(room).emit('call_ended');
    });

    socket.on('disconnect', () => {
        if (socket.type === 'kiosk') {
            isKioskOnline = false;
            io.to('backoffice_room').emit('kiosk_status', 'offline');
            console.log("Kiosk Disconnected");
        }
    });
});


server.listen(PORT, '0.0.0.0', () => {
    console.log(`Sentinel Server running on port ${PORT}`);
});
