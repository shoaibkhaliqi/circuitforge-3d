// M7/M8 device spike: decode a rotary (quadrature) encoder on two digital pins. The
// harness drives the A/B pair through a Gray sequence, one pin per count, so a polling
// decoder sees every step: this sketch counts the net steps and prints the total.
#define ENC_A 2
#define ENC_B 3

// Quadrature step table, indexed by (previous state << 2 | current state), where the
// state is (A << 1) | B. +1 forward, -1 reverse, 0 on no change / invalid hop.
const int8_t QUAD_TABLE[16] = {0, -1, 1, 0, 1, 0, 0, -1, -1, 0, 0, 1, 0, 1, -1, 0};

static inline uint8_t encState() {
  return (uint8_t)((digitalRead(ENC_A) << 1) | digitalRead(ENC_B));
}

void setup() {
  Serial.begin(9600);
  pinMode(ENC_A, INPUT);
  pinMode(ENC_B, INPUT);

  long steps = 0;
  uint8_t last = encState();
  const unsigned long window = 200;  // ms
  unsigned long t0 = millis();
  while (millis() - t0 < window) {
    uint8_t cur = encState();
    if (cur != last) {
      steps += QUAD_TABLE[(last << 2) | cur];
      last = cur;
    }
  }

  Serial.print("enc ");
  Serial.println(steps);
}

void loop() {
}
