// M7/M8 device spike: read an ADS1115 16-bit I2C ADC with no external library.
// The part has no ID register, so the sketch proves itself by *configuring* it: each
// conversion writes the config register (MUX + programmable gain + single-shot) and then
// reads the conversion register, so the codes come back at the range the sketch asked for.
// The harness serves a register file whose channel voltages are the solved node voltages
// of A0..A3, so this is the I2C twin of the SPI MCP3008 read path.
//   * A0..A3 against GND at +/-4.096 V (single-ended), and
//   * A0 against A1 (the differential pair) at the same gain, and
//   * A1 again at +/-1.024 V, to show the PGA really changes the codes.
#include <Wire.h>

#define ADS_ADDR   0x48
#define REG_CONV   0x00
#define REG_CONFIG 0x01
#define MUX_AIN0_GND   0x04
#define MUX_AIN1_GND   0x05
#define MUX_AIN2_GND   0x06
#define MUX_AIN3_GND   0x07
#define MUX_AIN0_AIN1  0x00
#define PGA_4V096      0x01
#define PGA_1V024      0x03
#define OS_SINGLE      0x8000
#define MODE_SINGLE    0x0100
#define RATE_128SPS    0x0080
#define COMP_DISABLE   0x0003

static void writeConfig(uint16_t cfg) {
  Wire.beginTransmission(ADS_ADDR);
  Wire.write(REG_CONFIG);
  Wire.write((uint8_t)(cfg >> 8));
  Wire.write((uint8_t)(cfg & 0xFF));
  Wire.endTransmission();
}

static int16_t readConversion(void) {
  Wire.beginTransmission(ADS_ADDR);
  Wire.write(REG_CONV);
  Wire.endTransmission(false);
  Wire.requestFrom((uint8_t)ADS_ADDR, (uint8_t)2);
  int16_t v = (int16_t)(Wire.read() << 8);
  v |= Wire.read();
  return v;
}

static uint16_t configFor(uint8_t mux, uint8_t pga) {
  return OS_SINGLE | ((uint16_t)mux << 12) | ((uint16_t)pga << 9) |
         MODE_SINGLE | RATE_128SPS | COMP_DISABLE;
}

// Print one conversion: the code and the same reading in millivolts, computed from the
// full-scale range this sketch selected (4.096 V = 4096 mV, 1.024 V = 1024 mV).
static void report(const char *tag, uint8_t mux, uint8_t pga, int full_scale_mv) {
  writeConfig(configFor(mux, pga));
  int16_t code = readConversion();
  long mv = ((long)code * full_scale_mv) / 32768L;
  Serial.print(tag);
  Serial.print(" ");
  Serial.print(code);
  Serial.print(" ");
  Serial.println(mv);
}

void setup() {
  Serial.begin(9600);
  Wire.begin();

  report("a0", MUX_AIN0_GND, PGA_4V096, 4096);
  report("a1", MUX_AIN1_GND, PGA_4V096, 4096);
  report("a2", MUX_AIN2_GND, PGA_4V096, 4096);
  report("a3", MUX_AIN3_GND, PGA_4V096, 4096);
  report("d01", MUX_AIN0_AIN1, PGA_4V096, 4096);   // A0 - A1, differentially
  report("a1g", MUX_AIN1_GND, PGA_1V024, 1024);    // A1 again, finer gain
}

void loop() {
}
