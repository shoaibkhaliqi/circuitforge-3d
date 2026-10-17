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
4. **Stage B** was originally open-loop (firmware drives the circuit; analog does
   not drive the firmware yet), and **Stage C** feeds analog values back into the
   MCU's ADC to close the loop. Executed in practice: the analog *input* loop
   (§10) and the analog *output* loop (§11) are both closed, so the implemented
   Stage B already reads the circuit back into the firmware.

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
- [x] Status changes backed by tests — **`pcf8574` `planned` → `partial`** is
      backed by a real firmware test (`firmware/sketches/expander` → state `0x55`,
      §9) plus Node-free mapping tests; other protocol parts stay `planned`/`visual`
      until they get the same treatment.

**Outcome:** technical feasibility is **confirmed** for the permissive path. The
harness is now wired into the app (open loop): `FirmwareBackend` +
`get_firmware_capabilities` / `run_firmware` / `apply_firmware_pins` run a HEX and
drive real `mcu_pin` components from firmware output at a chosen instant. Verified
end-to-end: with a 1 kΩ pin-to-ground load, D13 at 100 ms (HIGH) solves the signal
node to 4.878 V (= 5 V · 1000/1025). The first device, the **PCF8574** (§9), is now
modelled and firmware-driven, so its catalog label is honestly `partial`.

### Protocol surfaces: UART, I2C, SPI

The harness instantiates USART0, TWI and SPI, so firmware's protocol traffic is
observable through the engine:

