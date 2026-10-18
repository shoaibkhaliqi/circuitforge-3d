// M7/M8 capstone example: a firmware environment logger that ties two device families
// together in one sketch — a DHT22 one-wire temperature/humidity sensor and a 16x2 HD44780
// LCD behind a PCF8574 I2C backpack — using hand-written drivers only (no libraries).
// The harness answers the sensor and decodes the LCD, so both sides are checked.
//
// Circuit (data/examples/15_firmware_env_logger.cf3d):
//   DHT22 DATA -> D2 (through an mcu_pin), LCD SDA/SCL -> A4/A5, both module VCC/GND.
#include <Wire.h>

#define DHT_PIN 2
#define DHT_TIMEOUT_US 600

#define LCD_ADDR 0x27
#define LCD_RS 0x01
#define LCD_EN 0x04
#define LCD_BL 0x08

// ---- HD44780 over a PCF8574 backpack (4-bit mode) -------------------------------
void expanderWrite(uint8_t v) {
  Wire.beginTransmission(LCD_ADDR);
  Wire.write(v | LCD_BL);
  Wire.endTransmission();
}

void write4bits(uint8_t nib) {
  expanderWrite(nib);
  expanderWrite(nib | LCD_EN);
  expanderWrite(nib & ~LCD_EN);
}

void lcdSend(uint8_t value, uint8_t mode) {
  write4bits(((value >> 4) & 0x0F) << 4 | mode);
  write4bits((value & 0x0F) << 4 | mode);
}

void lcdCommand(uint8_t c) { lcdSend(c, 0); }
void lcdData(uint8_t d) { lcdSend(d, LCD_RS); }
void lcdPrint(const char *s) { while (*s) lcdData((uint8_t)*s++); }

void lcdInit() {
  delay(50);
  write4bits(0x30);
  write4bits(0x30);
  write4bits(0x30);
  write4bits(0x20);
  lcdCommand(0x28);
  lcdCommand(0x0C);
  lcdCommand(0x06);
  lcdCommand(0x01);
  delay(2);
}

// ---- DHT one-wire driver --------------------------------------------------------
static uint8_t dhtWait(uint8_t pin, uint8_t level, uint8_t *ok) {
  unsigned long t0 = micros();
  while (digitalRead(pin) == level) {
    if (micros() - t0 > DHT_TIMEOUT_US) {
      *ok = 0;
      return 0;
    }
  }
  return 1;
}

static uint8_t dhtRead(uint8_t pin, uint8_t *data) {
  for (uint8_t i = 0; i < 5; i++) data[i] = 0;

  pinMode(pin, OUTPUT);
  digitalWrite(pin, LOW);
  delay(2);
  digitalWrite(pin, HIGH);
  pinMode(pin, INPUT);

  uint8_t ok = 1;
  dhtWait(pin, HIGH, &ok);
  dhtWait(pin, LOW, &ok);
  if (!ok) return 0;

  for (uint8_t i = 0; i < 40; i++) {
    dhtWait(pin, HIGH, &ok);
    dhtWait(pin, LOW, &ok);
    if (!ok) return 0;
    unsigned long t0 = micros();
    dhtWait(pin, HIGH, &ok);
    unsigned long width = micros() - t0;
    if (!ok) return 0;
    data[i >> 3] = (uint8_t)((data[i >> 3] << 1) | (width > 40 ? 1 : 0));
  }
  return 1;
}

// ---- Report formatting ----------------------------------------------------------
static uint8_t appendInt(char *b, uint8_t pos, uint16_t v) {
  char tmp[5];
  uint8_t n = 0;
  do {
    tmp[n++] = (char)('0' + (v % 10));
    v /= 10;
  } while (v);
  while (n) b[pos++] = tmp[--n];
  return pos;
}

void setup() {
  Serial.begin(9600);
  Wire.begin();
  lcdInit();
  lcdCommand(0x80);
  lcdPrint("CircuitForge");
  lcdCommand(0xC0);
  lcdPrint("logger ready");
  delay(120);

  uint8_t d[5];
  if (!dhtRead(DHT_PIN, d)) {
    lcdCommand(0x01);
    delay(2);
    lcdCommand(0x80);
    lcdPrint("sensor error");
    Serial.println("env error");
    return;
  }

  uint8_t sum = (uint8_t)(d[0] + d[1] + d[2] + d[3]);
  int16_t h = (int16_t)((d[0] << 8) | d[1]);
  int16_t t = (int16_t)((d[2] << 8) | d[3]);
  uint8_t neg = (t & 0x8000) != 0;
  if (neg) t = (int16_t)(t & 0x7FFF);

  char line[17];
  uint8_t pos = 0;
  line[pos++] = 'T';
  line[pos++] = '=';
  if (neg) line[pos++] = '-';
  pos = appendInt(line, pos, (uint16_t)(t / 10));
  line[pos++] = '.';
  line[pos++] = (char)('0' + (t % 10));
  line[pos++] = 'C';
  line[pos++] = ' ';
  line[pos++] = 'H';
  line[pos++] = '=';
  pos = appendInt(line, pos, (uint16_t)(h / 10));
  line[pos++] = '.';
  line[pos++] = (char)('0' + (h % 10));
  line[pos++] = '%';
  line[pos] = 0;

  lcdCommand(0x01);
  delay(2);
  lcdCommand(0x80);
  lcdPrint(line);
  lcdCommand(0xC0);
  lcdPrint(sum == d[4] ? "checksum ok" : "checksum BAD");

  Serial.print("env ");
  Serial.println(line);
}

void loop() {
}
