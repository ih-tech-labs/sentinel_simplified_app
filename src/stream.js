const Stream = require('node-rtsp-stream');

// ==========================================
// CONFIGURACIÓN GLOBAL
// Pegar aquí la URL del RTSP de la cámara
// ==========================================
//const RTSP_URL = 'rtsp://admin:Admin0962@1b4f9d050d8134690137ec8272763c96.2.camera.verkada-lan.com:8554/standard';
const RTSP_URL = 'rtsp://admin:Admin0962@2f206bcb1ad24144a5192eaf72758885.5.camera.verkada-lan.com:8554/standard';
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