- **UART**: every transmitted byte is captured; `run_firmware` returns `serial` /
  `serial_lines`. Verified with `firmware/sketches/serial_hello` ("CircuitForge
  tick 0…4", 105 bytes over 2.2 s).
- **I2C (TWI)**: a trace handler records each transaction (address, direction,
  bytes). There is **no device** on the bus — the harness ACKs so a sketch's Wire
  transaction completes and reads return 0xFF. Verified with
  `firmware/sketches/i2c_write`: transactions to `0x27` with data `[0x00, 0x41]`,
  surfaced as `i2c` / `i2c_addresses` (`["0x27"]`).
- **SPI**: MOSI bytes are recorded (`spi_bytes`); MISO returns 0x00 (no device).

This is the groundwork for protocol parts: a bus where firmware output is the
observable. The next step — modelling the device at the other end — started with
the PCF8574 below.

## 9. First device: PCF8574 I2C I/O expander (executed)

`pcf8574` (`data/components/analog_ic.json`) is the first *bus* part upgraded from
`planned` to **`partial`** on the strength of a real firmware path:

- **Model**: the netlist maps the device `state` byte to eight ideal
  quasi-bidirectional `gpio` outputs P0..P7 against VSS (default `rout` 1 kΩ,
  approximating the part's weak pull-up; a Thevenin level, so `state` is directly
  settable and also firmware-writable).
- **Firmware path (both directions)**: `apply_firmware_device` runs a HEX, takes the
  last byte the firmware wrote to the device's I2C address
  (`FirmwareBackend.last_i2c_write_byte`, default address `0x27`) and sets `state`
  from it, optionally re-solving DC. In the other direction, `run_firmware(...,
  attach_devices=true)` attaches the circuit's `pcf8574` (`state`/`inputs`/`address`)
  to the emulated bus, so firmware can **read** it: a port bit held externally low
  (`inputs`) reads back as 0 (`(state & ~inputs)`). This is the closed bus loop —
  device state drives firmware, firmware output drives the device.
- **Verified**: `firmware/sketches/expander` writes `0x55` to `0x27`; the device
  ends at `state=0x55` with port levels `[1,0,1,0,1,0,1,0]` (address `0x27`).
  `firmware/sketches/expander_read` writes `0xFF` then reads the port; with
  `inputs=0x0F` the firmware reads `0xF0` (`Serial` prints "port 240") — asserted by
  `firmware/harness/verify_expander_read.mjs`. Node-free mapping is covered by
  `tests/unit/test_netlist.gd`; the byte helpers by `tests/unit/test_firmware.gd`
  (`last_i2c_write_byte` / `last_i2c_read_byte`); the tool surface by MCP Test B6.
- **Still limited**: only one device type is modelled, and the electrical solver is
  not in the loop (analog/ADC feedback is absent; `inputs` is a parameter, not a
  solved node voltage). Other protocol parts stay `planned` until they get the same
  treatment.

## 10. Analog loop: `mcu_analog_in` → `analogRead()` (executed)

The AVR's own ADC is now in the loop. New virtual part **`mcu_analog_in`**
(`data/components/virtual.json`, `partial`) is an ideal high-impedance probe:
the netlist emits a 1 GΩ resistor to ground (draws ~nA, so it never loads the
circuit meaningfully and needs a ground elsewhere), and the node keeps its solved
voltage.

- **Harness**: instantiates `AVRADC(cpu, adcConfig)`; `CF_ADC` (a JSON map of
  channel → volts) sets `adc.channelValues`. `analogRead(Ax)` then returns the
  converted code; the run output adds `adc`.
- **App**: `run_firmware(..., analog_map={"A0": "AIN1"})` builds the circuit,
  solves DC, and feeds each mapped `mcu_analog_in` component's node voltage
  (clamped to 0..5 V) to the matching ADC channel; the response adds `adc` and
  `analog_inputs`. This is circuit → firmware analog feedback.
- **Verified**: `firmware/sketches/analog_read` + `verify_analog.mjs` → 2.5 V reads
  as code 512; end-to-end, a 4 V source across 1 kΩ + 1 kΩ solves the midpoint to
  2.0 V and `analogRead(A0)` returns 409. Node-free probe mapping is covered by
  `tests/unit/test_netlist.gd`; the tool surface by MCP Test B7.

## 11. Output loop: `analogWrite()` → `mcu_pwm_out` (executed)

The last direction — firmware → circuit, analog — is now closed. New virtual part
**`mcu_pwm_out`** (`data/components/virtual.json`, `partial`) models a PWM pin as
its DC **average**: an ideal Thevenin source `vout` at `duty · vlogic` in series
with `rout` (default 25 Ω). No ripple, frequency response or dead-time is modelled,
so it is only correct *on average* (a switch-mode load is idealised).

- **Harness**: from the recorded pin transitions it computes each pin's duty cycle
  (`pwm` summary: `duty`, `freq_hz`, `ms_high`, `edges`; pins with <4 edges are not
  PWM). `AVRADC` is unaffected.
- **App**: `apply_firmware_pwm(hex_path, pin_map={"9": "PWM1"})` measures the duty on
  the mapped pins and sets the target's `voltage` to `duty · vlogic`, optionally
  re-solving DC. The matching engine method is `FirmwareBackend.pwm_duty()`.
- **Verified**: `firmware/sketches/pwm_out` (`analogWrite(9,128)`) +
  `verify_pwm.mjs` measure ~50.2% duty at ~490 Hz; end-to-end that drives a
  `mcu_pwm_out` to 2.509 V, which with a 1 kΩ load sags to 2.448 V. Mapping is
  covered by `tests/unit/test_netlist.gd`; the tool surface by MCP Test B8.

## 12. Recommendation

The originally suggested `simavr` (GPL) spike is superseded by the working
**avr8js (MIT)** result above for the same reason §4 prefers it: no GPL is
vendored into the MIT binary. The sidecar `get_firmware_capabilities` /
`run_firmware` / `apply_firmware_pins` / `apply_firmware_device` surface in §5 is
now built on top of `firmware/harness/run.mjs`, and the PCF8574 (§9) is the first
catalog status change backed by a real firmware-driven test. The bus loop is closed
for the PCF8574 (§9): firmware reads device state and writes it back. The analog
input loop is also closed (§10): `mcu_analog_in` feeds the AVR `analogRead()` from
the solved circuit, and the analog output loop (§11) drives the circuit from
`analogWrite()` via `mcu_pwm_out`. Remaining work: link the analog surface to
specific *devices* (e.g. an I²C ADC's channels from solved nodes), more device
models (LCD/OLED, EEPROM through the app, DHT, ultrasonic), and a
streaming/interactive mode if a blocking run proves too coarse. If the app-side
integration ever cannot meet the gate (e.g. timing or packaging), fall back to a
separately-installed `simavr` and keep the feature capability-flagged.
