// M7/M8 device spike: read an SHT31 temperature+humidity sensor over I2C with a
// hand-written driver (no library). The sensor takes 16-bit commands (0x2400 = single
// shot, high repeatability) and answers a read with six bytes: temperature MSB/LSB +
// CRC-8, humidity MSB/LSB + CRC-8 (poly 0x31, init 0xFF). The harness serves that
// frame, so the checksum path is exercised for real.
#include <Wire.h>

#define SHT31_ADDR 0x44

static uint8_t crc8(const uint8_t *data, uint8_t len) {
  uint8_t crc = 0xFF;
  for (uint8_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (uint8_t b = 0; b < 8; b++) {
      crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x31) : (uint8_t)(crc << 1);
    }
  }
  return crc;
}

static uint8_t shtRead(uint8_t *frame) {
  Wire.beginTransmission(SHT31_ADDR);
  Wire.write(0x24);
  Wire.write(0x00);              // single shot, high repeatability, no clock stretching
  if (Wire.endTransmission() != 0) return 0;
  delay(20);                     // measurement time (the harness answers immediately)

  if (Wire.requestFrom((uint8_t)SHT31_ADDR, (uint8_t)6) != 6) return 0;
  for (uint8_t i = 0; i < 6; i++) frame[i] = (uint8_t)Wire.read();
  return 1;
}

static void printTenths(int16_t tenths) {
  if (tenths < 0) {
    Serial.print('-');
    tenths = (int16_t)-tenths;
  }
  Serial.print(tenths / 10);
  Serial.print('.');
  Serial.print(tenths % 10);
}

void setup() {
  Serial.begin(9600);
  Wire.begin();

  uint8_t f[6];
  if (!shtRead(f)) {
    Serial.println("sht31 bus error");
    return;
  }

  uint8_t t_ok = crc8(f, 2) == f[2];
  uint8_t h_ok = crc8(f + 3, 2) == f[5];
  if (!t_ok || !h_ok) {
    Serial.println("sht31 crc error");
    return;
  }

  uint16_t traw = (uint16_t)((f[0] << 8) | f[1]);
  uint16_t hraw = (uint16_t)((f[3] << 8) | f[4]);
  // T = -45 + 175 * raw / 65535 ; RH = 100 * raw / 65535, scaled to tenths.
  int16_t t10 = (int16_t)(((uint32_t)traw * 1750u + 32767u) / 65535u) - 450;
  int16_t h10 = (int16_t)(((uint32_t)hraw * 1000u + 32767u) / 65535u);

  Serial.print("sht31 t ");
  printTenths(t10);
  Serial.print(" h ");
  printTenths(h10);
  Serial.print(" ok ");
  Serial.println(t_ok && h_ok ? 1 : 0);
}

void loop() {
}
