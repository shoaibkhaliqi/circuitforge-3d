// M7 device spike: drive a 128x64 SSD1306 OLED over SPI with no external library. The
// harness decodes the MOSI byte stream into the GDDRAM frame (using the DC line to tell
// commands from data), so the panel becomes a firmware-driven device - the SPI twin of
// oled_fill. This sketch fills the left half of the screen (columns 0..63 white, 64..127
// black) in vertical addressing mode, then reports the frame over serial.
//
// The transfer goes through the ATmega's own SPI peripheral (SPI.h ships with the AVR
// core, and the harness taps the peripheral - a bit-banged bus would not be visible to
// it), so the bus pins are the Uno's hardware SPI: MOSI = 11, SCK = 13. DC and CS stay
// ordinary GPIOs, which is what the device model samples per transfer.
#include <SPI.h>

#define OLED_DC 9
#define OLED_CS 10
#define OLED_RES 8

static void oledCmd(uint8_t c) {
  digitalWrite(OLED_DC, LOW);   // command
  SPI.transfer(c);
}

static void oledCmd1(uint8_t c, uint8_t a) {
  digitalWrite(OLED_DC, LOW);
  SPI.transfer(c);
  SPI.transfer(a);
}

static void oledCmd2(uint8_t c, uint8_t a, uint8_t b) {
  digitalWrite(OLED_DC, LOW);
  SPI.transfer(c);
  SPI.transfer(a);
  SPI.transfer(b);
}

static void oledData(uint8_t b) {
  digitalWrite(OLED_DC, HIGH);  // data
  SPI.transfer(b);
}

static void oledInit() {
  digitalWrite(OLED_RES, LOW);   // reset pulse
  delay(10);
  digitalWrite(OLED_RES, HIGH);
  delay(10);

  oledCmd(0xAE);            // display off
  oledCmd1(0xD5, 0x80);     // clock divide
  oledCmd1(0xA8, 0x3F);     // multiplex 64
  oledCmd1(0xD3, 0x00);     // display offset 0
  oledCmd(0x40);            // start line 0
  oledCmd1(0x8D, 0x14);     // charge pump on
  oledCmd1(0x20, 0x01);     // vertical addressing
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
  pinMode(OLED_DC, OUTPUT);
  pinMode(OLED_CS, OUTPUT);
  pinMode(OLED_RES, OUTPUT);
  SPI.begin();
  SPI.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));
  digitalWrite(OLED_CS, LOW);    // selected for the whole run

  oledInit();

  oledCmd2(0x21, 0, 127);   // column address 0..127
  oledCmd2(0x22, 0, 7);     // page address 0..7

  // Vertical addressing: the pointer walks down the pages of one column first, so each
  // column gets its own byte per page. Left 64 columns lit, right 64 dark.
  uint16_t written = 0;
  for (uint8_t c = 0; c < 128; c++) {
    for (uint8_t pg = 0; pg < 8; pg++) {
      oledData(c < 64 ? 0xFF : 0x00);
      written++;
    }
  }

  SPI.endTransaction();
  Serial.print("oled spi bytes ");
  Serial.print(written);
  Serial.println(" left half ff");
}

void loop() {
}
