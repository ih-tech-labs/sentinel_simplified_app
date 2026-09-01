/*
 * =============================================================================
 *  Sentinel · firmware de la torre de luces
 *  Placa: Arduino Uno/Nano · LEDs: PCA9685 por I2C · Sirena/Emergencia: relés
 * =============================================================================
 *
 *  PROTOCOLO (el mismo que habla scripts/gpio_daemon.py, a 9600 baudios):
 *
 *      RX <- "R,G,B,W,WW,EFFECT,ARG1,ARG2\n"
 *      TX -> "OK R,G,B,W,WW,EFFECT,ARG1,ARG2\n"   (eco normalizado)
 *            "ERR <motivo>\n"
 *
 *  Canales 0..255:  R,G,B  color · W blanco frío · WW blanco cálido
 *  EFFECT:
 *      0  estático        color fijo (con transición suave)
 *      1  sirena          relé de sirena ON + destello alternado frente/atrás
 *      2  emergencia      relé de luz de emergencia ON + color fijo
 *      3  respiración     el color respira (ARG1 = período en décimas de seg)
 *      4  pulso           latido con flash (ARG1 = período en décimas de seg)
 *  ARG1/ARG2: -1 o 0 = valor por defecto.
 *
 *  Un frame con EFFECT distinto de 1 apaga la sirena; distinto de 2 apaga la
 *  luz de emergencia. "0,0,0,0,0,0,0,0" apaga absolutamente todo.
 *
 *  HARDWARE (ajustar en la sección CONFIG):
 *    - PCA9685: dirección autodetectada al arrancar (o fijarla en PCA_ADDR).
 *      Frente: canales W=0 B=1 G=2 R=3 WW=8 · Atrás: W=4 B=5 G=6 R=7 WW=9
 *    - OE del PCA9685 en el pin 10 (activo bajo).
 *    - Relé de sirena en el pin 7, relé de emergencia en el pin 12.
 *
 *  Al arrancar imprime una línea de estado: se ve con `sentinel gpio monitor`.
 * =============================================================================
 */

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_PWMServoDriver.h>

// ----------------------------- CONFIG ---------------------------------------
#define PCA_ADDR        0x00   // 0x00 = autodetectar; o fijar p.ej. 0x40 / 0x55
#define PIN_OE          10     // Output Enable del PCA9685 (activo bajo)
#define PIN_SIREN       7      // relé de la sirena
#define PIN_EMERGENCY   12     // relé de la luz de emergencia
#define RELAY_ACTIVE_HIGH 1    // 1: relé activa con HIGH · 0: activa con LOW

// Mapa de canales del PCA9685 (-1 = ese canal no está cableado)
const int8_t CH_FRONT_R = 3, CH_FRONT_G = 2, CH_FRONT_B = 1, CH_FRONT_W = 0, CH_FRONT_WW = 8;
const int8_t CH_REAR_R  = 7, CH_REAR_G  = 6, CH_REAR_B  = 5, CH_REAR_W  = 4, CH_REAR_WW  = 9;

const unsigned long DEFAULT_BREATH_MS = 1800;
const unsigned long DEFAULT_PULSE_MS  = 2000;
const unsigned long SIREN_FLASH_MS    = 250;   // medio ciclo del destello
// -----------------------------------------------------------------------------

Adafruit_PWMServoDriver *pwm = NULL;
uint8_t pcaAddr = 0;
bool pcaOk = false;

// Estado pedido por el último frame
int targetR = 0, targetG = 0, targetB = 0, targetW = 0, targetWW = 0;
int effect = 0;
unsigned long effectPeriodMs = DEFAULT_BREATH_MS;

// Transición suave para el modo estático
float curR = 0, curG = 0, curB = 0, curW = 0, curWW = 0;

unsigned long lastLedUpdate = 0;
const unsigned long LED_INTERVAL_MS = 16;   // ~60 fps

// Buffer de recepción serie, SIN bloquear el loop
char rxBuf[64];
uint8_t rxLen = 0;

