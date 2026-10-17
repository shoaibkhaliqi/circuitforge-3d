// M7 device spike: read channel 0 of a PCF8591 I2C ADC/DAC (address 0x48) and
// print the 8-bit code. The harness serves the part on the bus and converts the
// solved analog input voltage (CF_DEVICES "ain") over the reference (default 5 V),
// so 2.5 V reads as code 128. Serial prints "adc 128".
#include <Wire.h>

#define PCF8591_ADDR 0x48

void setup() {
  Wire.begin();
  Serial.begin(9600);

  // Control byte: channel 0, no auto-increment, analog output off.
  Wire.beginTransmission(PCF8591_ADDR);
  Wire.write((uint8_t)0x00);
  Wire.endTransmission();

  Wire.requestFrom(PCF8591_ADDR, (uint8_t)1);
  uint8_t code = Wire.available() ? Wire.read() : 0;

  Serial.print("adc ");
  Serial.print(code);
}

void loop() {
}
