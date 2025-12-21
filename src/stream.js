const Stream = require('node-rtsp-stream');

// ==========================================
// CONFIGURACIÓN GLOBAL
// Pegar aquí la URL del RTSP de la cámara
// ==========================================
const RTSP_URL = 'rtsp://admin:12345@192.168.1.10:554/stream';
// ==========================================

const STREAM_PORT = 9999;

console.log(`Iniciando Bridge RTSP...`);
console.log(`Fuente: ${RTSP_URL}`);
console.log(`Puerto WebSocket: ${STREAM_PORT}`);

const stream = new Stream({
    name: 'sentinel-stream',
    streamUrl: RTSP_URL,
    wsPort: STREAM_PORT,
    ffmpegOptions: { // opciones ffmpeg
        '-stats': '', // imprimir stats
        '-r': 30, // fps
        '-s': '640x480' // resolución reducida para performance en RPi
    }
});

console.log("Stream activo. Esperando conexiones en ws://<IP>:" + STREAM_PORT);
