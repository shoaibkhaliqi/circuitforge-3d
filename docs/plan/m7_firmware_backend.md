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
- **Still limited**: the electrical solver is not *driven* by the expander's bus
  traffic (its pins map to `state`/`inputs` parameters, not solved node voltages);
  the analog feedback that closes the loop is covered in §10–§11. Other protocol
  parts stay `planned` until they get the same treatment.

## 9b. Second device: 24C02 I2C EEPROM (executed)

`eeprom_i2c` (`data/components/analog_ic.json`) is the first **`external`** part
added for the firmware backend — it has *no* breadboard electrical model (so it is
not in `HANDLED_TYPES`), and is served on the I2C bus only while firmware runs:

- **Model**: the harness `eeprom` device implements the standard two-byte address
  then data write with an auto-incrementing pointer, and sequential reads; it
  returns the resulting memory image as `devices[].mem`.
- **Path**: `run_firmware(..., attach_devices=true)` attaches the circuit's
  `eeprom_i2c` (`address` default `0x50`, `size` default 256).
- **Verified**: `firmware/sketches/eeprom_roundtrip` stores `0xA5` at 0x0000 and
  reads it back (`Serial` "eeprom 165"); `eeprom_read` reads the stored byte;
  `firmware/harness/verify_eeprom.mjs` asserts both. `tests/unit/test_netlist.gd`
  asserts `eeprom_i2c` is `external` and *not* solver-mapped; the tool surface by
  MCP Test B9.
- **Limits (honest)**: timing, write-cycle delay, page boundaries, the WP pin, ACK
  polling, endurance and data retention across *separate runs* are not modelled —
  the memory lives only for the duration of one run.

## 9c. Third device: PCF8591 I2C ADC/DAC (executed)

`pcf8591` (`data/components/analog_ic.json`, **`partial`**) is the first device
whose analog channels come from the *solved* circuit — closing the "analog surface
to a specific device" item:

- **Model**: the netlist maps AIN0..AIN3 to ideal 1 GΩ ADC probes and AOUT to an
  ideal Thevenin DAC output (`vout` at `aout`, `rout` default 25 Ω).
- **Read (circuit → firmware)**: `run_firmware(..., attach_devices=true)` solves the
  circuit and serves the part on the bus with each AIN channel's node voltage; the
  harness `pcf8591` device converts to an 8-bit code over `vref` (default 5 V) and
  honours the control byte's channel select and auto-increment. The run adds `ain`
  and `read` per device.
- **Write (firmware → circuit)**: `apply_firmware_device` sets the DAC `aout` from
  the last byte firmware writes (`byte/255 * vref`), optionally re-solving.
- **Verified**: `firmware/sketches/pcf8591_read` reads a 2.0 V divider midpoint as
  code 102 end-to-end; `pcf8591_dac` writes `0x80` → `aout` 2.510 V.
  `firmware/harness/verify_pcf8591.mjs` asserts 2.5 V → code 128; the mapping by
  `tests/unit/test_netlist.gd`; the tool surface by MCP Test B10.
- **Limits (honest)**: the read pipeline (the real part returns the previous
  conversion first), conversion/auto-increment timing, `EXT`/`OSC` and the digital
  bus itself are not modelled; the DAC is an ideal average/source, not a real
  buffered output with offset/linearity error.

## 9d. Fourth device: 16x2 I2C character LCD (executed)

`i2c_lcd1602` (`data/components/displays.json`, **`external`**) is the first
firmware-driven *display*. The backpack is a PCF8574, so the harness reuses the I2C
byte stream but decodes the HD44780 4-bit protocol instead of a GPIO port:

- **Model**: bit0 = RS, bit1 = RW, bit2 = E, bit3 = backlight, bits4..7 = D4..D7; a
  nibble is latched on the E falling edge and two nibbles make a byte. The decoder
  tracks clear/home, DDRAM (cursor) and CGRAM address commands and character writes,
  and returns the visible text as `devices[].lines`.
- **Path**: `run_firmware(..., attach_devices=true)` attaches the circuit's
  `i2c_lcd1602` (`address` default `0x27`, `cols`, `rows`).
