// M7 device spike: drive a PCF8574 I2C I/O expander.
// Writes a single port byte to address 0x27 (A0..A2 tied high) every 500 ms.
// The harness records the transaction, so `apply_firmware_device` sets the device
// port byte to 0x55: P0, P2, P4, P6 high; P1, P3, P5, P7 low.
#include <Wire.h>

const byte PCF8574_ADDR = 0x27;

void setup() {
  Wire.begin();
}

void loop() {
  Wire.beginTransmission(PCF8574_ADDR);
  Wire.write(0x55);
  Wire.endTransmission();
  delay(500);
}
