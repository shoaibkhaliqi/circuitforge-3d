// M7/M8 device spike: read a DHT11/DHT22 temperature+humidity sensor with a
// hand-written one-wire bit-banged driver (no library). The MCU pulls the data line low
// as a start signal, releases it, then times the sensor's 80/80 us handshake and 40 bits
// (each 50 us low + 27 us high = 0, 70 us high = 1) with micros(). The harness plays that
// bit train at datasheet timings, so this is a real sub-100 us protocol on an MCU pin.
#define DHT_PIN 2
#define DHT_TIMEOUT_US 600

static inline uint8_t dhtWait(uint8_t pin, uint8_t level, uint8_t *ok) {
  unsigned long t0 = micros();
  while (digitalRead(pin) == level) {
    if (micros() - t0 > DHT_TIMEOUT_US) {
      *ok = 0;
      return 0;
    }
  }
  return 1;
}

static uint8_t dhtRead(uint8_t pin, uint8_t *data) {
  for (uint8_t i = 0; i < 5; i++) data[i] = 0;

  pinMode(pin, OUTPUT);
  digitalWrite(pin, LOW);
  delay(2);                       // start signal: hold low, then release the line
  digitalWrite(pin, HIGH);
  pinMode(pin, INPUT);            // module pull-up holds the line high

  uint8_t ok = 1;
  dhtWait(pin, HIGH, &ok);        // sensor pulls low (ACK)
  dhtWait(pin, LOW, &ok);         // ... for 80 us, then high for 80 us
  if (!ok) return 0;

  for (uint8_t i = 0; i < 40; i++) {
    dhtWait(pin, HIGH, &ok);      // 50 us low starts the bit
    dhtWait(pin, LOW, &ok);       // ... then the line goes high
    if (!ok) return 0;
    unsigned long t0 = micros();
    dhtWait(pin, HIGH, &ok);      // measure how long it stays high
    unsigned long width = micros() - t0;
    if (!ok) return 0;
    data[i >> 3] = (uint8_t)((data[i >> 3] << 1) | (width > 40 ? 1 : 0));
  }
  return 1;
}

void setup() {
  Serial.begin(9600);

  uint8_t d[5];
  if (!dhtRead(DHT_PIN, d)) {
    Serial.println("dht error");
    return;
  }

  uint8_t sum = (uint8_t)(d[0] + d[1] + d[2] + d[3]);
  Serial.print("raw");
  for (uint8_t i = 0; i < 5; i++) {
    Serial.print(' ');
    if (d[i] < 16) Serial.print('0');
    Serial.print(d[i], HEX);
  }
  Serial.print(" ok ");
  Serial.println(sum == d[4] ? 1 : 0);

  // Decode as a DHT22 (16-bit tenths; temperature bit 15 is the sign).
  int16_t h = (int16_t)((d[0] << 8) | d[1]);
  int16_t t = (int16_t)((d[2] << 8) | d[3]);
  uint8_t neg = (t & 0x8000) != 0;
  if (neg) t = (int16_t)(t & 0x7FFF);
  Serial.print("t ");
  if (neg) Serial.print('-');
  Serial.print(t / 10);
  Serial.print('.');
  Serial.println(t % 10);
  Serial.print("h ");
  Serial.print(h / 10);
  Serial.print('.');
  Serial.println(h % 10);
}

void loop() {
}
