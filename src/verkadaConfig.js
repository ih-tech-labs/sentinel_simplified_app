// Mapeo de Cámaras de Verkada
// ID de Verkada -> Nombre Amigable y Configuración
// El ID se obtiene del webhook (device_id)

const verkadaConfig = {
    // Ejemplo:
    // "b9f36a44-....": { name: "Acceso Principal", triggerVideo: true, sound: true },

    // Puedes ir agregando los IDs reales a medida que lleguen al log
    "95b12b72-e081-488b-9ad5-f8ea6f1223b7": {
        name: "Planta Baja",
        triggerVideo: true,
        sound: true,
        allowedEvents: ['alert_rule_line_crossing'] // Filtro: Solo cruce de linea
    }
    // },

    // "12e64eb5-6b27-4426-9a99-f603611ab48d": {
    // name: "Escalera_6to_piso",
    // triggerVideo: true,
    // sound: true,
    // allowedEvents: ['alert_rule_line_crossing'] // Filtro: Solo cruce de linea
    //}
};

module.exports = verkadaConfig;
