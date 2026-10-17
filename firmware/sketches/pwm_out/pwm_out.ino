// M7 output-loop spike: analogWrite() (PWM) drives the circuit.
// Sets D9 to a 50.2% duty (128/255) square wave. The harness reports the average
// duty per pin, so apply_firmware_pwm can drive an mcu_pwm_out to 0.502 * 5 V.
void setup() {
  pinMode(9, OUTPUT);
}

void loop() {
  analogWrite(9, 128);
}
