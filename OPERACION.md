# Operación

Todo se maneja con un comando: `sentinel`.

```bash
cd ~/sentinel && ./sentinel
```

---

## Día a día

```bash
sentinel status              # ¿está todo bien?
sentinel logs                # ver qué está pasando
sentinel logs tunnel 100     # últimas 100 líneas del túnel
sentinel restart             # reiniciar todo
sentinel cameras             # ver las cámaras configuradas
sentinel report              # generar un .txt del estado del equipo
```

`sentinel report` deja un archivo con versiones, configuración, cámaras (con las credenciales RTSP enmascaradas) y el resultado de cada verificación. Sirve para archivar por cliente o para mandar cuando algo falla.

---

## Cuando algo no anda

```bash
sentinel diagnose            # revisa todo y dice dónde se corta
sentinel diagnose gpio       # sólo el control de luces
sentinel diagnose gpio --fix # e intenta repararlo
sentinel diagnose tunnel     # sólo el acceso desde internet
sentinel diagnose video      # sólo el video de fondo
```

Cada diagnóstico recorre la cadena de a un eslabón y termina con los comandos concretos a ejecutar, en orden.

---

## Cambiar la configuración

### Cámaras y URLs RTSP

Todo vive en `config/cameras.json`:

```json
{
  "site": "Costa Esmeralda",
  "cameras": [
    {
      "deviceId": "95b12b72-...",
      "id": "tenis",
      "name": "House Tenis",
      "shortName": "TENIS",
      "zone": "Sector Deportivo",
      "rtspUrl": "rtsp://usuario:clave@192.168.1.50:554/Streaming/Channels/102",
      "triggerVideo": true,
      "sound": true,
      "allowedEvents": ["alert_rule_line_crossing", "alert_rule_motion"]
    }
  ]
}
```

| Campo | Para qué |
|---|---|
| `id` | Va en la URL del kiosko: `/kiosk/?id=tenis`. No conviene cambiarlo después |
| `name` | Nombre visible. Este sí se cambia cuando quieras |
| `shortName` | Etiqueta sobre el video, estilo CCTV |
| `rtspUrl` | `null` = puesto sin video (sólo llamadas y alarmas) |
| `deviceId` | El de Verkada. `null` = no recibe alarmas |
| `allowedEvents` | `null` = acepta todos los tipos |

Editás, guardás, y `sentinel restart server`. El backoffice se rearma solo: con una cámara usa layout centrado, con más pasa a grilla.

**Usá el substream si existe.** Hikvision: `/Channels/102` en vez de `/101`. Dahua: `subtype=1` en vez de `0`. La Pi transcodifica por software.

### Contraseña

```bash
sentinel password              # la pide y verifica que el login funcione
sentinel password "NuevaClave"
```

### Pantalla

```bash
sentinel rotate          # ver estado actual
sentinel rotate 90       # horario
sentinel rotate 270      # antihorario
```

Raspberry Pi OS puede correr Wayland (labwc o wayfire) o X11, y cada uno se configura distinto. El comando detecta cuál está y escribe donde corresponde. Además la rotación se reaplica al lanzar el kiosko, porque el compositor a veces resetea la salida cuando el monitor renegocia el EDID — típico si la pantalla se enciende después que la Pi.

### Video de fondo

```bash
sentinel video ~/mi-video.mp4        # → 1080x1920
sentinel video ~/mi-video.mp4 720    # → 720x1280, si el equipo va justo
```

No copies el archivo a mano a `public/assets/`. La Pi 5 no tiene decodificador H.264 por hardware: un archivo en 4K se ve trabado sí o sí.

### Rendimiento

Si el backoffice se ve pesado o la Pi calienta, bajá la calidad en `.env`:

```ini
STREAM_WIDTH=480
STREAM_HEIGHT=270
STREAM_FPS=10
STREAM_BITRATE=300k
```

Y `sentinel restart server`.

---

## Túnel de Cloudflare

Verkada es un servicio en la nube: para mandar alarmas necesita llegar a la Pi **desde internet**. Una IP local no le sirve.

```bash
sentinel tunnel status                              # diagnóstico completo
sentinel tunnel list                                # túneles de la cuenta
sentinel tunnel setup sentinel-catamarca.ihtechlabs.com
sentinel tunnel delete <nombre>
sentinel tunnel clean                               # borra la config local
```

### Un subdominio por equipo

