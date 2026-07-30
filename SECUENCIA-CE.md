# Costa Esmeralda · instalar de cero con vuelta atrás

Instalación limpia sobre el equipo que hoy corre la versión anterior, con túnel nuevo, y con la posibilidad de deshacer todo con un comando.

---

## Antes de arrancar: elegí el dominio

Esto define cuán limpio es el rollback.

| | |
|---|---|
| **Dominio nuevo** *(recomendado)* | `sentinel-ce.ihtechlabs.com`. El túnel viejo y su DNS quedan intactos. Rollback instantáneo y sin riesgo. |
| **Reusar** `sentinel.ihtechlabs.com` | El DNS se repunta al túnel nuevo. El rollback lo devuelve solo, pero depende de una llamada a Cloudflare que puede fallar. |

Con dominio nuevo, durante la prueba tenés **los dos accesos vivos a la vez**: el viejo sigue sirviendo por `sentinel.ihtechlabs.com` hasta que apagues su servicio. Eso lo hace mucho más cómodo de verificar.

Si vas por el dominio nuevo, en Verkada agregá un webhook adicional apuntando al nuevo en vez de cambiar el existente. Cuando confirmes, borrás el viejo.

---

## 1. Traer el código

```bash
cd ~
git clone --depth 1 git@github.com:ih-tech-labs/sentinel_simplified_app.git sentinel-nuevo
cd sentinel-nuevo
```

## 2. Instalar

```bash
./install.sh
```

Al llegar al resumen, antes de confirmar, vas a ver:

```
Este equipo ya tenía Sentinel
  · servicio pm2 'sentinel-server'
  · túnel sentinel.ihtechlabs.com
  · autostart del kiosko
  · instalación en /home/develop/sentinel_simplified_app

Se va a fotografiar todo antes de tocar nada.
Para deshacer:  ./install.sh --rollback
```

Si no ves ese bloque, **cancelá** — significa que no detectó lo anterior y no vas a tener rollback.

### Respuestas

| Pregunta | Qué poner |
|---|---|
| Nombre | `Costa Esmeralda` |
| Usuario / contraseña | Enter, o los que quieras |
| URL RTSP | La de la cámara que vayas a usar |
| device_id | El de Verkada, o Enter para cargarlo después |
| Shared secret | El mismo que ya usás |
| ¿Túnel? | `s` |
| Dominio | `sentinel-ce.ihtechlabs.com` — **no** el actual |
| Pantalla / orientación | Según el equipo |
| Arduino | `s` |

El instalador detiene `sentinel-server` pero **no lo borra**: el rollback lo revive.

## 3. Verificar

```bash
./sentinel status
./sentinel diagnose
./sentinel diagnose webhook
```

Y en el navegador: `https://sentinel-ce.ihtechlabs.com/backoffice/`

Qué mirar antes de dar el OK:

- Las cámaras que configuraste, y sólo esas
- El video de fondo del kiosko fluido
- Una llamada en los dos sentidos
- Una alarma real de Verkada llegando al registro

---

## Si sale mal

```bash
./install.sh --rollback
```

Un comando. Restaura, en este orden:

1. Apaga los servicios nuevos y libera el puerto
2. Devuelve el autostart del kiosko al original
3. Revive `sentinel-server`
4. **Restaura el túnel**: `/etc/cloudflared` completo —config, credenciales y cert— y si el DNS quedó apuntando al túnel nuevo, lo devuelve al viejo
5. Verifica que responda, local y por el dominio

Probado: con un túnel original configurado, se lo reemplaza por otro distinto, y la restauración devuelve el UUID, el dominio, las credenciales y el `cert.pem` exactos. La config del túnel nuevo queda archivada en `/etc/cloudflared.reemplazado-<fecha>`.

El túnel nuevo **sigue existiendo en tu cuenta de Cloudflare** — el rollback es local. No molesta, y lo borrás cuando quieras con `./cleanup_old.sh --tunnels`.

---

## Cuando confirmes que anda

```bash
./cleanup_old.sh --list    # ver qué quedó
./cleanup_old.sh           # limpiar, preguntando cada cosa
```

Verifica primero que la nueva esté sana y **se niega a limpiar si no lo está**. Después ofrece, de a uno:

- Quitar `sentinel-server` de pm2
- Borrar la carpeta anterior *(pide escribir `BORRAR`)*
- Borrar el túnel `sentinel` viejo *(pide escribir su nombre completo)*
- Borrar los backups

El túnel en uso está protegido: ni aparece.

Después de borrar el túnel viejo, sacá el CNAME `sentinel` en [dash.cloudflare.com](https://dash.cloudflare.com) → `ihtechlabs.com` → **DNS → Records**, y quitá el webhook viejo en Verkada.

**Desde ese momento el rollback deja de estar disponible.** No corras esto hasta estar seguro.

---

## Diferencia con `deploy.sh`

| | `install.sh` | `deploy.sh` |
|---|---|---|
| Configuración | Desde cero, con asistente | Hereda el `.env` viejo |
| Cámaras | Las que definís | Las de la config existente |
| Túnel | Crea uno nuevo | Conserva el existente |
| Rollback | `./install.sh --rollback` | `./deploy.sh --rollback` |

Los dos usan el mismo snapshot y la misma restauración. La diferencia es qué configuración termina corriendo.

Para Costa Esmeralda ahora conviene `install.sh`: la migración arrastró las dos cámaras viejas y el `.env` heredado, que es justamente lo que no querías.

---

## Resumen

```bash
cd ~/sentinel-nuevo
./install.sh                 # instalar (fotografía lo anterior)
./sentinel status            # verificar
./install.sh --rollback      # deshacer, si hace falta
./cleanup_old.sh             # limpiar, cuando estés seguro
```
