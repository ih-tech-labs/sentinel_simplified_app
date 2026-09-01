# Firmware de la torre de luces

Sketch del Arduino que controla los LEDs (PCA9685 por I2C), la **sirena** y la
**luz de emergencia** (relés). Habla el mismo protocolo serie que
`scripts/gpio_daemon.py`, a **9600 baudios**:

```
RX <- "R,G,B,W,WW,EFFECT,ARG1,ARG2\n"
TX -> "OK <frame normalizado>"  |  "ERR <motivo>"
```

| EFFECT | Comportamiento |
|---|---|
| 0 | color estático (transición suave) |
| 1 | **sirena**: relé ON + destello alternado frente/atrás |
| 2 | **emergencia**: relé ON + color fijo |
| 3 | respiración (ARG1 = período en décimas de segundo) |
| 4 | pulso con pico (ARG1 = período en décimas de segundo) |

Un frame con EFFECT ≠ 1 apaga la sirena; con EFFECT ≠ 2 apaga la emergencia.
`0,0,0,0,0,0,0,0` apaga todo. Al arrancar imprime `SENTINEL-LIGHTS v1.0` con
la dirección I2C detectada del PCA9685 (visible en `sentinel gpio monitor`).

## Hardware (ajustable arriba del .ino)

- **PCA9685**: dirección autodetectada (0x40–0x7B). Frente: canales W=0 B=1
  G=2 R=3 WW=8 · Atrás: W=4 B=5 G=6 R=7 WW=9. OE en el pin 10.
- **Relés**: sirena en pin 7, luz de emergencia en pin 12 (activos en HIGH,
  cambiar `RELAY_ACTIVE_HIGH` si el módulo de relés es activo-bajo).

## Grabar

En la Raspberry Pi, con el Arduino por USB:

```bash
cd ~/sentinel/firmware
./flash.sh                    # Arduino Uno
./flash.sh --board nano-old   # Nano clon con bootloader viejo
```

El script instala `arduino-cli` si falta, detiene el daemon (que tiene tomado
el puerto), compila, graba y vuelve a levantar todo. Después: `./sentinel gpio test`.

También se puede abrir `sentinel_lights/sentinel_lights.ino` en el Arduino IDE
de Windows (instalar la librería *Adafruit PWM Servo Driver Library*) y grabar
desde ahí.
