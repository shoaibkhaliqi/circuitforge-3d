// M8 device spike: drive a 28BYJ-48 through a ULN2003 board with a hand-written four-phase
// sequencer - no library. Like the STEP/DIR stepper this is an *output*: the app watches
// the four phase pins and measures how far the pattern sequence walked, so it recovers the
// travel whatever mix of half-step, full-step and wave driving the sketch uses.
//
// The four inputs sit on PORTB bits 0..3, so one write sets the whole pattern and the
// harness records the pin transitions the app decodes.
#define PATTERN(lo) (PORTB = (PORTB & 0xF0) | ((lo) & 0x0F))

static const uint8_t HALF[8] = {0b0001, 0b0011, 0b0010, 0b0110, 0b0100, 0b1100, 0b1000, 0b1001};
static const uint8_t WAVE[4] = {0b0001, 0b0010, 0b0100, 0b1000};

static int halfIdx = 0;
static int waveIdx = 0;

// One pattern change per loop: in half-step driving that is half a step, in wave driving a
// full step - the decoder measures the difference, so both are honest.
static void halfSteps(int n, bool forward) {
  for (int i = 0; i < n; i++) {
    halfIdx = (halfIdx + (forward ? 1 : 7)) % 8;
    PATTERN(HALF[halfIdx]);
    delay(3);
  }
}

static void waveSteps(int n, bool forward) {
  for (int i = 0; i < n; i++) {
    waveIdx = (waveIdx + (forward ? 1 : 3)) % 4;
    PATTERN(WAVE[waveIdx]);
    delay(3);
  }
}

void setup() {
  DDRB |= 0x0F;                    // D8..D11 are the ULN2003 inputs
  Serial.begin(9600);

  PATTERN(HALF[halfIdx]);          // a driver holds the coils before the first step
  delay(5);
  Serial.println("half 32 fwd");
  halfSteps(32, true);

  PATTERN(0b0000);                 // coils released: the absolute index is lost, so the
  delay(20);                       // next pattern re-establishes the reference only
  PATTERN(WAVE[waveIdx]);
  delay(5);
  Serial.println("wave 8 rev");
  waveSteps(8, false);

  PATTERN(0b0000);
  delay(20);
  PATTERN(WAVE[waveIdx]);
  delay(5);
  Serial.println("wave 8 fwd");
  waveSteps(8, true);              // net +32 half steps (wave hops are worth two)

  Serial.println("4phase done 32");
}

void loop() {
}
