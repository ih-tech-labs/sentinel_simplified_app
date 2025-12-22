// Mapeo de Cámaras de Verkada
// ID de Verkada -> Nombre Amigable y Configuración
// El ID se obtiene del webhook (device_id)

const verkadaConfig = {
    // Ejemplo:
    // "b9f36a44-....": { name: "Acceso Principal", triggerVideo: true, sound: true },

    // Puedes ir agregando los IDs reales a medida que lleguen al log
    // Kiosco 1: Administración (Planta Baja)
    "4b5525c7-fc5a-4616-8f0f-5ad21a92c45e": {
        id: "admin", // Slug para URL ?id=admin
        name: "Administración",
        triggerVideo: true,
        sound: true,
        allowedEvents: ['alert_rule_line_crossing'],
        rtspUrl: "rtsp://admin:Admin0962@dc58d86505200da3b7675766a03f287a.14.camera.verkada-lan.com:8554/high",
        streamPort: 9998
    },

    // Kiosco 2: House Tenis (Antes Escalera)
    "95b12b72-e081-488b-9ad5-f8ea6f1223b7": {
        id: "tenis", // Slug para URL ?id=tenis
        name: "House Tenis",
        triggerVideo: true,
        sound: true,
        rtspUrl: "rtsp://admin:Admin0962@2f206bcb1ad24144a5192eaf72758885.5.camera.verkada-lan.com:8554/high",
        streamPort: 9999
    }
};

module.exports = verkadaConfig;