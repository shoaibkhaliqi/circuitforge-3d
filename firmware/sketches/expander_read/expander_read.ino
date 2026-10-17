// M7 closed-loop spike: READ from a device on the I2C bus.
// Drives the PCF8574's port high (weak pull-ups on) and reads one byte back, then
// prints it. The harness serves the device (see CF_DEVICES): with inputs = 0x0F
// (P0..P3 externally held low) the read is 0xFF & ~0x0F = 0xF0 = 240, so Serial
// prints "port 240". This proves device -> firmware feedback, not just a trace.
#include <Wire.h>

const byte PCF8574_ADDR = 0x27;

void setup() {
  Wire.begin();
  Serial.begin(9600);
}

void loop() {
  Wire.beginTransmission(PCF8574_ADDR);
  Wire.write(0xFF);
  Wire.endTransmission();

  Wire.requestFrom(PCF8574_ADDR, 1);
  byte value = 0;
  if (Wire.available()) {
    value = Wire.read();
  }

  Serial.print("port ");
  Serial.println(value);
  delay(500);
}
