// M7 spike: I2C (TWI) traffic — a protocol bus trace, not a device.
// Writes two bytes to address 0x27 every 500 ms. The harness has no device on the
// bus: it ACKs so the transaction completes and records it, so `run_firmware`
// should report an I2C transaction to 0x27 with data [0x00, 0x41].
#include <Wire.h>

void setup() {
  Wire.begin();
  Serial.begin(9600);
}

void loop() {
  Wire.beginTransmission(0x27);
  Wire.write(0x00);
  Wire.write(0x41);
  byte err = Wire.endTransmission();
  Serial.print("i2c err ");
  Serial.println(err);
  delay(500);
}
