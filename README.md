# Sentinel

Kiosko + backoffice de monitoreo para Raspberry Pi 5.

Una pantalla vertical con video de fondo, reloj y clima; un centro de monitoreo web con las cámaras en vivo, llamadas bidireccionales y alarmas de Verkada; y control de luces por Arduino.

---

## Los tres comandos

| | Cuándo |
|---|---|
| `./install.sh` | Equipo nuevo, desde cero → [INSTALL.md](INSTALL.md) |
| `./deploy.sh` | Migrar conservando el túnel existente → [DEPLOY.md](DEPLOY.md) |
| `./install.sh --rollback` | Deshacer una instalación sobre un equipo que ya tenía Sentinel → [SECUENCIA-CE.md](SECUENCIA-CE.md) |
| `./remove_all.sh` | Desinstalar todo |
| `./cleanup_old.sh` | Borrar la versión vieja y los túneles que sobren, después de migrar |

Después de instalado, todo se opera con un solo comando:

```bash
./sentinel status       # ¿está todo bien?
./sentinel diagnose     # ¿qué está fallando?
./sentinel              # todos los comandos
```

Ver [OPERACION.md](OPERACION.md).

---

## Estructura

```
sentinel/
├── install.sh          instalación desde cero
├── deploy.sh           migración con preflight y vuelta atrás
├── cleanup_old.sh      limpieza posterior (versión vieja, túneles)
├── remove_all.sh       desinstalación
├── sentinel            operación del día a día
│
├── lib/                lógica compartida por los scripts
│   ├── common.sh         entrada saneada, colores, helpers HTTP
│   ├── checks.sh         suite de verificación
│   ├── deploy.sh         preflight, snapshot y restauración
│   ├── tunnel.sh         túnel de Cloudflare
│   ├── webhook.sh        diagnóstico del webhook de Verkada
│   ├── gpio.sh           control de luces
│   └── screen.sh         rotación de pantalla
│
├── src/                servidor Node
│   ├── server.js         HTTP, rutas, webhook de Verkada
│   ├── cameras.js        lee config/cameras.json
│   ├── auth.js           login, sesiones, rate limiting
│   ├── streams.js        ffmpeg on-demand sobre WebSocket
│   ├── sockets.js        presencia, alarmas, signaling WebRTC
│   ├── events.js         historial persistente
│   ├── system.js         telemetría de la Pi
│   ├── devices.js        puente al Arduino
│   ├── poi.js            fotos del saludo a Personas de Interés
│   └── appearance.js     apariencia del kiosko (editable desde el backoffice)
│
├── public/             kiosko, backoffice y login
├── scripts/            daemon serie del Arduino
│
├── config/cameras.json ← LAS URLs RTSP VAN ACÁ
└── .env                contraseña, puerto, tuning
```

---

## Decisiones de diseño

### El video del kiosko

El archivo original era **2160x3840 a 24 Mbps H.264**. La Raspberry Pi 5 **no tiene decodificador H.264 por hardware** — se quitó respecto de la Pi 4, sólo quedó HEVC — así que se decodificaba entero por software, 30 veces por segundo. Por eso se veía trabado.

Ahora es 1080x1920 a 1,2 Mbps: de 75 MB a 3,7 MB. Además se eliminó el `backdrop-filter: blur(20px)` que había sobre el video (obliga al compositor a releer el framebuffer en cada cuadro) y el `--disk-cache-dir=/dev/null` de Chromium, que impedía cachearlo.

Para cambiarlo: `sentinel video <archivo>`.

### Streams on-demand

ffmpeg arranca cuando alguien abre el backoffice y se apaga 25 segundos después de que se va el último espectador. En una Pi 5 es la diferencia entre ~60% de CPU permanente y ~3% en reposo — y menos CPU significa menos temperatura, que en un equipo sin ventilación importa.

Todo va por el puerto 3000, incluido el video: pasa por el túnel de Cloudflare y no hay que abrir puertos en el firewall. El WebSocket valida la cookie de sesión.

