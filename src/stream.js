const Stream = require('node-rtsp-stream');

// Función para iniciar todos los streams configurados
function startStreams(verkadaConfig) {
    console.log("--> [STREAM] Inicializando Multi-Streams...");

    // Convertir objeto config a array
    const cameras = Object.values(verkadaConfig);

    cameras.forEach(cam => {
        if (!cam.rtspUrl || !cam.streamPort) {
            console.warn(`[STREAM] Salteando ${cam.name}: Falta URL o Puerto`);
            return;
        }

        console.log(`--> [STREAM] Iniciando ${cam.name} en puerto ${cam.streamPort}`);

        new Stream({
            name: `stream-${cam.id}`,
            streamUrl: cam.rtspUrl,
            wsPort: cam.streamPort,
            ffmpegOptions: {
                '-stats': '',
                '-r': 24,
                '-s': '640x360',
                '-rtsp_transport': 'tcp' // CLAVE: Usa TCP para evitar perdida de paquetes
            }
        });
    });

    console.log(`--> [STREAM] ${cameras.length} streams procesados.`);
}

module.exports = { startStreams };