- **Verified**: `firmware/sketches/lcd_hello` (a hand-written 4-bit driver, no
  external library) shows "CircuitForge" / "3D"; `firmware/harness/verify_lcd.mjs`
  asserts the decoded lines; `tests/unit/test_netlist.gd` asserts `i2c_lcd1602` is
  `external` and *not* solver-mapped; the tool surface by MCP Test B11.
- **Limits (honest)**: instruction timing, the busy flag, CGRAM custom glyphs,
  display/cursor shifting, scrolling and backlight PWM are not modelled; the text is
  decoded from the command stream, not rendered.

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

## 11b. Fifth device: HC-SR04 ultrasonic (firmware → MCU *input* pin)

Closes the last missing direction at the **pin** level: until now firmware could
*drive* pins and *read* the ADC and bus devices, but no attached part could drive an
MCU **input** pin from within a run. `hcsr04` (`data/components/sensors.json`,
`external`) does exactly that.

- **Model**: the harness watches the firmware's TRIG pulse; on its falling edge
  (after a ≥ 5 µs high pulse) it waits a 200 µs propagation delay and then drives
  ECHO — an MCU input pin — high for `distance_cm · 58 µs` (the round-trip time),
  so `pulseIn(ECHO, HIGH)` measures a real echo. Edges are queued and applied from
  the run loop (never from inside the GPIO write, so the port model isn't re-entered).
- **Path**: `run_firmware(..., pin_map={"9": "<TRIG pin comp>", "10": "<ECHO pin comp>"})`.
  The `pin_map` (firmware digital pin → component id) mirrors `analog_map`; an
  `hcsr04` whose TRIG/ECHO nets are shared with those components resolves its pin
  numbers from the netlist. The result adds `pin_devices` and `pin_inputs`.
- **Verified**: `firmware/sketches/ultrasonic` reports `echo 1735 dist 30` for a
  30 cm target; `firmware/harness/verify_ultrasonic.mjs` asserts the round-trip time
  (within 60 µs) and the distance (±1 cm) — also checked at 5/100/400 cm. The mapping
  is covered by `tests/unit/test_netlist.gd`; the tool surface by MCP Test B12.
- **Limits (honest)**: it is an idealisation — no acoustic spread, beam angle,
  minimum/maximum range, temperature dependence or the 60 ms measurement cycle;
  `pulseIn`'s own loop granularity makes the measured time run ~0.3–0.6% short.

## 11c. Sixth device: MPU-6050 IMU (served I2C register file)

The first **register-map** device: instead of a single value, the harness serves a
register file, so firmware can use the same read/write pattern a real sensor driver
does. `mpu6050` (`data/components/sensors.json`, `external`).

- **Model**: a 0x80-byte register file. A write transaction's first byte sets the
  register pointer and further bytes write + auto-increment; reads return the register
  at the pointer and auto-increment — so a burst read of 0x3B..0x48 works, and both
  stop and repeated-start transactions are handled. WHO_AM_I (0x75) = 0x68; the accel
  (0x3B), temperature (0x41) and gyro (0x43) counts are filled from the component's
  `ax`..`gz`/`temp_c` parameters at full-scale defaults (16384 LSB/g, 131 LSB/(deg/s),
  340 LSB/degC).
- **Path**: `run_firmware(..., attach_devices=true)` attaches the circuit's `mpu6050`
  (`address`/`ax`..`gz`/`temp_c`); the response's `devices[]` reports `who_am_i`,
  `accel_raw`, `gyro_raw` and `temp_c`.
- **Verified**: `firmware/sketches/mpu6050_read` (WHO_AM_I + a 14-byte burst) +
  `verify_mpu6050.mjs` decode the served values exactly (0.5/-0.25/1 g → 8192/-4096/16384,
  10/-20/250 °/s → 1310/-2620/32750, 26.53 °C → 2653). Mapping is covered by
  `tests/unit/test_netlist.gd`; the tool surface by MCP Test B13.
- **Limits (honest)**: only the sample/output registers are modelled — configuration
  registers (DMP, FIFO, filters, interrupts), the INT pin, timing, self-test and noise
  are not. The register file is ideal: writes are stored but change no behaviour.

## 11d. Seventh device: SSD1306 OLED (framebuffer)

The first **framebuffer** device: instead of a value or a register map the harness
tracks the panel's GDDRAM, so firmware that draws pixels can be checked. `oled_ssd1306`
(`data/components/displays.json`, `external`).

- **Model**: each I2C write transaction's first byte is a control byte (bit6 = D/C:
  0 = command, 1 = data). Commands are decoded (page/horizontal/vertical addressing via
  0x20, the 0x21/0x22 column/page ranges, B0-B7 column-set, 0xAE/0xAF display on/off);
  data bytes write GDDRAM with the addressing-mode auto-increment. The frame is returned
  as `devices[].pages_hex` (one hex string per page) plus `pixels_set` and `display_on`.
