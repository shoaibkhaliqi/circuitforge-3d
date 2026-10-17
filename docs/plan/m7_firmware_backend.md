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

## 8. Recommendation

Run a **time-boxed Windows spike**: `arduino-cli` compile + **simavr** (via a tiny
C harness or its CLI/VCD output) for ATmega328P, streamed over a sidecar process,
feeding the existing `gpio` element. If the spike passes the gate criteria, add
the API surface in §5 behind an "external firmware backend" capability flag. If it
does not, the feature stays gated and the catalog keeps its honest
`planned`/`external` labels.
