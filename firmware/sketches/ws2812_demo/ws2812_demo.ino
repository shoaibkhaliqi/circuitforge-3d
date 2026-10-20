// M7 device spike: drive a 3-LED WS2812B chain on D8 (PORTB bit 0) with a
// hand-written bit-banger - no library.
//
// Protocol (WS2812B datasheet): each bit is a high pulse - 0.8 us encodes a 1,
// 0.3 us encodes a 0 - followed by a low pulse; a low gap longer than 50 us
// latches the frame. Bytes go GRB, most-significant bit first. Interrupts are
// masked around the frame exactly like the popular NeoPixel library does,
// because a timer ISR stretching one high pulse would corrupt the bit.
//
// The harness records the pin's transitions; its WS2812B pin device decodes
// them back into LED colours, so the app can show the strip the sketch means.

#include <avr/io.h>
#include <util/delay.h>
#include <stdint.h>

#define LED_PIN_MASK _BV(PORTB0)   // D8

// High pulse per bit: ~750 ns for a 1, ~250 ns for a 0, measured with NOPs so
// the cycle count is explicit at F_CPU = 16 MHz (62.5 ns per cycle).
#define T1H_NOPS 10
#define T0H_NOPS 2

static void sendByte(uint8_t v)
{
  for (uint8_t b = 0; b < 8; b++) {
    // Each bit is emitted with hand-counted cycles at F_CPU = 16 MHz
    // (62.5 ns/cycle). sbi/cbi set then clear PORTB bit 0 (D8); the loop and
    // branch overhead lands in the low period, where it does not matter.
    if (v & 0x80) {
      // A 1 bit: high = 2 + 10 + 2 = 14 cycles = 0.875 us.
      __asm__ volatile (
        "sbi 5, 0\n\t"
        "nop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\t"
        "cbi 5, 0");
    } else {
      // A 0 bit: high = 2 + 2 + 2 = 6 cycles = 0.375 us, well under the 0.5 us
      // boundary a receiver uses to tell 0 from 1.
      __asm__ volatile (
        "sbi 5, 0\n\t"
        "nop\n\tnop\n\t"
        "cbi 5, 0");
    }
    __asm__ volatile ("nop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop"); // low
    v <<= 1;
  }
}

// One pixel in wire order: green, red, blue (GRB).
static void sendPixel(uint8_t r, uint8_t g, uint8_t b)
{
  sendByte(g);
  sendByte(r);
  sendByte(b);
}

void setup() {
  DDRB |= LED_PIN_MASK;   // D8 is an output; the idle line is low
  PORTB &= ~LED_PIN_MASK;
}

void loop() {
  cli();
  sendPixel(255, 0, 0);   // pixel 1: red   (G=0 R=255 B=0)
  sendPixel(0, 255, 0);   // pixel 2: green (G=255 R=0 B=0)
  sendPixel(0, 0, 255);   // pixel 3: blue  (G=0 R=0 B=255)
  sei();
  delay(100);             // longer than the 50 us latch gap: frame latches
}
