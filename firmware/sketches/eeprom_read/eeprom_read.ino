// M7 device spike: read the byte stored at 0x0000 of a 24LC256 (address 0x50) and
// print it. Used to show that a value written by a previous run (persisted in the
// component's `image`) is still there. Serial prints "eeprom <value>".
#include <Wire.h>

#define EEPROM_ADDR 0x50

void setup() {
  Wire.begin();
  Serial.begin(9600);

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
