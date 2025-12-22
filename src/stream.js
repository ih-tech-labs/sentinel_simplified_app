const Stream = require('node-rtsp-stream');

// ==========================================
// CONFIGURACIÓN GLOBAL
// Pegar aquí la URL del RTSP de la cámara
// ==========================================
const RTSP_URL = 'rtsp://admin:Admin0962@dc58d86505200da3b7675766a03f287a.14.camera.verkada-lan.com:8554/standard';
// ==========================================

const STREAM_PORT = 9999;

console.log(`Iniciando Bridge RTSP...`);
console.log(`Fuente: ${RTSP_URL}`);
console.log(`Puerto WebSocket: ${STREAM_PORT}`);

const stream = new Stream({
    name: 'sentinel-stream',
    streamUrl: RTSP_URL,
    wsPort: STREAM_PORT,
    ffmpegOptions: {
        '-stats': '',
        '-r': 24, // 24fps es suficiente para cine/video
        '-s': '640x360', // 16:9 ratio correcto
        '-rtsp_transport': 'tcp' // CLAVE: Usa TCP para evitar perdida de paquetes (pixelado gris)
    }
});

console.log("Stream activo. Esperando conexiones en ws://<IP>:" + STREAM_PORT);