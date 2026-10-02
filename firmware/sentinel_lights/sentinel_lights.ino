/*
 * =============================================================================
 *  Sentinel · firmware de la torre de luces  ·  ARDUINO DIRECTO (sin PCA9685)
 *  Placa: Arduino Uno/Nano · LEDs por transistores en pines PWM del Arduino
 * =============================================================================
 *
 *  PROTOCOLO (el mismo que habla scripts/gpio_daemon.py, a 9600 baudios):
 *
 *      RX <- "R,G,B,W,WW,EFFECT,ARG1,ARG2\n"
 *      TX -> "OK <frame normalizado>"  |  "ERR <motivo>"
 *
 *  Canales 0..255:  R,G,B color · W blanco frío · WW blanco cálido
 *  EFFECT:
 *      0  estático        color fijo
 *      1  sirena          relé de sirena ON + color
 *      2  emergencia      luz de emergencia ON + color
 *      3  respiración     el color respira (ARG1 = período en décimas de seg)
 *      4  pulso           latido con pico (ARG1 = período en décimas de seg)
 *  ARG1/ARG2: -1 o 0 = valor por defecto.
 *
 *  Un frame con EFFECT != 1 apaga la sirena; con EFFECT != 2 apaga la
 *  emergencia. "0,0,0,0,0,0,0,0" apaga absolutamente todo.
 *
 *  CONEXIONADO (transistores que conmutan cada canal):
 *      D11 Rojo · D10 Verde · D9 Azul · D6 Blanco frío · D5 Blanco cálido
 *      D8  Luz de emergencia (on/off) · D3 Sirena (on/off)
 *  Los 5 canales de color van en pines con PWM por hardware (analogWrite).
 *  Emergencia (D8) y sirena (D3) son on/off (digitalWrite).
 *
 *  Al arrancar imprime SENTINEL-LIGHTS-DIRECT con el mapa de pines (visible en
 *  `sentinel gpio monitor`).
 * =============================================================================
 */

#include <Arduino.h>

// ----------------------------- CONFIG · PINES -------------------------------
const uint8_t PIN_R  = 11;   // Rojo        (PWM)
const uint8_t PIN_G  = 10;   // Verde       (PWM)
const uint8_t PIN_B  = 9;    // Azul        (PWM)
const uint8_t PIN_W  = 6;    // Blanco frío (PWM)
const uint8_t PIN_WW = 5;    // Blanco cálido (PWM)
const uint8_t PIN_EMERGENCY = 8;  // Luz de emergencia (on/off)
const uint8_t PIN_SIREN     = 3;  // Sirena            (on/off)

// Si por tu electrónica un transistor/relé se activa con LOW en vez de HIGH,
// poné el ACTIVE correspondiente en 0.
#define COLOR_ACTIVE_HIGH 1   // analogWrite: 255 = brillo máximo
#define RELAY_ACTIVE_HIGH 1   // digitalWrite HIGH = sirena/emergencia encendida

const unsigned long DEFAULT_BREATH_MS = 2600;
const unsigned long DEFAULT_PULSE_MS  = 2000;
const unsigned long FRAME_INTERVAL_MS = 16;   // ~60 fps para los efectos suaves
// -----------------------------------------------------------------------------

// Estado pedido por el último frame
int targetR = 0, targetG = 0, targetB = 0, targetW = 0, targetWW = 0;
int effect = 0;
unsigned long effectPeriodMs = DEFAULT_BREATH_MS;

unsigned long lastUpdate = 0;

// Buffer de recepción serie, sin bloquear
char rxBuf[64];
uint8_t rxLen = 0;

// -----------------------------------------------------------------------------
// Salida a los pines
// -----------------------------------------------------------------------------

void writeChannel(uint8_t pin, int value255) {
  value255 = constrain(value255, 0, 255);
#if !COLOR_ACTIVE_HIGH
  value255 = 255 - value255;
#endif
  analogWrite(pin, value255);
}

// Escribe los 5 canales de color escalados por un factor de brillo 0..1.
void writeColor(int r, int g, int b, int w, int ww, float factor) {
  writeChannel(PIN_R,  (int)(r  * factor + 0.5f));
  writeChannel(PIN_G,  (int)(g  * factor + 0.5f));
  writeChannel(PIN_B,  (int)(b  * factor + 0.5f));
  writeChannel(PIN_W,  (int)(w  * factor + 0.5f));
  writeChannel(PIN_WW, (int)(ww * factor + 0.5f));
}

void setRelay(uint8_t pin, bool on) {
#if RELAY_ACTIVE_HIGH
  digitalWrite(pin, on ? HIGH : LOW);
#else
  digitalWrite(pin, on ? LOW : HIGH);
#endif
}

// -----------------------------------------------------------------------------
// Parser del frame
// -----------------------------------------------------------------------------

