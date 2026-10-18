// M7/M8 device spike: drive a 128x64 SSD1306 OLED over I2C with no external library.
// The harness decodes the command/data stream into the GDDRAM frame and returns it, so
// the display becomes a firmware-driven device. This sketch fills the top half of the
// screen (pages 0..3) white and leaves the bottom half black, then reports the frame.
#include <Wire.h>

#define OLED_ADDR 0x3C

void oledCmd(uint8_t c) {
  Wire.beginTransmission(OLED_ADDR);
  Wire.write(0x00);
  Wire.write(c);
  Wire.endTransmission();
}

void oledCmd1(uint8_t c, uint8_t a) {
  Wire.beginTransmission(OLED_ADDR);
  Wire.write(0x00);
  Wire.write(c);
  Wire.write(a);
  Wire.endTransmission();
}

void oledCmd2(uint8_t c, uint8_t a, uint8_t b) {
  Wire.beginTransmission(OLED_ADDR);
  Wire.write(0x00);
  Wire.write(c);
  Wire.write(a);
  Wire.write(b);
  Wire.endTransmission();
}

void oledInit() {
  oledCmd(0xAE);            // display off
  oledCmd1(0xD5, 0x80);     // clock divide
  oledCmd1(0xA8, 0x3F);     // multiplex 64
  oledCmd1(0xD3, 0x00);     // display offset 0
  oledCmd(0x40);            // start line 0
  oledCmd1(0x8D, 0x14);     // charge pump on
  oledCmd1(0x20, 0x00);     // horizontal addressing
  oledCmd(0xA1);            // segment remap
  oledCmd(0xC8);            // COM scan dec
  oledCmd1(0xDA, 0x12);     // COM pins
  oledCmd1(0x81, 0xCF);     // contrast
  oledCmd1(0xD9, 0xF1);     // pre-charge
  oledCmd1(0xDB, 0x40);     // VCOMH
  oledCmd(0xA4);            // resume RAM content
  oledCmd(0xA6);            // normal (not inverted)
  oledCmd(0xAF);            // display on
}

void setup() {
  Serial.begin(9600);
  Wire.begin();
  oledInit();

  oledCmd2(0x21, 0, 127);   // column address 0..127
  oledCmd2(0x22, 0, 7);     // page address 0..7

  uint16_t written = 0;
  for (uint16_t i = 0; i < 1024; i += 16) {
    Wire.beginTransmission(OLED_ADDR);
    Wire.write(0x40);       // data stream
    for (uint8_t j = 0; j < 16; j++) {
      Wire.write(i < 512 ? 0xFF : 0x00);  // top half white, bottom half black
      written++;
    }
    Wire.endTransmission();
  }

  Serial.print("oled bytes ");
  Serial.print(written);
  Serial.println(" page0 ff");
}

void loop() {
}
