const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const cors = require('cors');
const crypto = require('crypto');
const bodyParser = require('body-parser');
require('dotenv').config();
const verkadaConfig = require('./verkadaConfig');
const { startStreams } = require('./stream');

// Start RTSP Streams
startStreams(verkadaConfig);

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

// Body Parser for Verkada Signature Validation (RAW BODY NEEDED)
app.use(bodyParser.json({
    verify: (req, res, buf) => {
        req.rawBody = buf;
    }
}));

app.use(express.static(path.join(__dirname, '../public')));

// -------------------------------------------------------------------
// VERKADA WEBHOOK VALIDATION
// -------------------------------------------------------------------
function validateVerkadaWebhook(req, res, next) {
    console.log("--> [HTTP] Webhook Request Received from IP:", req.ip);

    const signatureHeader = req.headers['verkada-signature'];
    const sharedSecret = process.env.VERKADA_SHARED_SECRET;

    if (!signatureHeader || !sharedSecret) {
        console.warn('Verkada Webhook: Missing Signature or Secret');
        return res.status(400).send('Missing Signature or Secret');
    }

    try {
        const [timestampStr, signature] = signatureHeader.split('|');
        const timestamp = parseInt(timestampStr, 10);
        const now = Math.floor(Date.now() / 1000);

        // 1. Replay Attack Protection (60s tolerance)
        if (Math.abs(now - timestamp) > 60) {
            console.warn('Verkada Webhook: Expired Signature');
            return res.status(403).send('Expired Signature');
        }

        // 2. HMAC Validation
        const timestampBuffer = Buffer.from(timestampStr, 'utf-8');
        const separatorBuffer = Buffer.from('|', 'utf-8');
        const signedPayload = Buffer.concat([req.rawBody, separatorBuffer, timestampBuffer]);

        const expectedSignature = crypto
            .createHmac('sha256', sharedSecret)
            .update(signedPayload)
            .digest('hex');

        if (!crypto.timingSafeEqual(Buffer.from(signature, 'hex'), Buffer.from(expectedSignature, 'hex'))) {
            console.warn('Verkada Webhook: Invalid Signature');
            return res.status(401).send('Invalid Signature');
        }

        next(); // Valid!
    } catch (err) {
        console.error('Verkada Webhook Error:', err);
        return res.status(500).send('Webhook validation error');
    }
}

// -------------------------------------------------------------------
// ROUTES
// -------------------------------------------------------------------

app.post('/verkada-webhook', validateVerkadaWebhook, (req, res) => {
    const data = req.body.data || {};
    const cameraId = data.device_id;
    // Intentar obtener el tipo de evento de data.notification_type (Verkada) o data.event_type
    const eventType = data.notification_type || data.event_type || req.body.webhook_type || 'unknown';

    // DEBUG: Print full payload
    console.log("\n--- [WEBHOOK RECEIVED] ---");
    console.log("Event Type:", eventType);
    console.log("Camera ID:", cameraId);
    console.log("Full Payload:", JSON.stringify(req.body, null, 2));
    console.log("--------------------------\n");

    const camConfig = verkadaConfig[cameraId];

    if (camConfig) {
        // FILTER LOGIC
        if (camConfig.allowedEvents) {
            console.log(`[DEBUG] Filter Check > Event: '${eventType}' | Allowed:`, camConfig.allowedEvents);

            if (!camConfig.allowedEvents.includes(eventType)) {
                console.log(`-> 🚫 Ignored Event '${eventType}' for camera '${camConfig.name}' (Not in allowed list)`);
                return res.status(200).send({ status: 'ignored', reason: 'filtered by type' });
            }
        }

        console.log(`-> Alarm Triggered for: ${camConfig.name}`);

        io.to('backoffice').emit('alarm_trigger', {
            kioskId: camConfig.id, // Critical for routing in Backoffice
            camera: camConfig.name,
            cameraId: cameraId,
            triggerVideo: camConfig.triggerVideo,
            sound: camConfig.sound,
            details: `Evento: ${eventType}`
        });
    } else {
        console.log(`-> Camera not configured in Sentinel (ID: ${cameraId}), ignoring alarm.`);
    }

    res.status(200).send({ status: 'ok' });
});
app.get('/', (req, res) => {
    res.send('Sentinel Server Running. Go to /kiosk or /backoffice');
});

// Socket.io Signaling
let connectedKiosks = new Map(); // Map<SocketID, KioskID>

io.on('connection', (socket) => {
    console.log('User connected:', socket.id);

    // Registration handling
    socket.on('register', (data) => {
        // Data can be object { role: 'kiosk', id: 'admin' } or string 'backoffice'
        const role = (typeof data === 'object') ? data.role : data;
        const kioskId = (typeof data === 'object') ? data.id : null;

        if (role === 'kiosk') {
            // Track this Kiosk
            connectedKiosks.set(socket.id, kioskId);

            // Join specific room for this Kiosk (e.g. 'kiosk-admin')
            const roomName = `kiosk-${kioskId}`;
            socket.join(roomName);

            console.log(`Kiosk registered: ${kioskId} (Room: ${roomName})`);

            // Notify backoffice that THIS specific kiosk is online
            io.to('backoffice').emit('kiosk_status', { id: kioskId, online: true });
        } else if (role === 'backoffice') {
            socket.join('backoffice');
            console.log('Backoffice registered');

            // Send status of ALL currently connected Kiosks to this new Backoffice
            connectedKiosks.forEach((kId, sId) => {
                socket.emit('kiosk_status', { id: kId, online: true });
            });

            // TEST ALARM: Now requires target
            socket.on('test_alarm', (targetId) => { // targetId = 'admin' or 'tenis'
                console.log(`[TEST] Triggering alarm for ${targetId}...`);

                // Find config by slug ID
                const camEntry = Object.entries(verkadaConfig).find(([_, cfg]) => cfg.id === targetId);

                if (camEntry) {
                    const [uuid, cfg] = camEntry;
                    io.to('backoffice').emit('alarm_trigger', {
                        kioskId: cfg.id, // CRITICAL for UI routing
                        camera: cfg.name,
                        triggerVideo: true,
                        sound: true,
                        details: "Prueba Manual V4.0"
                    });
                }
            });
        }

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
        socket.to(data.room).emit('remote_media_state', data);
    });

    socket.on('disconnect', () => {
        console.log('User disconnected:', socket.id);

        // Handle Kiosk Disconnect
        if (connectedKiosks.has(socket.id)) {
            const kId = connectedKiosks.get(socket.id);
            console.log(`Kiosk disconnected: ${kId}`);

            // Notify Backoffice
            io.to('backoffice').emit('kiosk_status', { id: kId, online: false });

            connectedKiosks.delete(socket.id);
        }
    });
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Sentinel Server running on port ${PORT}`);
});