void applyFrame(long v[8]) {
  targetR  = constrain((int)v[0], 0, 255);
  targetG  = constrain((int)v[1], 0, 255);
  targetB  = constrain((int)v[2], 0, 255);
  targetW  = constrain((int)v[3], 0, 255);
  targetWW = constrain((int)v[4], 0, 255);
  effect   = (v[5] >= 0 && v[5] <= 4) ? (int)v[5] : 0;

  long arg1 = v[6];
  if (effect == 3) effectPeriodMs = (arg1 > 0) ? (unsigned long)arg1 * 100UL : DEFAULT_BREATH_MS;
  if (effect == 4) effectPeriodMs = (arg1 > 0) ? (unsigned long)arg1 * 100UL : DEFAULT_PULSE_MS;

  setRelay(PIN_SIREN, effect == 1);
  setRelay(PIN_EMERGENCY, effect == 2);
}

bool parseLine(char *line) {
  long v[8];
  uint8_t n = 0;
  char *tok = strtok(line, ",");
  while (tok != NULL && n < 8) {
    char *end;
    long val = strtol(tok, &end, 10);
    if (end == tok) return false;
    v[n++] = val;
    tok = strtok(NULL, ",");
  }
  if (n != 8 || tok != NULL) return false;

  applyFrame(v);

  Serial.print(F("OK "));
  Serial.print(targetR); Serial.print(',');
  Serial.print(targetG); Serial.print(',');
  Serial.print(targetB); Serial.print(',');
  Serial.print(targetW); Serial.print(',');
  Serial.print(targetWW); Serial.print(',');
  Serial.print(effect); Serial.print(',');
  Serial.print((long)(effectPeriodMs / 100)); Serial.println(",0");
  return true;
}

void pollSerial() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (rxLen == 0) continue;
      rxBuf[rxLen] = '\0';
      rxLen = 0;
      if (!parseLine(rxBuf)) Serial.println(F("ERR formato invalido (R,G,B,W,WW,EFFECT,ARG1,ARG2)"));
    } else if (rxLen < sizeof(rxBuf) - 1) {
      rxBuf[rxLen++] = c;
    } else {
      rxLen = 0;
      Serial.println(F("ERR linea demasiado larga"));
    }
  }
}

// -----------------------------------------------------------------------------
// Efectos (se refrescan a ~60 fps desde loop)
// -----------------------------------------------------------------------------

void updateLeds() {
  unsigned long now = millis();

  switch (effect) {
    case 3: {  // respiración: 60fps + gamma ~2 para suavizar los pasos de 8 bits
      float phase = (float)(now % effectPeriodMs) / (float)effectPeriodMs * TWO_PI;
      float lin = 0.5 * (1.0 + sin(phase));   // 0..1
      float g = lin * lin;                     // gamma ~2.0 (brillo perceptual)
      float f = 0.02 + 0.98 * g;               // nunca negro total
      writeColor(targetR, targetG, targetB, targetW, targetWW, f);
      break;
    }
    case 4: {  // pulso: latido con pico
      float phase = (float)(now % effectPeriodMs) / (float)effectPeriodMs;
      float val = 0.5 * (1.0 + sin(phase * TWO_PI - PI / 2.0));
      float f = 0.1 + 0.9 * pow(val, 4.0);
      writeColor(targetR, targetG, targetB, targetW, targetWW, f);
      break;
    }
    default: {  // 0 estático, 1 sirena, 2 emergencia: color fijo
      writeColor(targetR, targetG, targetB, targetW, targetWW, 1.0);
      break;
    }
  }
}

// -----------------------------------------------------------------------------

void setup() {
  Serial.begin(9600);                 // MISMO baudrate que gpio_daemon.py

  pinMode(PIN_R, OUTPUT);  pinMode(PIN_G, OUTPUT);  pinMode(PIN_B, OUTPUT);
  pinMode(PIN_W, OUTPUT);  pinMode(PIN_WW, OUTPUT);
  pinMode(PIN_EMERGENCY, OUTPUT);
  pinMode(PIN_SIREN, OUTPUT);
  pinMode(LED_BUILTIN, OUTPUT);

  setRelay(PIN_SIREN, false);
  setRelay(PIN_EMERGENCY, false);
  writeColor(0, 0, 0, 0, 0, 1.0);     // arrancar todo apagado

  Serial.println(F("SENTINEL-LIGHTS-DIRECT v1.0 pins R11 G10 B9 W6 WW5 EMG8 SIREN3"));

  digitalWrite(LED_BUILTIN, HIGH); delay(120); digitalWrite(LED_BUILTIN, LOW);
}

void loop() {
  pollSerial();

  unsigned long now = millis();
  if (now - lastUpdate >= FRAME_INTERVAL_MS) {
    lastUpdate = now;
    updateLeds();
    digitalWrite(LED_BUILTIN, (targetR | targetG | targetB | targetW | targetWW) ? HIGH : LOW);
  }
}
