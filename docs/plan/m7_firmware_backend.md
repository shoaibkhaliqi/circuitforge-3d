# M7 feasibility — code-execution (firmware) backend

Status: **assessment only — nothing here is implemented.** This document is the
gate the plan requires before any firmware feature is integrated. It exists so we
can decide *whether* and *how* to add real MCU code execution without ever
claiming a capability we do not have.

## 1. Why this is gated

Parts that only do something when code runs (I2C/SPI displays, DHT/ultrasonic
sensors, PWM, servo pulses, stepper sequences) cannot be simulated truthfully by
the MNA solver alone. Faking them would break the project's core rule: a
`full`/`partial` claim must map to a real model (`NetlistBuilder.handles()` +
`tests/unit/test_netlist.gd`). So they stay `planned`/`visual` until a **real**
code-execution engine is wired in.

The current **Stage A** (`mcu_pin` → the `gpio` element) already drives digital
pins by hand (ideal Thevenin source, level high/low/high-Z). That is enough to
light a 7-segment display or exercise logic. Firmware execution would replace the
hand-set pin levels with levels produced by an actual program.

## 2. Target priorities

1. **AVR / Arduino (Uno, Nano, Mega)** — the dominant beginner target and the
   simplest 8-bit core; some AVR parts have ≤128 KB flash.
2. ARM Cortex-M (STM32, RP2040), ESP32 (Xtensa/RISC-V), MSP430 — later; each adds
   a new core and toolchain.

## 3. Candidate engines (researched, not yet integrated)

| Engine | License | Platforms | Cores | Notes |
|--------|---------|-----------|-------|-------|
| **simavr** (libsimavr) | GPL-3.0 | Linux, macOS (Windows via build) | AVR (≤128 KB flash) | Loads ELF/iHEX; has a small C harness API and a GDB server; widely used for Arduino co-sim. |
| **simulavr** | GPL-2.0 | Linux (build scripts not ready for Windows/macOS) | AVR (ATtiny/ATmega) | Library + CLI + Python/TCL interface; GDB back-end. |
| **avr8js** | MIT | Anywhere Node/browser runs | AVR (8-bit) | Pure JS/TS AVR core (the engine behind Wokwi); permissive, so it can ship with an MIT app. |
| **Renode** | MIT | Windows/macOS/Linux (.NET) | Cortex-M, RISC-V, RP2040 (AVR support is limited) | Permissive, but heavy and not AVR-first. |
| **Espressif QEMU** | GPL-2.0 | Win/macOS/Linux | ESP32 family | For ESP32 only. |
| **Microchip AVR Simulator** | proprietary | Windows (inside Microchip Studio) | AVR | Not redistributable; dev-tool only. |

Compilation off the shelf is **arduino-cli** (GPL-3.0) or `avr-gcc` + `avr-libc`
(GPL), producing the ELF/HEX the engines consume.

## 4. The licensing decision (important — the app is MIT)

Bundling a **GPL** engine (simavr/simulavr) *inside* our distributed binary would
effectively relicense CircuitForge 3D. Two honest ways to avoid that:

- **External sidecar (recommended).** The firmware engine and `arduino-cli` are
  *separately installed programs* the user provides; CircuitForge talks to them
  over a local process boundary, exactly like the existing MCP server is a
  separate process. The MIT app stays MIT; the GPL tools stay the user's.
- **Permissive engine.** Use **avr8js (MIT)** under a small Node harness (Node is
  itself already a plausible optional sidecar), so nothing GPL is vendored.

Either way the firmware path is **optional and external**, consistent with the
project's offline, no-secret, local-only design.

## 5. Integration shape (Stage B / C)

1. **Compile** — `arduino-cli compile` (or `avr-gcc`) turns a sketch into an ELF.
2. **Run** — the chosen engine executes the ELF on a virtual AVR at the sketch's
   clock (e.g. 16 MHz).
3. **Co-simulate** — the MCU's pin transitions are streamed (timestamp, pin,
   level) to the app, which stamps them into the MNA solver as time-varying
   `gpio`/`vsource` sources. This reuses the existing Stage-A `gpio` element and
   the line-JSON local API (`scripts/api/`).
