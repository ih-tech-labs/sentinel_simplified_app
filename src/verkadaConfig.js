// Mapeo de Cámaras de Verkada
// ID de Verkada -> Nombre Amigable y Configuración
// El ID se obtiene del webhook (device_id)

const verkadaConfig = {
    // Ejemplo:
    // "b9f36a44-....": { name: "Acceso Principal", triggerVideo: true, sound: true },

    // Puedes ir agregando los IDs reales a medida que lleguen al log
    // Kiosco 1: Administración (Planta Baja)
    "95b12b72-e081-488b-9ad5-f8ea6f1223b7": {
        id: "admin", // Slug para URL ?id=admin
        name: "Administración",
        triggerVideo: true,
        sound: true,
        allowedEvents: ['alert_rule_line_crossing'],
        rtspUrl: "rtsp://admin:Admin0962@dc58d86505200da3b7675766a03f287a.14.camera.verkada-lan.com:8554/standard",
        streamPort: 9998
    },

    // Kiosco 2: House Tenis (Antes Escalera)
    "12e64eb5-6b27-4426-9a99-f603611ab48d": {
        id: "tenis", // Slug para URL ?id=tenis
        name: "House Tenis",
        triggerVideo: true,
        sound: true,
        rtspUrl: "rtsp://admin:Admin0962@2f206bcb1ad24144a5192eaf72758885.5.camera.verkada-lan.com:8554/standard",
        streamPort: 9999
    }
};

module.exports = verkadaConfig;