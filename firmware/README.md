# Firmware harness (M7 spike)

This is the **open-loop (Stage B) proof** that CircuitForge 3D can execute real
Arduino firmware without vendoring a GPL engine. It is a **spike**, not the
product: nothing in the app calls it yet, and it does not touch the solver.

## What it does

1. `arduino-cli` (external tool) compiles a sketch for `arduino:avr:uno` to Intel HEX.
2. `harness/run.mjs` loads that HEX into **avr8js** (MIT) — a pure-JS ATmega328P —
   wires up timer0/1/2 and ports B/C/D, runs one instruction at a time and prints
   every digital pin transition as JSON with emulated timestamps.

avr8js is **MIT**, so it can be shipped alongside the MIT app; `arduino-cli` and
Node are treated as optional external tools, never bundled. See
`../docs/plan/m7_firmware_backend.md` for the full rationale and gate criteria.

## Run it

```sh
# 1. compile (external tools; not required by the Godot test suite)
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/blink firmware/sketches/blink

# 2. execute + inspect
cd firmware/harness
npm install
node run.mjs ../build/blink/blink.ino.hex 2500 > blink.json

# 3. verify the blink is deterministic (exit 0/1)
node verify.mjs ../build/blink/blink.ino.hex
```

`verify.mjs` asserts D13 (PB5) is a clean ~500 ms square wave. On the reference
host the edge gaps are 500.009/500.008/500.012/500.011 ms.

These steps are **not** part of `tests/run_tests.gd`: the Godot suite must stay
runnable with only Godot installed. They are run manually / in a separate job.