// -----------------------------------------------------------------------------
// PCA9685
// -----------------------------------------------------------------------------

bool i2cPresent(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

void initPca() {
  Wire.begin();
  if (PCA_ADDR != 0x00) {
    pcaAddr = PCA_ADDR;
  } else {
    // Autodetección: el PCA9685 vive entre 0x40 y 0x7B según sus jumpers.
    for (uint8_t a = 0x40; a <= 0x7B; a++) {
      if (a == 0x70) continue;           // 0x70 = all-call del PCA, no es real
      if (i2cPresent(a)) { pcaAddr = a; break; }
    }
  }
  if (pcaAddr && i2cPresent(pcaAddr)) {
    pwm = new Adafruit_PWMServoDriver(pcaAddr);
    pwm->begin();
    pwm->setPWMFreq(1000);               // alto para que no parpadee en cámara
    pcaOk = true;
  }
}

void setChannel(int8_t ch, int value255) {
  if (!pcaOk || ch < 0) return;
  uint16_t v = map(constrain(value255, 0, 255), 0, 255, 0, 4095);
  pwm->setPWM(ch, 0, v);
}

void writeLeds(int r, int g, int b, int w, int ww) {
  setChannel(CH_FRONT_R, r); setChannel(CH_FRONT_G, g); setChannel(CH_FRONT_B, b);
  setChannel(CH_FRONT_W, w); setChannel(CH_FRONT_WW, ww);
  setChannel(CH_REAR_R, r);  setChannel(CH_REAR_G, g);  setChannel(CH_REAR_B, b);
  setChannel(CH_REAR_W, w);  setChannel(CH_REAR_WW, ww);
}

// Sirena: frente y atrás alternados, estilo baliza
void writeLedsAlternating(int r, int g, int b, int w, int ww, bool frontOn) {
  setChannel(CH_FRONT_R, frontOn ? r : 0); setChannel(CH_FRONT_G, frontOn ? g : 0);
  setChannel(CH_FRONT_B, frontOn ? b : 0); setChannel(CH_FRONT_W, frontOn ? w : 0);
  setChannel(CH_FRONT_WW, frontOn ? ww : 0);
  setChannel(CH_REAR_R, frontOn ? 0 : r);  setChannel(CH_REAR_G, frontOn ? 0 : g);
  setChannel(CH_REAR_B, frontOn ? 0 : b);  setChannel(CH_REAR_W, frontOn ? 0 : w);
  setChannel(CH_REAR_WW, frontOn ? 0 : ww);
}

// -----------------------------------------------------------------------------
// Relés
// -----------------------------------------------------------------------------

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

  // ARG1 = período en décimas de segundo para respiración/pulso
  long arg1 = v[6];
  if (effect == 3) effectPeriodMs = (arg1 > 0) ? (unsigned long)arg1 * 100UL : DEFAULT_BREATH_MS;
  if (effect == 4) effectPeriodMs = (arg1 > 0) ? (unsigned long)arg1 * 100UL : DEFAULT_PULSE_MS;

  setRelay(PIN_SIREN, effect == 1);
  setRelay(PIN_EMERGENCY, effect == 2);
}

// Devuelve true si la línea era un frame válido
bool parseLine(char *line) {
  long v[8];
  uint8_t n = 0;
  char *tok = strtok(line, ",");
  while (tok != NULL && n < 8) {
    char *end;
    long val = strtol(tok, &end, 10);
    if (end == tok) return false;        // no era un número
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

// Acumula bytes sin bloquear; procesa al ver '\n'
void pollSerial() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (rxLen == 0) continue;
      rxBuf[rxLen] = '\0';
      rxLen = 0;
      if (!parseLine(rxBuf)) {
        Serial.println(F("ERR formato invalido (R,G,B,W,WW,EFFECT,ARG1,ARG2)"));
      }
    } else if (rxLen < sizeof(rxBuf) - 1) {
      rxBuf[rxLen++] = c;
    } else {
      rxLen = 0;                          // línea demasiado larga: descartar
      Serial.println(F("ERR linea demasiado larga"));
    }
  }
}

