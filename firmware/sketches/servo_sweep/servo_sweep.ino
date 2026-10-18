// M7/M8 device spike: drive a hobby servo (SG90/MG996R) with a hand-written 50 Hz
// software-PWM pulse train (no Servo library is bundled, and the real one is a Timer1
// driver). The harness records the pin's transitions, so the commanded angle can be
// recovered from the pulse widths - firmware -> actuator feedback without an electrical
// model. The sketch sweeps 0..180 degrees in 30-degree steps, then settles at 90.
#define SERVO_PIN 9
#define SERVO_MIN_US 544
#define SERVO_MAX_US 2400
#define FRAME_MS 20

static uint16_t usForAngle(uint8_t deg) {
  return (uint16_t)(SERVO_MIN_US + ((uint32_t)(SERVO_MAX_US - SERVO_MIN_US) * deg) / 180);
}

static void servoPulse(uint16_t us) {
  digitalWrite(SERVO_PIN, HIGH);
  const unsigned long t0 = micros();
  while (micros() - t0 < us) { }   // hold the line high for the commanded width
  digitalWrite(SERVO_PIN, LOW);
  delay(FRAME_MS);                 // one 50 Hz frame
}

static void servoHold(uint8_t deg, uint8_t frames) {
  const uint16_t us = usForAngle(deg);
  for (uint8_t i = 0; i < frames; i++) servoPulse(us);
}

void setup() {
  pinMode(SERVO_PIN, OUTPUT);
  Serial.begin(9600);

  for (uint8_t deg = 0; deg <= 180; deg += 30) {
    Serial.print("servo ");
    Serial.println(deg);
    servoHold(deg, 3);
  }

  Serial.println("servo settle 90");
  servoHold(90, 15);               // hold so the commanded position is unambiguous
}

void loop() {
}
