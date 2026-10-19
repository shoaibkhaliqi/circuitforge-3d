// M8 device spike: read a MCP3008 8-channel 10-bit ADC over SPI with no external library.
// Unlike the SPI displays (which the harness only *listens* to), this is a read: the ADC
// answers on MISO, so the harness returns bytes for firmware to consume - the first
// device -> firmware feedback on the SPI peripheral. This sketch reads channels 0..3 with
// the datasheet's three-transfer conversion and prints the raw codes over serial.
//
// The transfer goes through the ATmega's own SPI peripheral (the harness taps the
// peripheral, so a bit-banged bus would be invisible): MOSI = 11 (DIN), SCK = 13 (CLK),
// MISO = 12 (DOUT = the ADC's answer). CS is an ordinary GPIO, and the harness samples it
// per transfer to frame one conversion.
#include <SPI.h>

#define ADC_CS 10

// One MCP3008 conversion: 0x01 start, then 0x80 (single-ended) | channel in bits 6..4,
// then a don't-care byte. The 10-bit result arrives in the low bits of the 2nd byte and
// all of the 3rd.
static int adcRead(uint8_t channel) {
  digitalWrite(ADC_CS, LOW);
  SPI.transfer(0x01);
  uint8_t hi = SPI.transfer(0x80 | ((channel & 0x07) << 4));
  uint8_t lo = SPI.transfer(0x00);
  digitalWrite(ADC_CS, HIGH);
  return ((hi & 0x03) << 8) | lo;
}

void setup() {
  Serial.begin(9600);
  pinMode(ADC_CS, OUTPUT);
  digitalWrite(ADC_CS, HIGH);
  SPI.begin();
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));

  // Read a few channels twice to show a repeat read is stable, then report.
  int first[4];
  for (uint8_t ch = 0; ch < 4; ch++) first[ch] = adcRead(ch);
  for (uint8_t ch = 0; ch < 4; ch++) {
    int again = adcRead(ch);
    Serial.print("ch");
    Serial.print(ch);
    Serial.print(" ");
    Serial.print(first[ch]);
    Serial.print(" ");
    Serial.println(again);
  }

  SPI.endTransaction();
}

void loop() {
}
