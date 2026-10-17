// M7 spike: the simplest deterministic firmware — a 1 Hz LED blink on D13.
// Compiled by arduino-cli (arduino:avr:uno) into an Intel HEX that the flywheel
// harness runs on avr8js. D13 is PB5 on the ATmega328P, so the harness should see
// PORTB bit 5 toggle every 500 ms of emulated time.
void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
}

void loop() {
  digitalWrite(LED_BUILTIN, HIGH);
  delay(500);
  digitalWrite(LED_BUILTIN, LOW);
  delay(500);
}
