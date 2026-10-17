// M7 spike: serial output — the first protocol surface (UART).
// Prints a greppable line over Serial (USART0) every 500 ms. The harness captures
// the transmitted bytes, so `run_firmware` should report "CircuitForge tick N".
void setup() {
  Serial.begin(9600);
}

void loop() {
  static unsigned long n = 0;
  Serial.print("CircuitForge tick ");
  Serial.println(n);
  n++;
  delay(500);
}