- **Path**: `run_firmware(..., attach_devices=true)` attaches the circuit's
  `oled_ssd1306` (`address`/`cols`/`pages`).
- **Verified**: `firmware/sketches/oled_fill` (hand-written init, no library) fills the
  top half; `verify_oled.mjs` asserts 4096 lit pixels and the exact per-page hex.
  Mapping is covered by `tests/unit/test_netlist.gd`; the tool surface by MCP Test B14.
- **Limits (honest)**: no panel optics (contrast/charge-pump effects), no hardware
  scroll (0x2E/0x2F), no font — the harness decodes pixels, not text — and the display's
  own timing/refresh is not modelled.

## 11e. Eighth device: rotary encoder (quadrature pin device)

The second **pin** device after the HC-SR04, and the first *input-only* one: the
harness drives an MCU input pair, so a firmware-side decoder can be checked.
`rotary_encoder` (`data/components/sensors.json`, `external`).

- **Model**: the harness walks the canonical Gray cycle `(A,B) = 00 → 10 → 11 → 01`
  (or the reverse) from the power-on state, changing exactly one pin per count, so a
  polling decoder never sees an illegal two-bit hop. `counts` steps are emitted from
  `start_us`, one per `step_us`; each is queued like the HC-SR04's ECHO pulse and
  applied from the run loop. Honest limit: the steps are ideal (no contact bounce).
- **Path**: `run_firmware(..., pin_map={"2": "A", "3": "B"})` resolves the encoder's
  A/B nets from the netlist (the same mechanism as the HC-SR04).
- **Verified**: `firmware/sketches/encoder_read` (a hand-written quadrature table
  decoder, no library) counts 50 steps clockwise, 50 counter-clockwise and 200 at a
  500 µs step; `verify_encoder.mjs` asserts each case and that an arbitrary pin pair
  schedules without error. Mapping is covered by `tests/unit/test_netlist.gd`; the tool
  surface by MCP Test B15.
- **Limits (honest)**: no detent/bounce physics, no acceleration model, no electrical
  loading, and the push switch (`SW`) is just another digital input — wire it to an
  `mcu_pin` if you want to read it.

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
`analogWrite()` via `mcu_pwm_out`. Devices now cover the PCF8574 expander (§9),
the 24C02 EEPROM (§9b) and the PCF8591 ADC/DAC (§9c) — whose channels come from the
solved nodes, linking the analog surface to a specific device — and the I2C 16x2 LCD
(§9d), which closes the display item. The HC-SR04 (§11b) adds the missing direction
at the *pin* level: a part that drives an MCU input pin from inside a run, so
`pulseIn()`/timing sketches work. The MPU-6050 (§11c) adds a served *register map*,
so driver-style multi-register reads work, and the SSD1306 (§11d) adds a *framebuffer*,
so drawing code can be checked. The rotary encoder (§11e) adds a second pin device — an
ideal quadrature pair — so input-decoding sketches can be checked without a library.
Remaining work: more device models (DHT), a bundled firmware example project, and a
streaming/interactive mode if a blocking run proves too coarse. If the app-side
integration ever cannot meet the gate (e.g. timing or packaging), fall back to a
separately-installed `simavr` and keep the feature capability-flagged.
