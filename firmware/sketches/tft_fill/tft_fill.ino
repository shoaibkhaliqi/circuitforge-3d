// M8 device spike: drive a 240x320 ILI9341 colour TFT over SPI with no external library.
// The harness decodes the MOSI byte stream into an RGB565 frame using the panel's DC line to
// tell commands from pixel data, so the TFT becomes a firmware-driven device - the colour
// twin of oled_spi. This sketch fills the left half of the screen red (0xF800) and the right
// half blue (0x001F), then reports the pixel count over serial.
//
// The transfer goes through the ATmega's own SPI peripheral (the harness taps the peripheral,
// so a bit-banged bus would be invisible): MOSI = 11, SCK = 13. DC, CS and RESET are ordinary
// GPIOs, and the harness samples DC and CS per transfer.
#include <SPI.h>

#define TFT_CS 10
#define TFT_DC 9
#define TFT_RES 8

#define TFT_W 240
#define TFT_H 320

static void tftCmd(uint8_t c) {
  digitalWrite(TFT_DC, LOW);    // command
  SPI.transfer(c);
}

static void tftData(uint8_t b) {
  digitalWrite(TFT_DC, HIGH);   // data
  SPI.transfer(b);
}

static void tftCmdData(uint8_t c, const uint8_t* d, uint8_t n) {
  tftCmd(c);
  for (uint8_t i = 0; i < n; i++) tftData(d[i]);
}

// A trimmed-down Adafruit-style init: power/reset, the driver's tuning registers, then the
// 16-bit pixel format and display on. The tuning values are the usual ones and do not matter
// to the decode, but they exercise the harness's command/argument handling.
static void tftInit() {
  digitalWrite(TFT_RES, LOW);
  delay(20);
  digitalWrite(TFT_RES, HIGH);
  delay(120);

  tftCmd(0x01);                 // software reset
  delay(5);
  tftCmd(0x11);                 // sleep out
  delay(120);

  static const uint8_t pwrA[] = {0x39, 0x2C, 0x00, 0x34};
  tftCmdData(0xCB, pwrA, 4);    // power control A
  static const uint8_t pwrB[] = {0x00, 0xC1, 0x30};
  tftCmdData(0xCF, pwrB, 3);    // power control B
  static const uint8_t drvTA[] = {0x85, 0x00, 0x78};
  tftCmdData(0xE8, drvTA, 3);   // driver timing control A
  static const uint8_t drvTB[] = {0x00, 0x00};
  tftCmdData(0xEA, drvTB, 2);   // driver timing control B
  static const uint8_t pwrSeq[] = {0x64, 0x03, 0x12, 0x81};
  tftCmdData(0xED, pwrSeq, 4);  // power on sequence
  static const uint8_t pumpRatio[] = {0x20};
  tftCmdData(0xF7, pumpRatio, 1); // pump ratio
  static const uint8_t pwr1[] = {0x23};
  tftCmdData(0xC0, pwr1, 1);    // power control 1
  static const uint8_t pwr2[] = {0x10};
  tftCmdData(0xC1, pwr2, 1);    // power control 2
  static const uint8_t vcom1[] = {0x3E, 0x28};
  tftCmdData(0xC5, vcom1, 2);   // VCOM control 1
  static const uint8_t vcom2[] = {0x86};
  tftCmdData(0xC7, vcom2, 1);   // VCOM control 2
  static const uint8_t madctl[] = {0x48};
  tftCmdData(0x36, madctl, 1);  // memory access control (MX | BGR)
  static const uint8_t pixfmt[] = {0x55};
  tftCmdData(0x3A, pixfmt, 1);  // 16 bits/pixel (RGB565)
  static const uint8_t frmctr[] = {0x00, 0x18};
  tftCmdData(0xB1, frmctr, 2);  // frame rate control
  static const uint8_t dfun[] = {0x08, 0x82, 0x27};
  tftCmdData(0xB6, dfun, 3);    // display function control
  static const uint8_t e3[] = {0x00};
  tftCmdData(0xF2, e3, 1);      // 3G gamma disable
  static const uint8_t gctrl[] = {0x01};
  tftCmdData(0x26, gctrl, 1);   // gamma set
  static const uint8_t gmPos[] = {0x0F, 0x31, 0x2B, 0x0C, 0x0E, 0x08, 0x4E, 0xF1,
    0x37, 0x07, 0x10, 0x03, 0x0E, 0x09, 0x00};
  tftCmdData(0xE0, gmPos, 15);  // positive gamma
  static const uint8_t gmNeg[] = {0x00, 0x0E, 0x14, 0x03, 0x11, 0x07, 0x31, 0xC1,
    0x48, 0x08, 0x0F, 0x0C, 0x31, 0x36, 0x0F};
  tftCmdData(0xE1, gmNeg, 15);  // negative gamma

  tftCmd(0x11);                 // sleep out (again, after the tuning)
  delay(120);
  tftCmd(0x29);                 // display on
}

static void tftSetWindow(uint16_t x0, uint16_t y0, uint16_t x1, uint16_t y1) {
  tftCmd(0x2A);                 // column address set
  tftData(x0 >> 8); tftData(x0 & 0xFF);
  tftData(x1 >> 8); tftData(x1 & 0xFF);
  tftCmd(0x2B);                 // page address set
  tftData(y0 >> 8); tftData(y0 & 0xFF);
  tftData(y1 >> 8); tftData(y1 & 0xFF);
  tftCmd(0x2C);                 // memory write
}

void setup() {
  Serial.begin(9600);
  pinMode(TFT_CS, OUTPUT);
  pinMode(TFT_DC, OUTPUT);
  pinMode(TFT_RES, OUTPUT);
  SPI.begin();
  SPI.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));
  digitalWrite(TFT_CS, LOW);    // selected for the whole run

  tftInit();

  tftSetWindow(0, 0, TFT_W - 1, TFT_H - 1);

  // RGB565: left half red, right half blue. The pointer auto-increments across the window
  // and wraps back to the window's start once it passes the last pixel.
  uint32_t pixels = 0;
  for (uint16_t y = 0; y < TFT_H; y++) {
    for (uint16_t x = 0; x < TFT_W; x++) {
      uint16_t colour = (x < TFT_W / 2) ? 0xF800 : 0x001F;
      tftData(colour >> 8);
      tftData(colour & 0xFF);
      pixels++;
    }
  }

  SPI.endTransaction();
  Serial.print("tft pixels ");
  Serial.print(pixels);
  Serial.println(" left half red");
}

void loop() {
}
