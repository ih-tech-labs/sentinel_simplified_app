# Instalación desde cero

Raspberry Pi 5 con Raspberry Pi OS (Bookworm, 64-bit).

---

## 1. Copiar el proyecto a la Pi

Por USB, `scp` o `git clone`. Podés ponerla donde quieras:

```bash
mv sentinel_simplified_app ~/sentinel
cd ~/sentinel
chmod +x install.sh sentinel
```

## 2. Correr el instalador

```bash
./install.sh
```

Instala Node, ffmpeg, Chromium, pm2 y pyserial, te hace el asistente, deja los servicios corriendo y configura el arranque automático.

---

## 3. Contestar el asistente

### Nombre del equipo

Se pregunta **una sola vez** y de ahí sale todo lo demás:

```
¿Cómo se llama este equipo?
Nombre: Catamarca

Con ese nombre configuro:
    En el tablero se ve        Catamarca
    Identificador interno      catamarca
    Dominio para el túnel      sentinel-catamarca.ihtechlabs.com
```

| | |
|---|---|
| **Nombre** | Lo que ves en el tablero. Con mayúsculas, acentos y espacios si querés |
| **Identificador** | Versión sin acentos ni espacios. Va en la URL del kiosko: `/kiosk/?id=catamarca` |
| **Dominio** | Se sugiere `sentinel-<identificador>.ihtechlabs.com` |

El nombre visible lo cambiás cuando quieras. El identificador conviene dejarlo: va en la URL y en el autostart.

### El resto

| Pregunta | Qué poner |
|---|---|
| Usuario | Enter (`Bunker`) |
| Contraseña | Enter usa `!BunkerCE2026`, o escribí otra |
| **URL RTSP** | La de la cámara. Se prueba en el momento |
| device_id de Verkada | Enter para omitir y cargarlo después |
| ¿Agregar otra cámara? | `n` |
| Shared secret de Verkada | El de Verkada Command → Admin → Webhooks |
| ¿Configurar túnel? | `s` |
| Dominio | **Enter** — ya viene sugerido |
| ¿Hay pantalla de kiosko? | `s` o `n` |
| Orientación | `1` si la pantalla está vertical girada en sentido horario |
| ¿Hay Arduino? | Según el equipo |

El puerto no se pregunta si el 3000 está libre. La cámara hereda el nombre del equipo. El nombre del túnel se deriva del dominio.

## 4. Reiniciar

```bash
sudo reboot
```

Al volver: kiosko a pantalla completa y tablero accesible.

---

## Instalar sobre un equipo que ya tenía Sentinel

Si el equipo ya tiene una versión corriendo, el instalador **la detecta y la fotografía antes de tocar nada**. Antes de pedirte confirmación te lo muestra:

```
Este equipo ya tenía Sentinel
  · servicio pm2 'sentinel-server'
  · túnel sentinel.ihtechlabs.com
  · autostart del kiosko

Se va a fotografiar todo antes de tocar nada.
Para deshacer:  ./install.sh --rollback
```

Si ese bloque no aparece, cancelá: no detectó lo anterior y no vas a tener vuelta atrás.

La versión anterior se **detiene, no se borra**. Para deshacer:

```bash
./install.sh --rollback
```

Restaura el autostart, revive el servicio anterior y **devuelve el túnel al original** — `/etc/cloudflared` entero, con credenciales y cert, y el DNS repuntado si el túnel nuevo se quedó con el dominio.

El túnel nuevo sigue existiendo en tu cuenta de Cloudflare; el rollback es local. Se borra después con `./cleanup_old.sh --tunnels`.

Para el paso a paso completo de Costa Esmeralda: [SECUENCIA-CE.md](SECUENCIA-CE.md).

---

## Cuidado con crear túneles de más

Si en la cuenta de Cloudflare ya existe un túnel para este equipo, el instalador lo **lista antes de preguntarte el dominio**. Si usás el mismo dominio, se reutiliza en vez de crear otro.

El problema aparece cuando el dominio se escribe apenas distinto — `sentinelcatamarca` vs `sentinel-catamarca` — porque el nombre del túnel se deriva del dominio y termina creando uno nuevo.

Antes de instalar, mirá qué hay:

```bash
cloudflared tunnel list
```

Si hay restos de una instalación anterior, borralos:

