# Firmware harness (M7 spike)

This is the **Stage B proof** that CircuitForge 3D can execute real Arduino
firmware without vendoring a GPL engine. It is a **spike**, not the product: the
Godot test suite never requires it, and only the app's capability-flagged tools
call it. It closes the loop in both directions — firmware reads the solved circuit
(ADC inputs, I2C devices) and drives it back (`mcu_pin`s, PWM outputs, device state).

## What it does

1. `arduino-cli` (external tool) compiles a sketch for `arduino:avr:uno` to Intel HEX.
2. `harness/run.mjs` loads that HEX into **avr8js** (MIT) — a pure-JS ATmega328P —
   wires up timer0/1/2, ports B/C/D, USART0, TWI, SPI and ADC, runs one instruction
   at a time and prints digital pin transitions (with a per-pin PWM duty summary),
   captured `Serial` output and I2C/SPI bus traces as JSON with emulated timestamps.
   By default the buses have **no device** (I2C is ACKed and recorded, SPI MISO
   returns 0x00); with `CF_DEVICES` a PCF8574/EEPROM is served on the bus.

avr8js is **MIT**, so it can be shipped alongside the MIT app; `arduino-cli` and
Node are treated as optional external tools, never bundled. See
`../docs/plan/m7_firmware_backend.md` for the full rationale and gate criteria.

## Run it

```sh
# 1. compile (external tools; not required by the Godot test suite)
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/blink firmware/sketches/blink
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/serial_hello firmware/sketches/serial_hello
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/i2c_write firmware/sketches/i2c_write
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/expander firmware/sketches/expander
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/expander_read firmware/sketches/expander_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/analog_read firmware/sketches/analog_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/pwm_out firmware/sketches/pwm_out
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/eeprom_roundtrip firmware/sketches/eeprom_roundtrip
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/eeprom_read firmware/sketches/eeprom_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/pcf8591_read firmware/sketches/pcf8591_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/pcf8591_dac firmware/sketches/pcf8591_dac

# 2. execute + inspect
cd firmware/harness
npm install
node run.mjs ../build/blink/blink.ino.hex 2500 > blink.json
node run.mjs ../build/serial_hello/serial_hello.ino.hex 2200 > serial.json
node run.mjs ../build/i2c_write/i2c_write.ino.hex 2200 > i2c.json

# 3. verify (exit 0/1)
node verify.mjs ../build/blink/blink.ino.hex
node verify_serial.mjs ../build/serial_hello/serial_hello.ino.hex
node verify_i2c.mjs ../build/i2c_write/i2c_write.ino.hex
node verify_expander_read.mjs ../build/expander_read/expander_read.ino.hex
node verify_analog.mjs ../build/analog_read/analog_read.ino.hex
node verify_pwm.mjs ../build/pwm_out/pwm_out.ino.hex
node verify_eeprom.mjs ../build/eeprom_roundtrip/eeprom_roundtrip.ino.hex
node verify_pcf8591.mjs ../build/pcf8591_read/pcf8591_read.ino.hex
```

`verify.mjs` asserts D13 (PB5) is a clean ~500 ms square wave (edge gaps
500.009/500.008/500.012/500.011 ms). `verify_serial.mjs` asserts the sketch's
`Serial.print` output is captured (`CircuitForge tick 0…4`, 105 bytes).
`verify_i2c.mjs` asserts a Wire write to `0x27` with bytes `0x00,0x41` is recorded
as an I2C bus trace. `sketches/expander` writes the port byte `0x55` to a PCF8574
at `0x27`; the app's `apply_firmware_device` tool consumes that byte to set the
device's `state` (P0..P7 = 1,0,1,0,1,0,1,0).

## Devices on the bus (closed loop)

`run.mjs` reads an optional `CF_DEVICES` environment variable — a JSON array of
device specs — and serves the matching I2C addresses, so firmware can *read* a
device (device → firmware feedback), not just trace writes:

```sh
# PCF8574 at 0x27 with P0..P3 externally held low -> reads return 0xF0
CF_DEVICES='[{"kind":"pcf8574","address":39,"state":255,"inputs":15}]' \
  node run.mjs ../build/expander_read/expander_read.ino.hex 2200

# 24C02 EEPROM at 0x50: store a byte then read it back (prints "eeprom 165")
CF_DEVICES='[{"kind":"eeprom","address":80,"size":256,"init":[]}]' \
  node run.mjs ../build/eeprom_roundtrip/eeprom_roundtrip.ino.hex 600

# PCF8591 ADC at 0x48 with AIN0 = 2.5 V over a 5 V reference -> reads code 128
CF_DEVICES='[{"kind":"pcf8591","address":72,"ain":[2.5,0,0,0],"vref":5}]' \
  node run.mjs ../build/pcf8591_read/pcf8591_read.ino.hex 400
```

Supported `kind`s: `pcf8574` (`state`, `inputs`), `eeprom` (`address`, `size`,
`init`) and `pcf8591` (`address`, `ain`, `vref`); the EEPROM summary also returns
the memory image (`mem`). The app does this automatically:
`run_firmware(..., attach_devices=true)` builds the specs from the circuit's
`pcf8574`, `eeprom_i2c` and `pcf8591` components (a `pcf8591`'s `ain` values come
from the solved node voltages).

## Analog inputs (circuit → firmware)

`run.mjs` also reads `CF_ADC`, a JSON map of ADC channel → volts, and feeds it to
the AVR's ADC so `analogRead()` reads a real voltage:

```sh
# analogRead(A0) reads 2.5 V -> code 512
CF_ADC='{"0":2.5}' node run.mjs ../build/analog_read/analog_read.ino.hex 1600
```

The app does this automatically: `run_firmware(..., analog_map={"A0": "AIN1"})`
solves the circuit and feeds each `mcu_analog_in` node's voltage to the channel.

## Analog outputs (firmware → circuit)

The run output also carries a `pwm` summary: for every digital pin that toggled
rapidly enough (≥ 4 edges) it reports the average `duty` cycle, approximate
`freq_hz` and the edge count.

```sh
# analogWrite(9,128) -> ~50.2% duty at ~490 Hz
node run.mjs ../build/pwm_out/pwm_out.ino.hex 2000
```

The app consumes it: `apply_firmware_pwm(hex_path, pin_map={"9": "PWM1"})` sets the
matching `mcu_pwm_out` component's `voltage` to `duty * vlogic` (the DC average), so
firmware's `analogWrite()` drives the circuit. `verify_pwm.mjs` asserts the duty for
`analogWrite(9,128)`.

These steps are **not** part of `tests/run_tests.gd`: the Godot suite must stay
runnable with only Godot installed. They are run manually / in a separate job.
