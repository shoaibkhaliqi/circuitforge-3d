// M7 device spike: set the PCF8591 DAC output (address 0x48) to mid-scale. The
// harness records the DAC byte (control 0x40 enables the analog output, then the
// data byte), so apply_firmware_device can drive the circuit's AOUT to
// byte/255 * vref (~2.51 V) and re-solve. Serial prints "dac 128".
#include <Wire.h>

#define PCF8591_ADDR 0x48

void setup() {
  Wire.begin();
  Serial.begin(9600);

  Wire.beginTransmission(PCF8591_ADDR);
  Wire.write((uint8_t)0x40); // enable analog output, channel 0
  Wire.write((uint8_t)0x80); // mid-scale
  Wire.endTransmission();

  Serial.print("dac 128");
}

void loop() {
}
