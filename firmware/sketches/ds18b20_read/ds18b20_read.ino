// M7 device spike: read a DS18B20 digital thermometer over 1-Wire with a hand-written driver.
// The OneWire library is NOT bundled (only the core Arduino libraries are), so every 1-Wire
// slot is timed here with delayMicroseconds() and micros-free reads - which is the point: the
// harness has to serve a real *bidirectional* bit-slot slave, not a start-pulse sensor.
//
// Printed lines (all values the verifier recomputes):
//   present 1                              the presence pulse a reset must answer with
//   rom 28 ... 46 crc-ok                   READ ROM (0x33) + the Dallas CRC-8
//   match-bad crc-bad                      MATCH ROM (0x55) with another ROM: the part stays
//                                          silent, so the bytes read back are all ones
//   match-ok crc-ok                        MATCH ROM with the ROM just read: the part answers
//   temp <raw> <mC> <crc> <TH> <TL> <CFG>  a conversion (0x44) then READ SCRATCHPAD (0xBE)
//   cfg  <raw> <mC> <crc> <TH> <TL> <CFG>  after WRITE SCRATCHPAD (0x4E) at 10-bit resolution
#include <Arduino.h>

#define OW_PIN 2

// ---- a minimal 1-Wire master -------------------------------------------------
static void owLow() { pinMode(OW_PIN, OUTPUT); digitalWrite(OW_PIN, LOW); }
static void owRelease() { pinMode(OW_PIN, INPUT); }

// Dallas/Maxim CRC-8 (reflected polynomial 0x8C, init 0) - the same one the OneWire library
// uses for both the 64-bit ROM and the scratchpad.
static uint8_t crc8(const uint8_t *data, uint8_t len) {
  uint8_t crc = 0;
  while (len--) {
    uint8_t inByte = *data++;
    for (uint8_t i = 8; i; i--) {
      uint8_t mix = (crc ^ inByte) & 0x01;
      crc >>= 1;
      if (mix) crc ^= 0x8C;
      inByte >>= 1;
    }
  }
  return crc;
}

// Reset pulse + presence check. The datasheet minimum is 480 us, so 500 is used.
static bool owReset() {
  owLow();
  delayMicroseconds(500);
  owRelease();
  delayMicroseconds(70);
  bool present = (digitalRead(OW_PIN) == LOW);
  delayMicroseconds(410);
  return present;
}

static void owWriteBit(uint8_t bit) {
  owLow();
  if (bit) { // a 1: a short low, then the slot's remainder released
    delayMicroseconds(6);
    owRelease();
    delayMicroseconds(64);
  } else {   // a 0: hold the line low for most of the slot
    delayMicroseconds(60);
    owRelease();
    delayMicroseconds(10);
  }
}

static uint8_t owReadBit() {
  owLow();
  delayMicroseconds(3);
  owRelease();
  delayMicroseconds(10); // the part drives a 0 before the master samples here
  uint8_t bit = (digitalRead(OW_PIN) == HIGH) ? 1 : 0;
  delayMicroseconds(53);
  return bit;
}

// 1-Wire sends the least significant bit of every byte first.
static void owWriteByte(uint8_t value) {
  for (uint8_t i = 0; i < 8; i++) owWriteBit((value >> i) & 1);
}

static uint8_t owReadByte() {
  uint8_t value = 0;
  for (uint8_t i = 0; i < 8; i++) if (owReadBit()) value |= (uint8_t)(1 << i);
  return value;
}

static void printHex(uint8_t b) {
  if (b < 16) Serial.print('0');
  Serial.print(b, HEX);
}

