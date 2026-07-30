# Migrar Costa Esmeralda

Para la Raspberry que ya tiene la versión anterior con el túnel `sentinel.ihtechlabs.com`.

> **¿Migrar o instalar de cero?** `deploy.sh` hereda el `.env` y las cámaras de la versión anterior y conserva el túnel. Si querés arrancar limpio —cámaras nuevas, túnel nuevo, configuración desde el asistente— usá `./install.sh`, que también tiene rollback: [SECUENCIA-CE.md](SECUENCIA-CE.md).

---

## Lo que no se toca

**El túnel de Cloudflare no se modifica en ningún momento** — ni al migrar, ni al volver atrás. Es lo único que no se puede reconstruir desde el equipo: si se rompe, el sitio se queda sin alarmas de Verkada y hay que ir a Cloudflare a rehacerlo.

Concretamente, quedan igual:

- El túnel `sentinel` y su UUID
- El registro DNS de `sentinel.ihtechlabs.com`
- **La URL del webhook en Verkada Command** — no hay que tocar nada allá
- La carpeta de la versión anterior

Lo que sí cambia: el servicio pm2 pasa de `sentinel-server` a `sentinel`, el autostart del kiosko apunta a la carpeta nueva, y el puerto 3000 lo sirve la versión nueva.

---

## 1. Copiar el proyecto

Sin pisar la instalación actual:

```bash
cd ~
git clone --depth 1 git@github.com:ih-tech-labs/sentinel_simplified_app.git sentinel-nuevo
cd sentinel-nuevo
```

Los scripts llegan ejecutables. Si la versión anterior no está en una ruta habitual, se la indicás con `--old-dir`.

## 2. Preflight — saber de antemano si se puede

```bash
./deploy.sh --check
```

**No modifica absolutamente nada.** Verifica y reporta:

| | |
|---|---|
| Requisitos | Node 18+, ffmpeg, pm2, pyserial |
| Recursos | Espacio en disco, temperatura del SoC |
| Conectividad | npm y Cloudflare alcanzables por HTTPS |
| Versión nueva | Archivos completos, sintaxis de todo el código |
| Versión anterior | Que exista, y que tenga `.env` para heredar el secret |
| Puerto | Que el del túnel coincida con el de la versión nueva |
| Túnel | Que esté corriendo y responda desde internet |

Termina con un veredicto claro:

```
TODO LISTO. Se puede migrar.
```

o

```
NO MIGRAR TODAVÍA · 2 problema(s)
```

Y antes del veredicto lista explícitamente qué se toca y qué no.

## 3. Migrar

```bash
./deploy.sh
```

Vuelve a correr el preflight —si algo cambió desde el chequeo, se detiene— y te pide confirmación. Después:

1. **Snapshot** del estado actual: qué corría en pm2, qué autostart había, a qué apuntaba el túnel
2. **Backup** comprimido de la versión anterior, más uno de `/etc/cloudflared`
3. **Hereda** el secret de Verkada y el puerto del `.env` viejo
4. Instala dependencias y verifica sintaxis
5. **Detiene** la versión anterior — la detiene, no la borra
6. Levanta la nueva
7. **Verifica** de punta a punta, incluido que el túnel siga respondiendo

Si algo falla en cualquier punto, **vuelve solo al estado anterior**. No te deja el sitio caído.

## 4. Verificar

```bash
./sentinel status
./sentinel diagnose webhook
```

Y desde cualquier navegador: `https://sentinel.ihtechlabs.com/backoffice/`

Qué mirar:

- El video de fondo del kiosko va fluido
- El tablero muestra la cámara y la telemetría se actualiza
- Una llamada funciona en los dos sentidos
- Una alarma real de Verkada llega y suena

## 5. Reiniciar

```bash
sudo reboot
```

Para validar que todo arranca solo.

---

## Volver atrás

```bash
./deploy.sh --rollback
```

Un comando. Lee el snapshot y restaura exactamente lo que había:

- Apaga la versión nueva y libera el puerto
- Restaura el autostart del kiosko tal cual estaba
- Vuelve a levantar `sentinel-server`
- Verifica que responda, local y por el túnel

Se puede correr en cualquier momento, también días después. El túnel no se tocó, así que sigue sirviendo igual.

Si el rollback no logra levantar la versión anterior, te lo dice y te deja los comandos para revisar a mano. El backup completo está en `~/sentinel-backup-<fecha>.tar.gz`.

---

## Limpiar, cuando estés seguro

**Sólo después de confirmar que todo anda.** Después de esto el rollback deja de estar disponible.

```bash
./cleanup_old.sh --list    # ver qué hay, sin borrar nada
./cleanup_old.sh           # limpiar, preguntando cada cosa
```

Antes de ofrecer nada, verifica que la versión nueva esté sana: servicio online, servidor respondiendo y túnel funcionando desde internet. **Si algo de eso falla, se niega a limpiar** — borrar la vieja con la nueva rota te deja sin nada.

Después va preguntando de a una:

- Quitar el servicio pm2 `sentinel-server`
- Borrar la carpeta de la versión anterior *(pide escribir `BORRAR`)*
- Borrar autostart viejos archivados
- **Borrar túneles que sobren**
- Borrar los backups

### Sobre los túneles

El túnel que usa el equipo **está protegido**: ni siquiera aparece como opción. Sólo se ofrecen los demás.

Para cada uno te dice si tiene conexiones activas —lo que significa que otro equipo lo está usando y borrarlo lo dejaría sin webhook— y para confirmar hay que **escribir el nombre completo del túnel**. No alcanza con un "sí".

Si sólo querés esa parte:

```bash
./cleanup_old.sh --tunnels
```

Después de borrar un túnel, acordate de sacar el CNAME huérfano en [dash.cloudflare.com](https://dash.cloudflare.com) → `ihtechlabs.com` → **DNS → Records**. El borrado del túnel no lo saca solo.

---

## Qué queda en disco

```
~/sentinel-backup-<fecha>.tar.gz          versión anterior comprimida
~/cloudflared-backup-<fecha>.tar.gz       config del túnel
~/sentinel-deploy-<equipo>-<fecha>.txt    reporte con versiones y verificaciones
~/sentinel-deploy-<fecha>.log             log completo de la migración
<carpeta-nueva>/.snapshot/                estado para el rollback
```

El reporte enmascara las credenciales RTSP, así que se puede archivar o compartir.

---

## Deploy remoto por SSH

Todo queda logueado. Si se corta la conexión:

```bash
tail -f ~/sentinel-deploy-*.log
```

El snapshot vive en disco, así que `./deploy.sh --rollback` funciona aunque el SSH se haya caído a mitad de camino.

Para traerte el reporte:

```bash
scp usuario@ip:~/sentinel-deploy-*.txt .
```

---

## Resumen

```bash
./deploy.sh --check       # ¿se puede? No toca nada
./deploy.sh               # migrar (vuelve solo si falla)
./deploy.sh --rollback    # volver atrás
./cleanup_old.sh --list   # ver qué quedó para limpiar
./cleanup_old.sh          # limpiar, cuando estés seguro
```
