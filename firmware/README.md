# Firmware de la torre de luces

Sketch del Arduino que controla los LEDs (por transistores en pines PWM), la
**sirena** y la **luz de emergencia**. Habla el mismo protocolo serie que
`scripts/gpio_daemon.py`, a **9600 baudios**:

```
RX <- "R,G,B,W,WW,EFFECT,ARG1,ARG2\n"
TX -> "OK <frame normalizado>"  |  "ERR <motivo>"
```

| EFFECT | Comportamiento |
|---|---|
| 0 | color estático |
| 1 | **sirena**: relé de sirena ON + color |
| 2 | **emergencia**: luz de emergencia ON + color |
| 3 | respiración (ARG1 = período en décimas de segundo) |
| 4 | pulso con pico (ARG1 = período en décimas de segundo) |

Un frame con EFFECT ≠ 1 apaga la sirena; con EFFECT ≠ 2 apaga la emergencia.
`0,0,0,0,0,0,0,0` apaga todo. Al arrancar imprime `SENTINEL-LIGHTS-DIRECT v1.0`
con el mapa de pines (visible en `sentinel gpio monitor`).

## Conexionado (Arduino directo — así están TODOS los Sentinel)

Los LEDs van por transistores que conmutan cada canal, en pines PWM del Arduino.
**No hay PCA9685.**

| Canal | Pin |
|---|---|
| Rojo | D11 |
| Verde | D10 |
| Azul | D9 |
| Blanco frío | D6 |
| Blanco cálido | D5 |
| Luz de emergencia | D8 (on/off) |
| Sirena | D3 (on/off) |

Si tu electrónica activa con LOW en vez de HIGH, cambiá `COLOR_ACTIVE_HIGH` o
`RELAY_ACTIVE_HIGH` arriba del `.ino`.

## Grabar

En la Raspberry Pi, con el Arduino por USB:

```bash
cd ~/sentinel/firmware
./flash.sh                    # Arduino Uno
./flash.sh --board nano-old   # Nano clon con bootloader viejo
```

El script instala `arduino-cli` si falta, detiene el daemon (que tiene tomado
el puerto), compila, graba y vuelve a levantar todo. Después: `./sentinel gpio test`.
