// M7/M8 device spike: read an HC-SR04 ultrasonic distance sensor. TRIG is driven
// by the MCU; the harness watches the trigger pulse and drives ECHO (an MCU input)
// high for a distance-proportional time, so pulseIn() measures a real echo. The
// measured round-trip time and distance are printed to Serial.
#define TRIG_PIN 9
#define ECHO_PIN 10

void setup() {
  Serial.begin(9600);
  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  digitalWrite(TRIG_PIN, LOW);
  delay(50);

  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  unsigned long echo = pulseIn(ECHO_PIN, HIGH, 30000UL);
  // Round to the nearest centimetre (58 us per cm round trip).
  unsigned int distanceCm = echo == 0 ? 0 : (unsigned int)((echo + 29UL) / 58UL);

  Serial.print("echo ");
  Serial.print(echo);
  Serial.print(" dist ");
  Serial.println(distanceCm);
}

void loop() {
}