// -----------------------------------------------------------------------------
// Efectos
// -----------------------------------------------------------------------------

void updateLeds() {
  unsigned long now = millis();

  switch (effect) {

    case 1: {  // sirena: destello alternado frente/atrás
      bool frontOn = (now / SIREN_FLASH_MS) % 2 == 0;
      writeLedsAlternating(targetR, targetG, targetB, targetW, targetWW, frontOn);
      curR = targetR; curG = targetG; curB = targetB; curW = targetW; curWW = targetWW;
      break;
    }

    case 3: {  // respiración
      float phase = (float)(now % effectPeriodMs) / (float)effectPeriodMs * TWO_PI;
      float f = 0.12 + 0.88 * (0.5 * (1.0 + sin(phase)));
      writeLeds((int)(targetR * f), (int)(targetG * f), (int)(targetB * f),
                (int)(targetW * f), (int)(targetWW * f));
      curR = targetR; curG = targetG; curB = targetB; curW = targetW; curWW = targetWW;
      break;
    }

    case 4: {  // pulso: latido con pico
      float phase = (float)(now % effectPeriodMs) / (float)effectPeriodMs;
      float val = 0.5 * (1.0 + sin(phase * TWO_PI - PI / 2.0));
      float f = 0.1 + 0.9 * pow(val, 4.0);
      writeLeds((int)(targetR * f), (int)(targetG * f), (int)(targetB * f),
                (int)(targetW * f), (int)(targetWW * f));
      curR = targetR; curG = targetG; curB = targetB; curW = targetW; curWW = targetWW;
      break;
    }

    default: {  // estático (y emergencia): transición suave hacia el target
      curR += (targetR - curR) * 0.15; if (fabs(curR - targetR) < 0.5) curR = targetR;
      curG += (targetG - curG) * 0.15; if (fabs(curG - targetG) < 0.5) curG = targetG;
      curB += (targetB - curB) * 0.15; if (fabs(curB - targetB) < 0.5) curB = targetB;
      curW += (targetW - curW) * 0.15; if (fabs(curW - targetW) < 0.5) curW = targetW;
      curWW += (targetWW - curWW) * 0.15; if (fabs(curWW - targetWW) < 0.5) curWW = targetWW;
      writeLeds((int)curR, (int)curG, (int)curB, (int)curW, (int)curWW);
      break;
    }
  }
}

// -----------------------------------------------------------------------------

void setup() {
  Serial.begin(9600);                     // MISMO baudrate que gpio_daemon.py

  pinMode(PIN_SIREN, OUTPUT);
  pinMode(PIN_EMERGENCY, OUTPUT);
  setRelay(PIN_SIREN, false);
  setRelay(PIN_EMERGENCY, false);

  pinMode(PIN_OE, OUTPUT);
  digitalWrite(PIN_OE, LOW);              // habilita salidas del PCA9685

  pinMode(LED_BUILTIN, OUTPUT);

  initPca();
  writeLeds(0, 0, 0, 0, 0);               // arrancar todo apagado

  // Línea de arranque: se ve como RX en `sentinel gpio monitor`
  Serial.print(F("SENTINEL-LIGHTS v1.0 pca9685="));
  if (pcaOk) { Serial.print(F("0x")); Serial.print(pcaAddr, HEX); }
  else Serial.print(F("NO_DETECTADO"));
  Serial.println();

  digitalWrite(LED_BUILTIN, HIGH); delay(120); digitalWrite(LED_BUILTIN, LOW);
}

void loop() {
  pollSerial();

  unsigned long now = millis();
  if (now - lastLedUpdate >= LED_INTERVAL_MS) {
    lastLedUpdate = now;
    updateLeds();
    // Latido del LED de placa: prendido si hay algún color activo
    digitalWrite(LED_BUILTIN, (targetR | targetG | targetB | targetW | targetWW) ? HIGH : LOW);
  }
}
