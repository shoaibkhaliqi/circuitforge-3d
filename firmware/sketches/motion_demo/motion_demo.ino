// M8 capstone: one sketch that drives both kinds of motor at once - a servo on a 50 Hz
// software pulse train (D9) and a STEP/DIR stepper driver (D3/D2/D4) - so the app's two
// *output* decoders (servo pulse widths, stepper edges) can be checked together on a
// single run. No libraries: the stopwatch is micros().
#define SERVO_PIN 9
#define STEP_PIN 3
#define DIR_PIN 2
#define ENABLE_PIN 4

// 0..180 deg across the SG90's 544..2400 us band, then settle at 90. Plain `int`, not
// int8_t: 144 and 180 do not fit in a signed byte (they wrap to -112/-76 and the pulses
// come out short and nonsense - the verifier caught exactly that).
static const int SCHEDULE[8] = {0, 36, 72, 108, 144, 180, 90, 90};
static const unsigned long PULSE_US = 20000;      // 50 Hz
static const unsigned long STEP_US = 2500;        // 400 steps/s
static const unsigned long HOLD_US = 150000;      // one schedule entry every 150 ms

static int schedIdx = 0;
static long remaining = 200;                      // 200 forward, then 50 back = net +150
static int phase = 0;
static unsigned long nextPulseUs = 0;
static unsigned long nextStepUs = 0;
static unsigned long nextHoldUs = 0;

// Long arithmetic on purpose: on an AVR `int` is 16 bits, so (2400-544)*deg overflows for
// any angle above ~17 degrees and the pulses come out wrong. (The servo_sweep sketch uses
// map(), which is already long.)
static int pulseForDeg(int deg) { return (int)(544L + (2400L - 544L) * (long)deg / 180L); }

void setup() {
  pinMode(SERVO_PIN, OUTPUT);
  pinMode(STEP_PIN, OUTPUT);
  pinMode(DIR_PIN, OUTPUT);
  pinMode(ENABLE_PIN, OUTPUT);
  digitalWrite(ENABLE_PIN, LOW);                  // the A4988 is enabled low
  digitalWrite(DIR_PIN, HIGH);                    // forward
  Serial.begin(9600);
  Serial.println("motion demo");
  nextPulseUs = micros();
  nextStepUs = nextPulseUs;
  nextHoldUs = nextPulseUs;
}

void loop() {
  unsigned long now = micros();

  if (now >= nextPulseUs) {                       // one 50 Hz servo pulse
    digitalWrite(SERVO_PIN, HIGH);
    // Spin on micros() like servo_sweep: delayMicroseconds() overshoots the commanded
    // width by tens of microseconds here (its runtime path rounds to loop chunks), which
    // would show up as several degrees of error in the decoded angle.
    const unsigned long t0 = micros();
    const unsigned long want = (unsigned long)pulseForDeg(SCHEDULE[schedIdx]);
    while (micros() - t0 < want) { }
    digitalWrite(SERVO_PIN, LOW);
    nextPulseUs = micros() + PULSE_US - 3000UL;   // the pulse itself costs 0.5..2.4 ms
    if (micros() >= nextHoldUs) {
      if (schedIdx < 7) schedIdx++;
      nextHoldUs += HOLD_US;
    }
  }

  now = micros();
  if (now >= nextStepUs && phase < 2) {           // one STEP pulse, interleaved with the servo
    digitalWrite(STEP_PIN, HIGH);
    delayMicroseconds(3);
    digitalWrite(STEP_PIN, LOW);
    remaining--;
    if (remaining == 0) {
      if (phase == 0) {
        Serial.println("stepper 200 forward");
        phase = 1;
        digitalWrite(DIR_PIN, LOW);               // reverse
        remaining = 50;
      } else {
        Serial.println("stepper 50 reverse");
        phase = 2;
        digitalWrite(ENABLE_PIN, HIGH);           // release the driver
      }
    }
    nextStepUs = micros() + STEP_US;
  }
}
