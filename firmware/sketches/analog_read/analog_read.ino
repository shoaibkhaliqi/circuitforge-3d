// M7 analog-loop spike: READ a voltage with the AVR's own ADC.
// The harness sets ADC channel 0 (A0) from the CF_ADC env var, so this prints the
// converted code. With CF_ADC={"0":2.5} at a 5 V AVcc reference the code is
// round(2.5/5 * 1023) = 512, so Serial prints "adc 512 mv 2502". This proves
// circuit -> firmware analog feedback (the solved node voltage reaches analogRead).
void setup() {
  Serial.begin(9600);
}

void loop() {
  int raw = analogRead(A0);
  unsigned long mv = map(raw, 0, 1023, 0, 5000);
  Serial.print("adc ");
  Serial.print(raw);
  Serial.print(" mv ");
  Serial.println(mv);
  delay(500);
}
