// M7 device spike: store a byte in a 24LC256 I2C EEPROM (address 0x50) and read
// it back in the same run. The harness serves the EEPROM on the bus, so the value
// survives; Serial prints "eeprom 165".
#include <Wire.h>

#define EEPROM_ADDR 0x50
#define VALUE 0xA5

void setup() {
  Wire.begin();
  Serial.begin(9600);

  // Write VALUE at address 0x0000 (two address bytes, then data).
  Wire.beginTransmission(EEPROM_ADDR);
  Wire.write((uint8_t)0x00);
  Wire.write((uint8_t)0x00);
  Wire.write((uint8_t)VALUE);
  Wire.endTransmission();

  // Point at 0x0000 and read one byte back.
  Wire.beginTransmission(EEPROM_ADDR);
  Wire.write((uint8_t)0x00);
  Wire.write((uint8_t)0x00);
  Wire.endTransmission();
  Wire.requestFrom(EEPROM_ADDR, (uint8_t)1);
  uint8_t got = Wire.available() ? Wire.read() : 0;

  Serial.print("eeprom ");
  Serial.print(got);
}

void loop() {
}