Si ffmpeg se cae o la cámara deja de mandar datos por 15 segundos, se reinicia solo con backoff exponencial.

### Seguridad

Simple a propósito: sin OAuth, sin base de datos de usuarios, sin dependencias externas.

Contraseña como hash **scrypt** con salt aleatorio. Sesión en cookie `HttpOnly` firmada con HMAC-SHA256, con el secreto persistido en disco (un `pm2 restart` no te desloguea). Rate limiting de 8 intentos por IP.

Protegidos: `/backoffice/`, la API y el WebSocket de video. **Público a propósito:** `/kiosk/` — es una pantalla física que arranca sola con el sistema; si pidiera login no podría bootear desatendida.

### Saludo a Personas de Interés

Cuando el webhook de Verkada trae un evento de POI (`person_of_interest`), en vez de alarma se dispara una bienvenida: popup en el kiosko con el nombre del perfil y la foto del evento, y los LEDs pasan al preset configurado unos segundos antes de volver solos al estado anterior (un comando manual del operador cancela la restauración). La foto **no** se muestra desde la URL de Verkada — es firmada, puede expirar, y el kiosko puede estar sin internet — sino que el servidor la descarga una vez y la sirve local desde `/poi-images/`. Todo se configura en `.env` (`POI_*`); una llamada en curso tiene prioridad sobre el popup.

### Apariencia del kiosko sin tocar código

Desde el backoffice (panel **Apariencia del Kiosko**) se editan tipografía, color del texto, tamaño del reloj y de los textos, y qué widgets se ven (reloj, fecha, clima, línea de estado). Se guarda en `config/appearance.json` — fuera del repo, como `cameras.json`, porque es configuración del sitio — y se aplica **en vivo** por socket: el kiosko no se reinicia. Las tipografías son una lista curada de fuentes del sistema, no webfonts: misma razón que en `tokens.css`, un kiosko sin internet no puede bloquear el render esperando a Google Fonts.

### Historial sin base de datos

Ring buffer en memoria + JSONL append-only con rotación. Cero dependencias nativas: `better-sqlite3` sería un punto de falla más en cada `npm install` y en cada actualización de Node, y para el volumen de estos sitios no aporta nada.

---

## Bugs corregidos de la versión anterior

**Fugas de listeners.** Los handlers de `offer`, `candidate` y `remote_media_state` se registraban dentro de `startCall()`. Cada llamada dejaba un listener más: a la quinta, un mismo ICE candidate se procesaba cinco veces. Lo mismo con `test_alarm` en el servidor, registrado dentro de `register`.

**Crosstalk de signaling.** El WebRTC usaba una room global compartida, así que con dos kioskos los ICE candidates de uno llegaban al otro.

**Kioskos fantasma.** El `Map<socketId, kioskId>` no manejaba reconexiones: un kiosko podía quedar contado dos veces.

**Webhook con código incorrecto.** `crypto.timingSafeEqual` lanza excepción si los buffers tienen distinto largo, y esa excepción caía en el catch genérico devolviendo **500**. Una firma mal formada se reportaba como error del servidor en vez de rechazo.

**MPEG-1 a 12 fps.** MPEG-1 sólo admite oficialmente 24/25/30/50/60 fps; con 12 ffmpeg abortaba. Se agregó `-strict -1`.

**jsmpeg desde CDN.** Sin internet, el backoffice se quedaba sin reproductor. Ahora se sirve local.

**`curl -f` en los chequeos.** Con `-f`, curl sale con error en un 401 y el `|| echo 000` concatenaba: un 401 daba `401000` y el chequeo de "API protegida" fallaba en falso.

**Instalador de Cloudflare destructivo.** Hacía "destruir y recrear" sobre un nombre fijo: correrlo en un equipo nuevo con la misma cuenta borraba el túnel de producción de otro sitio.

**Entrada con bytes de control.** Si el backspace del terminal no coincide con lo que espera la tty (habitual por SSH), inserta un `0x08` o `0x7F` crudo que quedaba guardado en la variable y rompía un hostname o un JSON mucho más adelante.