4. **Stage B** is open-loop (firmware drives the circuit; analog does not drive
   the firmware yet). **Stage C** feeds analog values back into the MCU's ADC to
   close the loop.

### Proposed API additions (not implemented)

- `load_firmware(sketch_dir | hex_path) -> {ok, size, mcu}`
- `start_mcu(freq_hz) / stop_mcu()`
- `read_pins(since_ms) -> [{t_ms, pin, level}, ...]`
- New resource: firmware status (running, cycles, last error).

## 6. Gate criteria (must all hold before coding)

- [ ] A chosen engine **builds and runs on Windows** for an Arduino Uno/ATmega328P
      ELF (the primary platform; Linux is the second target).
- [ ] **License** is compatible with shipping an **MIT** app (external sidecar or
      a permissive engine). No GPL code vendored into the MIT binary.
- [ ] **Board coverage** is stated honestly (AVR first; everything else "planned").
- [ ] Deterministic, reproducible timing for a blink/tone example; documented
      accuracy limits (not cycle-accurate against external analog).
- [ ] Every new catalog status change is backed by a passing test, exactly like
      Stage A.

## 7. Non-claims / risks

- Mixed-signal co-simulation timing is **approximate**; we will say so.
- Windows support for the AVR engines (esp. simavr) may need a local build — an
  install step, not a bundled dependency.
- Building our own AVR interpreter is **rejected**: large, error-prone, and would
  duplicate mature engines.
- ESP32/STM32/MSP430 are explicitly out of the first spike.

## 8. Spike result (executed)

A time-boxed Windows spike was run with the **permissive** path from §4/§5, using
tools already present on the host (`arduino-cli 1.5.1` + `arduino:avr 1.8.8`,
Node). The `simavr`/GPL path was not needed for the spike to succeed.

- `firmware/sketches/blink/blink.ino` — a 1 Hz blink on D13.
- `arduino-cli compile --fqbn arduino:avr:uno` → `blink.ino.hex` (924 bytes, 2% flash).
- `firmware/harness/run.mjs` loads the HEX into **avr8js 0.21** (MIT), wires up
  timer0/1/2 + ports B/C/D, runs instruction-by-instruction and prints pin
  transitions with emulated timestamps.
- Observed, deterministic D13 (PB5) activity over 2.5 s:

  ```
  t=0.014ms B5=1   t=500.023ms B5=0   t=1000.031ms B5=1
  t=1500.043ms B5=0  t=2000.054ms B5=1
  ```

- `firmware/harness/verify.mjs` asserts a clean ~500 ms square wave and passes
  (edge gaps 500.009 / 500.008 / 500.012 / 500.011 ms).

### Gate criteria (§6) — spike outcome

- [x] Builds and runs on **Windows** for an ATmega328P program (HEX; arduino-cli
      can also emit ELF).
- [x] **License** compatible with an MIT app: engine is **avr8js (MIT)**; Node and
      `arduino-cli` stay external tools, nothing GPL vendored.
- [x] **Board coverage** stated honestly: AVR/ATmega328P only in the spike.
- [x] **Deterministic, reproducible timing** for blink (reproducible via
      `verify.mjs`); limits documented (§7).
- [ ] Status changes backed by tests — no catalog status is changed yet; the
      protocol parts stay `planned`/`visual` until the app actually consumes the
      harness. This is the remaining step before flipping any status.

**Outcome:** technical feasibility is **confirmed** for the permissive path. The
next increment is wiring `run.mjs`'s JSON into the app (a sidecar + the §5 API)
and feeding transitions into the existing `gpio` element. Until that is done and
tested, the catalog labels do not change.

## 9. Recommendation

The originally suggested `simavr` (GPL) spike is superseded by the working
**avr8js (MIT)** result above for the same reason §4 prefers it: no GPL is
vendored into the MIT binary. Build the sidecar `load_firmware` / `start_mcu` /
`read_pins` surface in §5 on top of `firmware/harness/run.mjs`. If the app-side
integration cannot meet the gate (e.g. timing or packaging), fall back to a
separately-installed `simavr` and keep the feature capability-flagged.