// A reset + SKIP ROM + READ SCRATCHPAD, then one report line: the raw 12/10-bit count, the
// same value in milli-degrees, the CRC verdict and the scratchpad's TH/TL/config bytes.
static void reportScratchpad(const char *tag) {
  owReset();
  owWriteByte(0xCC); // SKIP ROM: there is only one device on the bus
  owWriteByte(0xBE); // READ SCRATCHPAD
  uint8_t sp[9];
  for (uint8_t i = 0; i < 9; i++) sp[i] = owReadByte();

  int16_t raw = (int16_t)(((uint16_t)sp[1] << 8) | sp[0]);
  long milliC = (long)raw * 125L / 2L; // 0.0625 degC = 62.5 mdegC = 125/2

  Serial.print(tag);
  Serial.print(' ');
  Serial.print(raw);
  Serial.print(' ');
  Serial.print(milliC);
  Serial.print(' ');
  Serial.print(crc8(sp, 8) == sp[8] ? 1 : 0);
  Serial.print(' ');
  for (uint8_t i = 2; i < 5; i++) {
    printHex(sp[i]);
    Serial.print(' ');
  }
  Serial.println();
}

static const uint8_t OTHER_ROM[8] = {0x28, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x00};

void setup() {
  Serial.begin(9600);

  Serial.print("present ");
  Serial.println(owReset() ? 1 : 0);

  // READ ROM (0x33): family code, serial number and the ROM's own CRC.
  owReset();
  owWriteByte(0x33);
  uint8_t rom[8];
  for (uint8_t i = 0; i < 8; i++) rom[i] = owReadByte();
  Serial.print("rom ");
  for (uint8_t i = 0; i < 8; i++) {
    printHex(rom[i]);
    Serial.print(' ');
  }
  Serial.println(crc8(rom, 7) == rom[7] ? "crc-ok" : "crc-bad");

  // MATCH ROM (0x55) with a ROM this part does not have: it must answer nothing, so the
  // nine bytes read after READ SCRATCHPAD are all ones and the CRC fails.
  owReset();
  owWriteByte(0x55);
  for (uint8_t i = 0; i < 8; i++) owWriteByte(OTHER_ROM[i]);
  owWriteByte(0xBE);
  uint8_t other[9];
  for (uint8_t i = 0; i < 9; i++) other[i] = owReadByte();
  Serial.print("match-bad ");
  Serial.println(crc8(other, 8) == other[8] ? "crc-ok" : "crc-bad");

  // MATCH ROM (0x55) with the ROM just read: now the part must answer, so the scratchpad comes
  // back with a good CRC. Together the two runs show the ROM comparison actually selects.
  owReset();
  owWriteByte(0x55);
  for (uint8_t i = 0; i < 8; i++) owWriteByte(rom[i]);
  owWriteByte(0xBE);
  uint8_t matched[9];
  for (uint8_t i = 0; i < 9; i++) matched[i] = owReadByte();
  Serial.print("match-ok ");
  Serial.println(crc8(matched, 8) == matched[8] ? "crc-ok" : "crc-bad");

  // Two conversions, each with the datasheet's 750 ms wait for 12-bit resolution, then a
  // third read without a new conversion (the same value again).
  for (uint8_t k = 0; k < 2; k++) {
    owReset();
    owWriteByte(0xCC);
    owWriteByte(0x44); // CONVERT T
    delay(750);
    reportScratchpad("temp");
  }
  reportScratchpad("temp");

  // WRITE SCRATCHPAD (0x4E): TH, TL and a 10-bit config, then read it back - the part must
  // serve the bytes it was given and quantise the temperature to the new resolution.
  owReset();
  owWriteByte(0xCC);
  owWriteByte(0x4E);
  owWriteByte(0x4B); // TH = +75 degC
  owWriteByte(0x46); // TL = +70 degC
  owWriteByte(0x3F); // 0b0011 1111 -> bits 6:5 = 01 -> 10-bit resolution
  reportScratchpad("cfg");

  // COPY SCRATCHPAD (0x48) / RECALL E2 (0xB8): decoded and counted by the part, but nothing
  // persists between runs (memory is never stored to disk).
  owReset();
  owWriteByte(0xCC);
  owWriteByte(0x48);
  owReset();
  owWriteByte(0xCC);
  owWriteByte(0xB8);
  Serial.println("e2");
}

void loop() {
}