```bash
sudo systemctl stop cloudflared          # un túnel conectado no se deja borrar
cloudflared tunnel delete <nombre-viejo>
```

Y en [dash.cloudflare.com](https://dash.cloudflare.com) → `ihtechlabs.com` → **DNS → Records**, borrá el CNAME huérfano. El borrado del túnel no lo saca solo.

---

## Dónde va la URL RTSP

Durante la instalación te la pide el asistente y la prueba con `ffprobe`. Después vive en `config/cameras.json`:

```json
{
  "site": "Catamarca",
  "cameras": [
    {
      "deviceId": "4b5525c7-fc5a-...",
      "id": "catamarca",
      "name": "Catamarca",
      "shortName": "CATAMARCA",
      "zone": "",
      "rtspUrl": "rtsp://usuario:clave@192.168.1.50:554/Streaming/Channels/102",
      "triggerVideo": true,
      "sound": true,
      "allowedEvents": ["alert_rule_line_crossing", "alert_rule_motion"]
    }
  ]
}
```

Editás, `sentinel restart server`, y listo. El backoffice se rearma solo.

### Formatos comunes

```
Verkada     rtsp://usuario:clave@HOST.camera.verkada-lan.com:8554/standard
Hikvision   rtsp://usuario:clave@192.168.1.50:554/Streaming/Channels/102
Dahua       rtsp://usuario:clave@192.168.1.50:554/cam/realmonitor?channel=1&subtype=1
Axis        rtsp://usuario:clave@192.168.1.50:554/axis-media/media.amp
Reolink     rtsp://usuario:clave@192.168.1.50:554/h264Preview_01_sub
```

**Usá el substream si existe.** Hikvision: `/Channels/102` en vez de `/101`. Dahua: `subtype=1` en vez de `0`. La Pi transcodifica por software.

---

## Webhook de Verkada

Verkada es un servicio en la nube: necesita llegar a la Pi **desde internet**. Una IP local no le sirve, por eso el túnel.

Al terminar, el instalador te muestra la URL para **Verkada Command → Admin → Webhooks**:

```
https://sentinel-catamarca.ihtechlabs.com/verkada-webhook
```

Requiere estar logueado en Cloudflare. Si no lo estás, el script te dice cómo:

```bash
cloudflared tunnel login
```

**Dos cosas que fallan en silencio:** si `VERKADA_SHARED_SECRET` está vacío en `.env` el webhook rechaza todo; y si el `deviceId` no coincide con el que manda Verkada, el evento se ignora como `unknown_camera`. Para conseguirlo: disparás una alarma real y mirás `sentinel logs server`.

---

## Después

Todo se opera con un comando — ver [OPERACION.md](OPERACION.md):

```bash
sentinel status       # ¿está todo bien?
sentinel diagnose     # ¿qué está fallando?
sentinel logs         # ver qué pasa
sentinel              # todos los comandos
```

Si algo salió mal y querés empezar de nuevo:

```bash
./remove_all.sh       # borra todo (pide escribir BORRAR)
./install.sh          # y de vuelta
```

`remove_all.sh` **no borra los túneles de tu cuenta de Cloudflare**, sólo la config local. Eso lo hacés vos con `cloudflared tunnel delete`.

---

## Qué instala

**Paquetes:** ffmpeg, curl, git, python3 + pyserial, lsof, netcat, dnsutils, unclutter, x11-xserver-utils, wlr-randr, fonts-dejavu-core, Chromium, Node.js 20 LTS, pm2. Y cloudflared si pediste el túnel.

**Servicios pm2:** `sentinel` y `sentinel-gpio`, ambos con arranque automático.

**Archivos:**

```
config/cameras.json                         cámaras y URLs RTSP
.env                                        contraseña hasheada, puerto, tuning
data/                                       historial de alarmas
.screen_rotation                            orientación de la pantalla
~/.config/autostart/sentinel-kiosk.desktop  autostart del kiosko
/etc/cloudflared/config.yml                 túnel
```

**Seguridad:** contraseña como hash scrypt con salt aleatorio, nunca en texto plano. `.env` y `cameras.json` con permisos `600`.

Al terminar deja un reporte en `~/sentinel-instalacion-<equipo>-<fecha>.txt` con versiones, configuración y el resultado de cada verificación. Las credenciales RTSP van enmascaradas.
