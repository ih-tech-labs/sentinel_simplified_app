# Migrar Costa Esmeralda

Para la Raspberry que ya tiene la versión anterior corriendo con el túnel `sentinel.ihtechlabs.com`.

**El túnel no se toca.** El script lo detecta, lo conserva y verifica que siga funcionando después de migrar. La URL del webhook en Verkada sigue siendo la misma.

---

## Antes de empezar

Copiá el proyecto nuevo a la Pi, **sin pisar** la instalación actual:

```bash
cd ~
git clone <repo> sentinel-nuevo      # o scp / USB
cd sentinel-nuevo
chmod +x *.sh sentinel
```

El script busca la instalación anterior en las rutas habituales
(`~/sentinel_simplified_app`, la carpeta de arriba, etc.). Si está en otro
lado, se lo decís:

```bash
./deploy.sh --old-dir ~/ruta/a/la/vieja
```

---

## Paso a paso

### 1. Simular

```bash
./deploy.sh --dry-run
```

No toca nada: verifica requisitos, detecta la instalación anterior y el túnel, instala dependencias y chequea la sintaxis. Si algo falta, te enterás sin haber tocado el sitio.

### 2. Migrar

```bash
./deploy.sh
```

Ocho pasos:

1. Verifica requisitos y detecta la versión anterior y el túnel
2. Backup completo con fecha (más uno de `/etc/cloudflared`)
3. Hereda el `.env`: el shared secret de Verkada y el puerto
4. Instala dependencias y verifica sintaxis
5. Detiene la versión anterior — la **detiene**, no la borra
6. Levanta la nueva
7. Verifica de punta a punta, incluido el túnel
8. Fija la nueva como definitiva

**Si algo falla en el paso 7, vuelve sola a la versión anterior.** No te deja el sitio caído.

### 3. Verificar

```bash
sentinel status
```

Y desde cualquier navegador:

```
https://sentinel.ihtechlabs.com/backoffice/
```

Usuario `Bunker`. La contraseña es la de siempre si heredaste el `.env`; si no, la que puso el instalador.

### 4. Reiniciar

```bash
sudo reboot
```

Al volver: kiosko a pantalla completa y backoffice accesible.

---

## Qué mirar después

**Kiosko** — el video de fondo tiene que ir fluido, sin tirones. Era el problema principal.

**Backoffice** — se ve la cámara, la telemetría (CPU, temperatura, RAM) se actualiza sola, el badge del puesto dice ONLINE.

**Llamada** — "LLAMAR" abre la llamada, se escucha en los dos sentidos, apagar la cámara muestra el avatar en el kiosko.

**Alarma de prueba** — el botón 🔔 dispara una y aparece en el registro. Recargá con F5: el evento tiene que seguir ahí. Antes se perdía.

**Rendimiento** — con el backoffice cerrado, `sentinel status` debería mostrar CPU bajo. Al abrirlo arranca ffmpeg y sube; al cerrarlo, a los 25 segundos vuelve a bajar.

**Verkada** — disparar una alarma real y confirmar que llega.

---

## Si algo se ve mal

```bash
./deploy.sh --rollback
```

Detiene la nueva, restaura el autostart anterior, levanta la vieja y verifica que responda. Los kioskos se reconectan solos en unos segundos.

Se puede correr en cualquier momento, también días después. El backup queda en `~/sentinel-backup-<fecha>.tar.gz`.

---

## Qué queda después

```
~/sentinel-backup-<fecha>.tar.gz         backup de la versión anterior
~/cloudflared-backup-<fecha>.tar.gz      backup del túnel
~/sentinel-deploy-<equipo>-<fecha>.txt   reporte del deploy
~/sentinel-deploy-<fecha>.log            log completo
~/sentinel_simplified_app/               versión anterior, intacta
```

La carpeta de la versión anterior **no se borra**. Cuando estés seguro, la borrás vos.

---

## Deploy remoto por SSH

El script loguea todo a `~/sentinel-deploy-<fecha>.log`, así que si se corta la conexión podés reconectarte y ver qué pasó:

```bash
tail -f ~/sentinel-deploy-*.log
```

Si el corte fue justo durante la migración, el estado queda en `.deploy_state` y `./deploy.sh --rollback` sigue funcionando.

Para traerte el reporte:

```bash
scp usuario@ip:~/sentinel-deploy-*.txt .
```

---

## Diferencias con la versión anterior

**El túnel se conserva.** El instalador viejo hacía "destruir y recrear" sobre un túnel de nombre fijo. `deploy.sh` no lo toca: lo detecta, lo hereda y verifica que siga andando.

**Los puertos 9998 y 9999 dejan de usarse.** El video ahora va por el 3000, dentro del túnel. Eso significa que el backoffice funciona remoto: antes las cámaras sólo se veían desde la LAN.

**Las alarmas se persisten.** Antes se perdían al recargar la página.

**El servicio se llama `sentinel`**, no `sentinel-server`. El script lo reemplaza en pm2; el viejo queda detenido hasta el paso 8, para que el rollback pueda revivirlo.