| Sitio | Dominio | Túnel |
|---|---|---|
| Costa Esmeralda | `sentinel.ihtechlabs.com` | `sentinel` |
| Otro sitio | `sentinel-<sitio>.ihtechlabs.com` | `sentinel-<sitio>` |

Un solo nivel de subdominio: el certificado gratuito de Cloudflare cubre `*.ihtechlabs.com` pero no `a.b.ihtechlabs.com`.

Si reusás un dominio que ya usa otro equipo, `tunnel setup` lo detecta comparando el UUID del CNAME y te obliga a escribir `PISAR`. Sin eso, el otro equipo se quedaría sin webhook y nadie se enteraría hasta que falle una alarma.

### El panel web

Cloudflare tiene dos lugares con la misma información:

- [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Networks** → **Connectors**
- [dash.cloudflare.com](https://dash.cloudflare.com) → **Networking** → **Tunnels**

Los túneles que creamos son **locally-managed**: la config vive en `/etc/cloudflared/config.yml`, no en Cloudflare. Aparecen en la lista pero el panel dice que no podés editar su configuración. Es normal.

Para el DNS: `dash.cloudflare.com` → `ihtechlabs.com` → **DNS → Records**. Buscá los CNAME a `<uuid>.cfargotunnel.com`. Revisá que el proxy esté **naranja** (si está gris el túnel no funciona), que no haya CNAMEs huérfanos apuntando a túneles borrados, y que no haya un registro A pisando al CNAME.

### Códigos de error

| | |
|---|---|
| **530** | El túnel no está conectado |
| **502** | cloudflared corre pero no alcanza `localhost:3000` |
| **000** | El dominio no resuelve, o el DNS no propagó todavía |

Si un túnel figura sin conexiones activas, cloudflared no logra salir a Cloudflare: necesita **UDP 7844** (cae a TCP 7844 si está bloqueado). En redes con firewall restrictivo es lo primero a mirar.

---

## Control de luces

```bash
sentinel diagnose gpio        # revisa la cadena completa
sentinel diagnose gpio --fix  # e intenta repararla
```

La causa más frecuente y menos obvia: **pm2 hereda los grupos de la sesión que lo arrancó.** Si pm2 ya estaba levantado cuando el instalador agregó tu usuario a `dialout`, el daemon queda sin ese grupo aunque tu shell sí lo tenga. Un `pm2 restart` no alcanza:

```bash
pm2 kill && pm2 resurrect    # o directamente: sudo reboot
```

El daemon (`scripts/gpio_daemon.py`) mantiene el puerto serie abierto de por vida y escucha en `127.0.0.1:8765`. Eso importa porque abrir el puerto **resetea el Arduino** por DTR: el script original abría y cerraba en cada comando, con 2 segundos de latencia y un parpadeo cada vez.

---

## Problemas frecuentes

**El servidor no arranca**

```bash
sentinel logs server 50
```

Si el problema está en `cameras.json`, el mensaje dice exactamente qué campo corregir.

**Una cámara no muestra video**

```bash
ffprobe -rtsp_transport tcp -v error -show_entries stream=codec_name,width,height \
  -of default=noprint_wrappers=1 "rtsp://usuario:clave@ip:554/ruta"
```

Si eso tampoco responde, el problema es de red o credenciales, no de Sentinel.

**El kiosko no arranca solo**

```bash
cat ~/.config/autostart/sentinel-kiosk.desktop   # debe existir
sentinel status                                   # el servicio debe estar online
sentinel kiosk tenis                              # probarlo a mano
```

**Las alarmas de Verkada no llegan**

Tres cosas que fallan en silencio:

1. `VERKADA_SHARED_SECRET` vacío en `.env` → el webhook rechaza todo
2. El `deviceId` de `cameras.json` no coincide con el que manda Verkada → `unknown_camera`
3. El túnel caído → Verkada no llega

Para conseguir el `deviceId`: disparás una alarma real, mirás `sentinel logs server`, y ahí aparece.

---

## Archivos

| | |
|---|---|
| `config/cameras.json` | Cámaras y URLs RTSP |
| `.env` | Contraseña hasheada, puerto, tuning |
| `data/events.jsonl` | Historial de alarmas |
| `/etc/cloudflared/config.yml` | Túnel |
| `~/.config/autostart/sentinel-kiosk.desktop` | Autostart del kiosko |

`.env` y `cameras.json` quedan con permisos `600`: contienen el hash de la contraseña y las credenciales de las cámaras.
