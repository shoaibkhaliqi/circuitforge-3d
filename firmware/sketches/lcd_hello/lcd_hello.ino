// M7 device spike: drive a 16x2 HD44780 LCD through a PCF8574 I2C backpack
// (address 0x27) with no external library. The harness decodes the 4-bit nibble
// protocol and returns the visible text, so the display becomes a firmware-driven
// device. Shows "CircuitForge" on line 1 and "3D" on line 2.
#include <Wire.h>

#define LCD_ADDR 0x27
#define LCD_RS 0x01
#define LCD_EN 0x04
#define LCD_BL 0x08

void expanderWrite(uint8_t v) {
  Wire.beginTransmission(LCD_ADDR);
  Wire.write(v | LCD_BL);
  Wire.endTransmission();
}

void write4bits(uint8_t nib) {
  expanderWrite(nib);            // E low
  expanderWrite(nib | LCD_EN);   // E high
  expanderWrite(nib & ~LCD_EN);  // E low -> the LCD latches the nibble
}

void lcdSend(uint8_t value, uint8_t mode) {
  write4bits(((value >> 4) & 0x0F) << 4 | mode);
  write4bits((value & 0x0F) << 4 | mode);
}

void lcdCommand(uint8_t c) { lcdSend(c, 0); }
void lcdData(uint8_t d) { lcdSend(d, LCD_RS); }
void lcdPrint(const char *s) { while (*s) lcdData((uint8_t)*s++); }

void lcdInit() {
  delay(50);
  write4bits(0x30);
  write4bits(0x30);
  write4bits(0x30);
  write4bits(0x20); // enter 4-bit mode
  lcdCommand(0x28); // 4-bit, 2 lines, 5x8 font
  lcdCommand(0x0C); // display on, cursor off
  lcdCommand(0x06); // entry mode: increment
  lcdCommand(0x01); // clear
  delay(2);
}

void setup() {
  Wire.begin();
  lcdInit();
  lcdCommand(0x80); // line 1, column 0
  lcdPrint("CircuitForge");
  lcdCommand(0xC0); // line 2, column 0
  lcdPrint("3D");
}

void loop() {
}
