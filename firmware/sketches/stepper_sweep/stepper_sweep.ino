// M8 device spike: drive a STEP/DIR stepper driver (A4988/DRV8825) with a hand-written
// pulse generator - no library. A stepper is an *output*, so there is no device on the
// bus: the app counts the rising edges the sketch puts on STEP and takes the direction
// from DIR at each one, then turns that count into a shaft angle.
#define STEP_PIN 3
#define DIR_PIN 2
#define ENABLE_PIN 4

static void stepPulse() {
  digitalWrite(STEP_PIN, HIGH);
  delayMicroseconds(3);            // A4988 needs >= 1 us
  digitalWrite(STEP_PIN, LOW);
  delayMicroseconds(50);           // ~19 kHz step rate
}

static void move(long steps, bool forward) {
  digitalWrite(DIR_PIN, forward ? HIGH : LOW);
  delayMicroseconds(5);            // DIR setup time before the first edge
  for (long i = 0; i < steps; i++) stepPulse();
}

void setup() {
  pinMode(STEP_PIN, OUTPUT);
  pinMode(DIR_PIN, OUTPUT);
  pinMode(ENABLE_PIN, OUTPUT);
  digitalWrite(ENABLE_PIN, LOW);   // A4988 ENABLE is active low
  Serial.begin(9600);

  Serial.println("stepper 200 forward");
  move(200, true);
  Serial.println("stepper 100 reverse");
  move(100, false);
  Serial.println("stepper 50 forward");
  move(50, true);                  // net +150 steps
  Serial.println("stepper done 150");
}

void loop() {
}
