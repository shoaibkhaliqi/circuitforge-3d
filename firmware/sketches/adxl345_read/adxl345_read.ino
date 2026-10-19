// M8 device spike: read an ADXL345 accelerometer over I2C with no external library.
// DEVID identifies the part, DATA_FORMAT picks the range (this sketch asks for 10-bit
// mode at +/-4 g, i.e. 128 LSB/g, so the range logic is exercised), then a 6-byte burst
// from 0x32 returns the three little-endian axis counts. The harness serves a register
// file whose g values come from its parameters and whose counts follow the scale the
// sketch itself selected, so the sketch reads a real (stimulus-driven) accelerometer.
#include <Wire.h>

#define ADXL_ADDR        0x53
#define REG_DEVID        0x00
#define REG_BW_RATE      0x2C
#define REG_POWER_CTL    0x2D
#define REG_DATA_FORMAT  0x31
#define REG_DATA         0x32

// 10-bit mode (+/-4 g) -> 128 LSB/g; FULL_RES (bit 3) would be 3.9 mg/LSB at every range.
#define DATA_FORMAT_4G   0x01
#define MG_PER_LSB_NUM   1000L   // milli-g per g
#define LSB_PER_G        128L

static void writeReg(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(ADXL_ADDR);
  Wire.write(reg);
  Wire.write(value);
  Wire.endTransmission();
}

static void readRegs(uint8_t reg, uint8_t *out, uint8_t n) {
  Wire.beginTransmission(ADXL_ADDR);
  Wire.write(reg);
  Wire.endTransmission(false);
  Wire.requestFrom((uint8_t)ADXL_ADDR, n);
  for (uint8_t i = 0; i < n; i++) out[i] = Wire.read();
}

void setup() {
  Serial.begin(9600);
  Wire.begin();

  uint8_t who = 0xFF;
  readRegs(REG_DEVID, &who, 1);

  writeReg(REG_BW_RATE, 0x0A);            // 100 Hz output data rate
  writeReg(REG_DATA_FORMAT, DATA_FORMAT_4G);
  writeReg(REG_POWER_CTL, 0x08);          // measure

  uint8_t fmt = 0, pwr = 0;
  readRegs(REG_DATA_FORMAT, &fmt, 1);     // read back what we just wrote
  readRegs(REG_POWER_CTL, &pwr, 1);

  uint8_t d[6];
  readRegs(REG_DATA, d, 6);
  int16_t ax = (int16_t)((d[1] << 8) | d[0]);
  int16_t ay = (int16_t)((d[3] << 8) | d[2]);
  int16_t az = (int16_t)((d[5] << 8) | d[4]);

  Serial.print("devid 0x");
  Serial.print(who, HEX);
  Serial.print(" fmt 0x");
  Serial.print(fmt, HEX);
  Serial.print(" pwr 0x");
  Serial.print(pwr, HEX);
  Serial.print(" ax "); Serial.print(ax);
  Serial.print(" ay "); Serial.print(ay);
  Serial.print(" az "); Serial.print(az);
  Serial.print(" mg ");                   // counts -> milli-g for the selected scale
  Serial.print((long)ax * MG_PER_LSB_NUM / LSB_PER_G); Serial.print(" ");
  Serial.print((long)ay * MG_PER_LSB_NUM / LSB_PER_G); Serial.print(" ");
  Serial.println((long)az * MG_PER_LSB_NUM / LSB_PER_G);
}

void loop() {
}
