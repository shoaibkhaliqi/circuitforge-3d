// M7/M8 device spike: read an MPU-6050 IMU over I2C. WHO_AM_I identifies the part,
// then a 14-byte burst from 0x3B returns accel XYZ + temperature + gyro XYZ. The
// harness serves a register file whose sample values come from its parameters, so
// the sketch reads a real (stimulus-driven) IMU.
#include <Wire.h>

#define MPU_ADDR 0x68
#define REG_ACCEL 0x3B
#define REG_PWR   0x6B
#define REG_WHO   0x75

int16_t read16() {
  int16_t v = Wire.read() << 8;
  v |= Wire.read();
  return v;
}

void setup() {
  Serial.begin(9600);
  Wire.begin();

  Wire.beginTransmission(MPU_ADDR);  // wake the part
  Wire.write(REG_PWR);
  Wire.write(0x00);
  Wire.endTransmission();

  Wire.beginTransmission(MPU_ADDR);  // WHO_AM_I (repeated start)
  Wire.write(REG_WHO);
  Wire.endTransmission(false);
  Wire.requestFrom(MPU_ADDR, 1);
  uint8_t who = Wire.read();

  Wire.beginTransmission(MPU_ADDR);  // accel + temp + gyro burst (repeated start)
  Wire.write(REG_ACCEL);
  Wire.endTransmission(false);
  Wire.requestFrom(MPU_ADDR, 14);
  int16_t ax = read16();
  int16_t ay = read16();
  int16_t az = read16();
  int16_t raw_temp = read16();
  int16_t gx = read16();
  int16_t gy = read16();
  int16_t gz = read16();

  long temp_c_x100 = (long)raw_temp * 100L / 340L + 3653L;  // TEMP_degC = raw/340 + 36.53

  Serial.print("who 0x");
  Serial.print(who, HEX);
  Serial.print(" ax "); Serial.print(ax);
  Serial.print(" ay "); Serial.print(ay);
  Serial.print(" az "); Serial.print(az);
  Serial.print(" gx "); Serial.print(gx);
  Serial.print(" gy "); Serial.print(gy);
  Serial.print(" gz "); Serial.print(gz);
  Serial.print(" temp "); Serial.println(temp_c_x100);
}

void loop() {
}
