// M8 device spike: drive an MCP4725 12-bit I2C DAC with no external library, using the
// datasheet's write commands - 0x40 writes the DAC register, 0x60 writes the DAC register
// and its EEPROM - followed by two data bytes carrying the 12-bit code in their top 12
// bits. Each write is printed with the VOUT voltage it should produce at the 5 V (VDD)
// reference this sketch assumes. The harness serves the DAC, so the codes come back decoded.
// The last line is a deliberate fast-mode-style first byte (0b0000xxxx): the model decodes
// the *general* write command only, so that transaction must be counted and change nothing.
#include <Wire.h>

#define DAC_ADDR   0x60
#define CMD_DAC    0x40   // write the DAC register
#define CMD_EEPROM 0x60   // write the DAC register and the EEPROM
#define VREF_MV    5000L
#define DAC_STEPS  4096L  // 12-bit

static void setCode(uint8_t cmd, uint16_t code, uint8_t pd) {
  Wire.beginTransmission(DAC_ADDR);
  Wire.write((uint8_t)((cmd & 0x60) | (pd & 0x03)));
  Wire.write((uint8_t)((code >> 4) & 0xFF));       // D11..D4
  Wire.write((uint8_t)((code & 0x0F) << 4));       // D3..D0 in the high nibble
  Wire.endTransmission();
}

static void report(uint16_t code, uint8_t pd) {
  Serial.print("dac ");
  Serial.print(code);
  Serial.print(" ");
  Serial.print((long)code * VREF_MV / DAC_STEPS);
  Serial.print(" ");
  Serial.println(pd);
}

void setup() {
  Serial.begin(9600);
  Wire.begin();

  setCode(CMD_DAC, 2048, 0);            // 2.5 V
  report(2048, 0);

  setCode(CMD_DAC, 819, 0);             // 1.0 V (999.75 mV -> the print truncates)
  report(819, 0);

  setCode(CMD_DAC, 4095, 0);            // full scale
  report(4095, 0);

  setCode(CMD_EEPROM, 1234, 0);         // also writes the EEPROM (decoded, not persisted)
  report(1234, 0);

  setCode(CMD_DAC, 0, 1);               // power-down mode 1 (1k to GND); code 0
  report(0, 1);

  setCode(CMD_DAC, 3300, 0);            // back to normal drive: 3300/4096 * 5 V
  report(3300, 0);

  Wire.beginTransmission(DAC_ADDR);     // fast-mode-style first byte: not decoded
  Wire.write(0x0F);
  Wire.write(0x00);
  Wire.endTransmission();
  Serial.println("fastmode");
}

void loop() {
}
