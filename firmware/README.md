# Firmware harness (M7 spike)

This is the **open-loop (Stage B) proof** that CircuitForge 3D can execute real
Arduino firmware without vendoring a GPL engine. It is a **spike**, not the
product: nothing in the app calls it yet, and it does not touch the solver.

## What it does

1. `arduino-cli` (external tool) compiles a sketch for `arduino:avr:uno` to Intel HEX.
2. `harness/run.mjs` loads that HEX into **avr8js** (MIT) — a pure-JS ATmega328P —
   wires up timer0/1/2, ports B/C/D, USART0, TWI and SPI, runs one instruction at a
   time and prints digital pin transitions, captured `Serial` output and I2C/SPI
   bus traces as JSON with emulated timestamps. The buses have **no device**: I2C
   transactions are ACKed and recorded, SPI MISO returns 0x00.

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
```

`verify.mjs` asserts D13 (PB5) is a clean ~500 ms square wave (edge gaps
500.009/500.008/500.012/500.011 ms). `verify_serial.mjs` asserts the sketch's
`Serial.print` output is captured (`CircuitForge tick 0…4`, 105 bytes).
`verify_i2c.mjs` asserts a Wire write to `0x27` with bytes `0x00,0x41` is recorded
as an I2C bus trace. `sketches/expander` writes the port byte `0x55` to a PCF8574
at `0x27`; the app's `apply_firmware_device` tool consumes that byte to set the
device's `state` (P0..P7 = 1,0,1,0,1,0,1,0).

These steps are **not** part of `tests/run_tests.gd`: the Godot suite must stay
runnable with only Godot installed. They are run manually / in a separate job.
