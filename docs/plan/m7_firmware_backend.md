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
- **SPI**: MOSI bytes are recorded (`spi_bytes`) and MISO is driven by whichever served
  device is selected — with no device attached it stays 0x00, and the MCP3008 (§11n) is the
  part that answers reads on it.
  The trace is capped at 4096 bytes by default (`CF_SPI_LIMIT`) with the true length in
  `spi_byte_count`, because a full-screen frame is 150k+ bytes; a trimmed trace is never
  presented as the whole one.

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

## 11f. Ninth + tenth devices: DHT11/DHT22 (one-wire environmental)

The first **bidirectional** pin device: the MCU drives the line, then *listens*, and the
harness answers. `dht11` and `dht22` (`data/components/sensors.json`, both `external`).

- **Model**: the harness holds the line high (the module pull-up) whenever the MCU
  releases it, watches for a start signal (the line driven low for ≥ 500 µs, then
  released — detected on both PORT writes and `pinMode()`/DDR changes, so either driver
  style works), and then plays the datasheet bit train: a 20-40 µs wait, 80 µs low, 80 µs
  high, then 40 bits of 50 µs low with a 27 µs (0) or 70 µs (1) high, then 50 µs low.
  Edges land from the run loop at instruction precision, so a `micros()`-timed bit-bang
  reader sees sub-100 µs pulses exactly. Encodings: DHT22 = 16-bit humidity (tenths),
  16-bit temperature (tenths, bit 15 = sign) + checksum; DHT11 = humidity, 0, temperature,
  0 + checksum.
- **Path**: `run_firmware(..., pin_map={"2": "DATA"})` resolves the DATA net (like the
  HC-SR04/encoder); values come from the `temp_c`/`humidity` parameters.
- **Verified**: `firmware/sketches/dht_read` (hand-written one-wire driver, no library)
  reads 23.0 °C / 48.0 %, −5.5 °C / 99.9 % (sign bit + 16-bit humidity) and a DHT11
  21 °C / 55 % frame; `verify_dht.mjs` asserts each raw frame, the checksum and the
  decoded values, and that a sensor on an unwired pin times out. Mapping is covered by
  `tests/unit/test_netlist.gd`; the tool surface by MCP Test B16.
- **Limits (honest)**: no <0.5 Hz sample-rate hold-off, no power-on settling, no timing
  jitter, and the pull-up is ideal. A reader that requires interrupts to be *disabled*
  for the whole frame (some libraries) is not modelled — the harness responds to the
  line, not to the library.

## 11g. Capstone: a bundled firmware example (DHT22 + I2C LCD)

The M7 work is now demonstrated end to end by a *bundled example circuit* rather than
only by harness spikes: `data/examples/15_firmware_env_logger.cf3d` (Arduino + `dht22` +
`i2c_lcd1602` + a virtual `mcu_pin` on the sensor's data net), paired with
`firmware/sketches/env_logger`.

- **One sketch, two device families**: it reads the DHT22 on D2 and reports through both
  the I2C LCD ("T=23.0C H=48.0%" / "checksum ok") and serial — hand-written drivers, no
  libraries.
- **Verified**: `firmware/harness/verify_env_logger.mjs` asserts the decoded LCD text and
  the serial report agree for 23.0 °C / 48.0 % and −5.5 °C / 99.9 %, and that an unwired
  sensor is reported as "sensor error" on the display. `tests/integration/test_examples.gd`
  loads the bundled project, checks that the sensor's DATA net really is the `mcu_pin` net
  that `pin_map` resolves, and that the unmapped device models are skipped with a warning.

## 11h. Eleventh device: SHT31 (I2C, command-driven + CRC-8)

The first device whose protocol is **command-then-read with a checksum**: unlike the
MPU-6050's register pointer, the SHT3x takes 16-bit commands and answers with two
CRC-protected 16-bit words. `sht31` (`data/components/sensors.json`, `external`).

- **Model**: the harness decodes the 16-bit command (`0x2400`/`0x2406`/`0x240B` measure,
  `0xF32D` soft reset, `0x306D`/`0xE000` heater) and answers a read with six bytes —
  temperature MSB/LSB + CRC, humidity MSB/LSB + CRC — using the part's own CRC-8
  (poly `0x31`, init `0xFF`). It matches the datasheet's worked vector (`0xBE 0xEF` →
  `0x92`), so a real driver's validation path passes. `T = -45 + 175·raw/65535`,
  `RH = 100·raw/65535`; values come from `temp_c`/`humidity`.
- **Path**: `run_firmware(..., attach_devices=true)` attaches the circuit's `sht31`
  (`address`, `temp_c`, `humidity`, `corrupt_crc`) like the other I2C parts.
- **Verified**: `firmware/sketches/sht31_read` (hand-written driver, no library) reads
  23.0 °C / 48.0 % and −5.5 °C / 99.9 %; `verify_sht31.mjs` asserts the exact raw words,
  both CRCs, the datasheet vector, and that both a `corrupt_crc` part *and* a sensor at
  the wrong address are rejected by the driver's checksum check. Mapping is covered by
  `tests/unit/test_netlist.gd`; the tool surface by MCP Test B17.
- **Limits (honest)**: the ~15 ms measurement latency is not modelled (data is available
  immediately, so drivers that wait or poll both work), no clock stretching, the internal
  heater changes no temperature, and bus capacitance/timing is ideal.

## 11i. Twelfth device: servo (firmware-driven actuator, angle read back)

The first part that is a **mechanical output** rather than a sensor: the firmware drives
it, and the app recovers the commanded position. `servo_sg90` and `servo_mg996r`
(`data/components/motors.json`) move from `planned` to `external` — M8's "servo motors
and their drivers" item.

- **Model**: no device is attached at all. A hobby servo's control signal *is* the MCU's
  own pulse train, so `FirmwareBackend.pulse_widths(transitions, pin)` measures each high
  pulse on the pin from the harness's exact-cycle transition record, and
  `FirmwareBackend.servo_angle(us, min_us, max_us, range_deg)` maps the part's band
  (544–2400 µs for the SG90, 500–2500 µs for the MG996R) onto 0…`range_deg`, clamped.
  `FirmwareBackend.servo_position()` returns the count, last/min/max widths and the
  angle. This is the same "measure the MCU output" idea as the PWM duty, applied to a
  position instead of an average voltage.
- **Path**: `run_firmware(..., pin_map={"9": "S1"})` resolves the servo's PWM net to the
  firmware pin like the encoder's A/B pair and returns a `servos` array.
  `apply_firmware_servo(hex_path, pin_map)` writes the decoded angle onto the part's
  `angle` parameter. (A servo adds no electrical behaviour, so the solved circuit is
  untouched — the angle is a mechanical state, documented as such in the catalog.)
- **Verified**: `firmware/sketches/servo_sweep` hand-writes a 50 Hz software pulse train
  (no `Servo` library is bundled) that sweeps 0→180° in 30° steps and settles at 90°;
  `verify_servo.mjs` recovers every step from the transitions to within 3°. The pure
  GDScript decode path (pulse extraction, band mapping, clamping, no-pulse case) is unit
  tested in `tests/unit/test_firmware.gd`, the mapping by `tests/unit/test_netlist.gd`,
  and the tool surface by MCP Test B18.
- **Limits (honest)**: the measured widths are ~1° above nominal because that is what the
  sketch's own micros() loop plus Timer0 ISR latency actually produce on an ATmega328P —
  the harness reports the real pulse, not the intended one. Not modelled: torque, stall or
  holding current, the load moving the arm, and slew time (the angle is whatever the last
  pulse commanded). Servo power draw is not added to the circuit.

## 11j. Thirteenth device: STEP/DIR stepper motor (travel read back)

The servo's sibling: an **output** whose commanded travel is decoded from the MCU's own
pulse train, this time through a driver. `stepper_nema17` becomes `external` (from
`visual`) and `a4988_driver`/`drv8825_driver` become `external` (from `planned`).

- **Model**: no bus device. `FirmwareBackend.stepper_steps(transitions, step_pin,
  dir_pin)` counts every rising edge on STEP and takes the sign from the DIR level at that
  instant (starting from the reset state, all pins low); `dir_pin = -1` counts everything
  forward. `FirmwareBackend.stepper_angle(steps, steps_per_rev, microsteps)` maps the count
  onto a shaft angle, wrapping once per `steps_per_rev × microsteps`.
- **Path**: the caller maps the firmware pins driving the driver's STEP/DIR nets to the
  components on those nets — usually the circuit's virtual `mcu_pin`s — and the app finds
  the driver (by its STEP/DIR nets) and the motor (on the driver's **coil outputs** —
  the `passive` pins — via `_coil_nets`). The driver itself cannot be mapped: its nets
  carry no information about which firmware pin drives them, so `_net_pin` takes an
  `exclude` for it. `run_firmware(pin_map=…)` reports the move in `steppers`;
  `apply_firmware_stepper(hex_path, pin_map, microsteps=0)` writes the net `steps` and the
  shaft `angle` onto the motor. Mechanical only: the solved circuit is unchanged.
- **Verified**: `firmware/sketches/stepper_sweep` (hand-written pulse generator:
  +200 then −100 then +50) is decoded to exactly 250 forward / 100 reverse / net +150 steps
  by `verify_stepper.mjs`, which also asserts the STEP high pulse is wider than the A4988's
  1 µs minimum and that flipping the DIR polarity flips the travel. The decoder and the
  angle mapping (including wrap and the no-DIR case) are unit tested; the mapping by
  `tests/unit/test_netlist.gd`; the tool surface by MCP Test B19.
- **Limits (honest)**: `microsteps` must match how MS1..MS3 (or M0..M2) are actually
  strapped — the straps are not read back. The driver's ENABLE state, current limit, decay
  mode and coil waveforms are not modelled, no supply current is drawn from the solved
  circuit, and there is no torque, holding torque, load, backlash or step loss: every
  rising edge is assumed to move the motor exactly one (micro)step.

## 11k. Fourteenth device: four-phase stepper (ULN2003 + 28BYJ-48)

The `uln2003_driver` (`planned` → `external`) and `stepper_28byj48` (`visual` → `external`)
close M8's motor gap: a driver with no STEP pulse at all, four plain phase inputs.

- **Model**: `FirmwareBackend.stepper_phases(transitions, pins)` watches IN1..IN4. The
  harness reports one transition per changed bit, so transitions sharing a timestamp are
  grouped first — a wave-drive hop changes two coils at once and must not look like an
  invalid pattern in between. Each valid pattern is looked up in the eight-state drive cycle
  (`STEPPER_PHASE_CYCLE`), which contains the wave patterns (indices 0,2,4,6) and the
  two-coil full-step patterns (1,3,5,7), and every change is measured as the shortest signed
  move around it. That makes one table honest for half-step (1), wave and full-step (2)
  driving, in a single half-step unit. A coil-off or otherwise invalid pattern breaks the
  sequence — the next valid pattern only re-establishes the reference — and a 180° jump is
  counted in `skipped` rather than guessed.
- **Path**: the caller maps the four firmware pins on the driver's IN1..IN4 nets to the
  components on those nets; the app finds the motor on the driver's `passive` outputs
  (OUT1..OUT4 ↔ the 28BYJ-48's four wires), reports the move in `run_firmware`'s
  `steppers` and `apply_firmware_stepper` writes the net `steps` and shaft `angle`
  (4096 half steps per output revolution for the geared part). Mechanical only.
- **Verified**: `firmware/sketches/stepper_4phase` drives a pre-energized half-step burst
  (32 half steps forward), then wave-mode bursts backwards and forwards (8 changes each,
  worth two half steps apiece) with a coil-off gap between them;
  `verify_4phase.mjs` recovers net +32 half steps, 48 pattern changes, 48/16 forward/reverse
  and exactly 2 skipped coil-off patterns. The decoder (including the same-timestamp
  grouping, invalid patterns, the 180° jump and the no-DIR case) is unit tested; the
  mapping by `tests/unit/test_netlist.gd`; the tool surface by MCP Test B19 (one tool
  covers both driver families).
- **Limits (honest)**: the direction convention follows the standard drive cycle, so
  reversing the coil order flips the sign (as it does on hardware). The board's Darlington
  drops, free-wheeling diodes, current limit and supply draw are not modelled, no torque,
  holding torque, load, backlash or step loss is simulated, and `steps_per_rev` must suit
  the part (2048 for full/wave step driving of a 28BYJ-48, 4096 in half-step driving).

## 11l. Fifteenth device: SSD1306 OLED on SPI

The `oled_ssd1306_spi` panel (`planned` → `external`) is the same display as §11c, reached
over the other bus, and the first device decoded from the AVR's **SPI peripheral** rather
than from an address another device answers.

- **Model**: the harness already recorded `spi_bytes`; the device model adds the two lines a
  driver uses to give those bytes meaning. DC (data/command) and CS (selected) are sampled
  live from the MCU's own port state (`port.pinState(bit)`) at every completed transfer, so
  a byte is tagged with the levels that were true when it was sent. DC-high bytes are data,
  DC-low bytes are commands, and a byte received while CS is high belongs to no transaction
  and is counted as `deselected` instead of decoded. The GDDRAM engine is the *same*
  `makeSsd1306(cols, pages)` core the I2C part uses (extracted for this), so page/horizontal/
  vertical addressing, the `0x21`/`0x22` windows, `pixels_set`, `data_bytes` and `pages_hex`
  behave identically across the two interfaces.
- **Path**: the app builds the spec from the circuit when `attach_devices` is set. With no
  address to fall back on, the panel's DC and CS nets are resolved to firmware pins through
  `pin_map` (`_net_pin`, the same lookup the HC-SR04 and encoder use), which means a panel is
  wired and mapped exactly like a sensor: put a virtual `mcu_pin` on the DC net and the CS
  net and map the firmware pins to those components. If DC resolves to nothing the panel is
  skipped rather than guessed at — without DC the stream cannot be split.
- **Verified**: `firmware/sketches/oled_spi` drives the hardware SPI peripheral (the tap is
  on the peripheral, so a bit-banged bus would be invisible — noted in the sketch and in the
  catalog `notes`) and draws the left half of a 128x64 panel white in vertical addressing
  mode; `verify_oled_spi.mjs` recovers 4096 lit pixels, 1024 data bytes, the exact
  per-page frame and the raw trace, and then reruns the same bytes with **no DC line** to
  prove the frame only appears because DC tags the stream (a negative control, so the check
  cannot pass by accident). The app-side spec builder is unit tested for the DC/CS
  resolution and for the unwired-DC skip, and the part's status/handles() pair by
  `tests/unit/test_netlist.gd`.
- **Limits (honest)**: the same list as the I2C variant (panel optics, charge pump, contrast,
  scrolling, no font), plus: only the SPI peripheral is tapped, so the sketch must use the
  hardware SPI pins (MOSI D11 / SCK D13); DC and CS are read but RES is not, so a sketch that
  never resets the panel still decodes; and the panel is write-only — MISO is left to a device
  that answers it (the MCP3008, §11n), so reads from this one return 0x00.

## 11m. Sixteenth device: ILI9341 colour TFT on SPI

The `tft_ili9341` panel (`planned` → `external`) is the second SPI device and the first
*colour* one: a 240x320 RGB565 engine rather than a monochrome GDDRAM. It exists to show the
§11l plumbing is general, and it exercises a genuinely different command protocol.

- **Model**: `makeIli9341(width, height)` keeps an RGB565 frame plus the address window.
  `0x2A`/`0x2B` (four argument bytes each) set the column/page window, `0x2C` starts a pixel
  stream, and pixels arrive big-endian. The important difference from the SSD1306: here a
  DC-low byte is a *command* and its arguments come DC-high, so the decoder holds a pending
  command and routes DC-high bytes to it until its declared argument count is met, and only
  then to the frame as pixels. Argument counts for the usual init registers (power/timing/
  gamma, `0x36` MADCTL, `0x3A` COLMOD, `0x11`/`0x29`, ...) are what keeps their parameter
  bytes from being misread as commands; an unrecognised command is assumed to take none,
  which is the honest limit. `0x11`/`0x10`/`0x29`/`0x28` drive `sleeping`/`display_on`, and
  MADCTL is *recorded* (`madctl`) but not applied — there is no rotation/orientation model.
- **Output**: a 240x320 frame is 153600 bytes, so the device returns a **summary** the
  harness computes over the whole buffer: `pixels_written`, the distinct `colors` count, an
  FNV-1a `frame_hash` over the RGB565 bytes in row-major order, five probe pixels (four
  corners and the centre), the last address `window`, `madctl`, `colmod`, `display_on`,
  `sleeping`, and the byte counts. The full buffer never leaves the harness.
- **Path**: exactly as for the SPI OLED (§11l) — the app resolves the panel's DC (pin 4) and
  CS (pin 2) nets to firmware pins through `pin_map`, and skips the panel when DC is unwired.
- **Verified**: `firmware/sketches/tft_fill` drives the hardware SPI peripheral, resets the
  panel, runs a trimmed Adafruit-style init (which exercises the argument counts), sets the
  full-screen window and streams 76800 pixels: left half red `0xF800`, right half blue
  `0x001F`. `verify_tft.mjs` recomputes the FNV-1a hash from the *expected* pattern, so all
  76800 pixels are checked rather than a sample, and also checks the probe geometry,
  `colmod` 0x55, `madctl` 0x48, the byte accounting (`153600` pixel + `69` parameter + `25`
  command = `153694`) and the raw trace; the same bytes with **no DC line** are the negative
  control (identical stream, zero pixels written — DC is genuinely what splits the stream).
  The app-side DC/CS resolution and the part's status/handles() pair are unit tested.
- **Limits (honest)**: MADCTL is not applied (no mirroring/rotation), so the frame is stored
  in the order the window walks it; only 16-bit COLMOD is modelled (an 18-bit stream would be
  misparsed); the panel's touch controller, optics, backlight and supply current are not
  modelled; RES is not read (a sketch that never resets still decodes); and, as for the OLED,
  only the SPI peripheral is tapped, so the sketch must use the hardware SPI pins.

## 11n. Seventeenth device: MCP3008 8-channel ADC on SPI (the first read)

The `mcp3008` (`planned` → `external`) is the third SPI device and the first one firmware can
*read*: the two displays are written to and never answer, so until now the monitor ignored
MISO (every transfer returned `0x00`). Answering a read is what makes a real sensor front-end
possible — the ADC's channels are solved node voltages, so firmware reads the analog surface
through a device instead of through the MCU's own ADC.

- **Harness change**: the SPI monitor now hands each *selected* device the byte and lets it
  return what MISO should carry (`miso |= d.onByte(b)`), and it detects the CS high → low edge
  that starts a transaction (`d.select()`), because a conversion is framed by CS, not by the
  byte values. The two panels keep their behaviour (their `onByte` returns 0), so their
  summaries are unchanged.
- **Model**: `{kind:'mcp3008', cs, vref, ain}` — three transfers inside one CS-low window:
  `0x01` (start; nothing is clocked out), then `0x80 | (channel << 4)` (single-ended plus the
  channel number in bits 6..4), then a don't-care. The 10-bit code is clocked out as a leading
  zero bit followed by the result, so the second transfer returns `(code >> 8) & 0x03` and the
  third `code & 0xff`, which is exactly what the datasheet's `((hi & 0x03) << 8) | lo` expects.
  Codes are `round(clamp(v, 0, vref) / vref * 1023)` from the channel voltages, and every
  conversion is recorded (`reads[]` with channel/code/volts, plus `conversions`).
- **Path**: like the SPI panels there is no address, so the app resolves the ADC's CS (pin 9)
  through `pin_map`, and its CH0..CH7 pins are probes on the solved nets (the same closed loop
  as the PCF8591's AIN0..AIN3), with `vref` a parameter (default 5 V) rather than the VREF net.
  Without a mapped CS a conversion cannot be framed, so the part is skipped rather than guessed
  at. `run_firmware` asks for the DC solve when an `mcp3008` is in the circuit, exactly as for
  the PCF8591.
- **Verified**: `firmware/sketches/spi_adc` reads channels 0..3 twice with hand-written
  datasheet transfers (hardware SPI: DIN D11 / CLK D13, answering on MISO D12) and prints the
  raw codes. `verify_spi_adc.mjs` asserts the codes the sketch printed are the ones the spec
  implies (3.3 V → 675, 1.25 V → 256, 0 V → 0, 5 V → 1023 over `vref` 5 V), the per-read volts,
  the byte accounting and the raw trace, and `deselected` = 0 (every transfer sits inside a
  CS-low window); a **full-scale control** (`ain` = 5 V) shows the codes follow the spec rather
  than a constant, and the **negative control** runs the same firmware with **no device
  attached** — the bus then idles at 0x00, so every channel must read 0, which proves the codes
  came from the device model on the bus and not from the sketch. The app-side CS/vref/channel
  resolution and the unwired-CS skip are unit tested, the part's status/handles() pair by
  `tests/unit/test_netlist.gd`, and a divider the solver solves was read back end to end
  (2.5 V → code 512) before the change was committed.
- **Limits (honest)**: differential mode is not modelled (a differential request is answered
  with the channel's single-ended code and counted in `differential_requests`); the reference is
  the `vref` parameter, not the VREF net's solved voltage; conversion timing/throughput and the
  input's own loading on the source are not modelled; and, as for the panels, only the SPI
  peripheral is tapped, so a bit-banged bus is invisible.

## 11o. Eighteenth device: ADXL345 accelerometer (a scale the firmware chooses)

The `adxl345` (`planned` → `external`) is the second served *register file* (§11c was the
first) and it exists to show that the register-file pattern is not an MPU-6050 special case:
same plumbing, different map, and one property the MPU-6050 does not have.

- **Model**: DEVID (`0x00`) is `0xE5`; a write transaction's first byte sets the pointer,
  further bytes write and auto-increment, reads return and auto-increment, and the data
  registers (`0x32`..`0x37`) are little-endian 16-bit two's complement. The sample
  accelerations come from the part's `ax`/`ay`/`az` parameters (g), exactly as the MPU-6050's
  do.
- **The interesting part**: the ADXL345's *scale is the firmware's choice*, not a fixed
  full-scale. `DATA_FORMAT` (`0x31`) bit 3 is FULL_RES — 3.9 mg/LSB (256 LSB/g) at every
  range — and in 10-bit mode the scale is `256 >> range` LSB/g (so ±4 g is 128 LSB/g), while
  the range itself is the register's bits 1:0. The data registers are therefore computed from
  the *live* configuration at read time, so a sketch that changes the range sees the counts
  change, and the app does not have to be told which mode the firmware will use.
- **Path**: like the MPU-6050 it is an addressed I2C part, so `attach_devices` alone serves
  it from the circuit's `adxl345` component — no `pin_map` and no netlist are needed.
- **Verified**: `firmware/sketches/adxl345_read` reads DEVID, writes `BW_RATE`/
  `DATA_FORMAT`/`POWER_CTL`, reads the configuration back and then bursts the six axis bytes,
  reporting counts and milli-g at 128 LSB/g (10-bit mode, ±4 g). `verify_adxl345.mjs` checks
  DEVID, the read-back, the counts and the milli-g conversion, and the device summary's
  `data_format`/`full_res`/`range_g`/`lsb_per_g` — so if the model ignored the written
  `DATA_FORMAT` and used full resolution, the counts would be wrong by 2× and the check would
  fail. A **positive control** (different accelerations) shows the counts follow the spec, and
  the **negative control** runs the same firmware with **no device attached**: the bus then
  reads 0xFF, so DEVID is 0xFF and every axis is -1 — proving the readings came from the
  device model and not from the sketch. The app-side spec builder and the part's
  status/handles() pair are unit tested.
- **Limits (honest)**: only the I2C interface is served (the part also speaks SPI, which is
  not modelled — an SPI ADXL345 would need its own device kind); the FIFO, tap/double-tap,
  free-fall and activity interrupts, the INT1/INT2 pins, self-test, the offset registers and
  the output-data-rate/bandwidth corners are not modelled (the registers are stored, so a
  driver that writes them still runs — it just gets no interrupt behaviour); and the part's
  electrical loading is not modelled.

## 11p. Nineteenth device: ADS1115 16-bit ADC (register file + solved-voltage probes)

The `ads1115` (`planned` → `external`) is where the two proven mechanisms meet: it is an
addressed register file like §11c/§11o *and* a set of solved-voltage probes like the
PCF8591/§11n, and the conversion depends on what the firmware wrote — which is the "scale is
the driver's choice" idea again, over I2C.

- **Model**: four 16-bit registers behind a pointer (`0x00` conversion, `0x01` config,
  `0x02`/`0x03` thresholds), each read and written MSB first, with the pointer advancing after
  each 16-bit word (the conversion register is read-only, so a write to it is ignored). The
  conversion itself is computed live: the MUX bits pick single-ended A0..A3 against GND
  (MUX 4..7) or one of the differential pairs (0..3), and the PGA bits pick
  ±6.144/4.096/2.048/1.024/0.512/0.256 V full scale (reserved codes treated as 0.256 V), and
  the code is the 16-bit two's complement of `vdiff / full_scale × 32768`, clamped.
- **Path**: A0..A3 are the last four pins, so the app resolves each to its solved node voltage
  (exactly the MCP3008's channel loop) and adds the part to the `need_analog` set; the address
  is a parameter (default `0x48`). Because *both* members of a pair are resolved, the
  differential MUX codes are right for free — that is why the differential mode the MCP3008
  could not model *is* modelled here.
- **Timing is not modelled, deliberately**: the code is ready as soon as the config is
  written, so a single-shot driver (write config, read conversion) and a continuous-mode
  driver both work, and the app never has to know the data rate. Each conversion-register read
  is logged (`reads[] = {mux, pga, full_scale_v, code, volts}`) when its LSB completes the
  word — that is the device-side witness the verifier compares against.
- **Verified**: `firmware/sketches/ads1115_read` configures and reads A0..A3 against GND at
  ±4.096 V, the A0/A1 differential pair at the same gain, and A1 again at ±1.024 V — six
  conversions, each printing its code and the same reading in millivolts computed from the
  gain the sketch selected. `verify_ads1115.mjs` recomputes every code and milli-volt from the
  spec (`2.5 V → 20000`, `1 V → 8000`, `0 V → 0`, `3.3 V → 26400`, `A0-A1 → 12000`,
  `1 V at ±1.024 V → 32000`), checks the device-side `reads` log, the final
  config/MUX/PGA, and a **positive control** that includes a negative-full-scale reading
  (`-1.024 V → -32768`); the **negative control** runs the same firmware with **no device
  attached** — the bus then reads 0xFF, so every conversion is -1 and the sketch cannot have
  invented the codes. A divider the solver solved was read back end to end (2.5 V → code
  20000, and 2.5 V differentially against a 0 V channel) before the change was committed. The
  app-side channel resolution and the part's status/handles() pair are unit tested.
- **Limits (honest)**: the ALERT/RDY comparator and the threshold registers' behaviour are not
  modelled (the registers are stored, so a driver that writes them still runs), the ADDR pin's
  address selection is not modelled (the address is a parameter), conversion timing and the
  data-rate corner are not modelled, and the input's own loading and the device's
  supply/electrical limits are not modelled.

## 11q. Twentieth device: MCP4725 12-bit DAC (the loop turned around)

Every device so far either *serves* firmware (registers, frames, pulses) or is *observed* from
its pins (servo, stepper). The `mcp4725` (`planned` → `partial`) is the first part whose output
the *solver* consumes: firmware's code becomes a voltage stamped into the netlist, so a sketch
can drive the analog half of the circuit.

- **Model**: write-only — there is nothing to read back, so the harness decodes the *writes*
  (a read returns `0x00`). A transaction's first byte is the general write command (`0x40` =
  write the DAC register, `0x60` = also write the EEPROM, with the power-down mode in bits
  1..0) and the next two data bytes carry the 12-bit code in their top 12 bits
  (`code = (d1 << 4) | (d2 >> 4)`). The summary reports `code`, `volts` (`code/4096 · vref`),
  `power_down` with the resistor it selects, and the `writes`/`eeprom_writes`/`unrecognised`
  counts.
- **Path**: the app asks the harness to serve the part (`apply_firmware_device` passes the
  spec into `run_hex`), reads the decoded `code` from the device summary and sets the part's
  `vout`; the netlist builder stamps VOUT as a `vout` Thevenin source (`vout` + `rout`). So
  the protocol is implemented once, in `run.mjs`, and the app never re-parses it — the same
  discipline every read device already follows, which is why this part can claim `partial`:
  `NetlistBuilder.handles("mcp4725")` is true.
- **Power-down is modelled, not ignored**: the command byte's power-down bits (`power_down`
  1..3) name a 1 k/100 k/500 k pull-down, and the netlist replaces the driven source with that
  resistor, because that is what the real part does — it stops driving. A sketch that powers
  the DAC down therefore *loads* its node instead of holding it.
- **Verified**: `firmware/sketches/dac_out` writes 2048, 819, 4095 and 1234 (one of them to the
  EEPROM), a power-down write (code 0, mode 1) and a final normal write (3300), printing each
  code and the milli-volts it should produce at the 5 V reference; the last transaction is a
  deliberate fast-mode-style first byte. `verify_dac_out.mjs` recomputes every code and printed
  milli-volt, checks the decoded write/EEPROM/power-down bits, and adds a **3.3 V reference
  control** (only the decoded `volts` follows — the sketch's printed line still assumes 5 V) and
  a **wrong-address control** (the device served at `0x61` sees no transaction, so `writes` 0,
  `code` 0 — the codes come from the addressed device, not from the sketch); a **no-device run**
  still records the bus trace but decodes nothing. A circuit was driven end to end before the
  change was committed (code 3300 → `vout` 4.028 V → the solved node at the load 3.930 V through
  the 25 Ω source). The netlist source, the power-down resistor and both solve paths are unit
  tested, and the honesty sweep asserts `partial` ⇔ `handles()`.
- **Limits (honest)**: the EEPROM write is decoded and counted but nothing persists (no memory
  survives a run), the fast-mode write encoding is not decoded (an unrecognised first byte is
  counted and changes nothing), the power-on-reset/MTP recall value is not modelled (a device
  that has never been written sits at code 0, and the catalog's `vout` default is what a fresh
  part is taken to output), the `A` variant's internal reference/gain settings are not
  modelled, and the part's supply and electrical limits are not modelled.

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
ideal quadrature pair — so input-decoding sketches can be checked without a library, and
the DHT11/DHT22 (§11f) adds a *bidirectional, timing-sensitive* pin device, so one-wire
protocol sketches work. The capstone example (§11g, example 15 in the app) ties a DHT22
and an I2C LCD together in one sketch, so the whole path — circuit, `pin_map`, device
feedback and bus decoding — is exercised at once, and the SHT31 (§11h) adds a
command-driven, checksum-protected I2C part. The servo (§11i) adds the opposite
direction — a firmware-driven *actuator* whose commanded position is read back out of the
MCU's own pulse train — which is the first part of M8's "stepper and servo motors" gap, and
the STEP/DIR stepper (§11j) applies the same idea to travel, and the four-phase
`uln2003_driver`/`stepper_28byj48` pair (§11k) shows the same measurement works from a plain
four-wire sequence — which closes M8's motor gap. The motion example (example 16 in the app)
then puts both actuators in one project and one run, so the two output decoders are checked
against a single transition record, and the SPI devices — the SSD1306 OLED (§11l) and the
ILI9341 colour TFT (§11m) — close the last named M7 gap by decoding a display from the SPI
peripheral, where the command/data split comes from a DC line the app resolves like a sensor
pin. The MCP3008 (§11n) then runs that same bus the *other* way: it *answers* firmware's reads
on MISO with codes derived from the solved node voltages, so an ADC front-end is part of the
same loop and the SPI surface is no longer write-only. The ADXL345 (§11o) then shows the
byte-addressable register file (§11c) is a general pattern rather than one part's accident —
and adds a twist: its scale is whatever `DATA_FORMAT` the firmware wrote, recomputed at read
time. The ADS1115 (§11p) then closes the loop over I2C as well — an addressed register file
*and* solved-voltage probes in one part, whose MUX/PGA the firmware selects, so differential
measurement (which the MCP3008 could not model) comes out right because both members of each
pair are resolved. The MCP4725 (§11q) then turns the same loop around: its *output* is what
the solver consumes — the firmware's code becomes VOUT's Thevenin source (or a pull-down
resistor in a power-down write) — so a sketch can drive the analog half of a circuit, which is
the first time a firmware part changes what the *next* solve sees. Remaining work: the gas/analog modules
(which now have an ADC path to hang off, but no models of their own), a 1-Wire slave for parts
like the DS18B20, and a
streaming/interactive mode if a blocking run proves too coarse (§13). If the app-side
integration ever cannot meet the gate (e.g. timing or packaging), fall back to a
separately-installed `simavr` and keep the feature capability-flagged.

## 13. Streaming / interactive runs: decision

The open question in §12 is whether a *streaming* (long-lived, step-by-step) firmware mode is
needed, i.e. one where the app and the user can interact with the AVR while it runs. The
decision is **no — the blocking run is enough for this milestone**, for these reasons:

- A run is **instruction-accurate and deterministic**: `run.mjs` executes the compiled HEX
  cycle by cycle and returns the complete record (serial, per-pin transitions with
  timestamps, I2C/SPI events, PWM/ADC summaries). Nothing about the *fidelity* depends on the
  interaction model, so a streaming mode would not make any measurement more truthful.
- **Inputs are already time-addressable without a stream**: pin devices inject their
  protocol answers at the emulated time the sketch asks for them, `apply_firmware_pins`
  drives a pin at a chosen `at_ms`, `CF_DEVICES`/`CF_ADC` set device state and analog
  voltages for the whole run, and a run can simply be repeated with different inputs.
- A stream would add real cost: a long-lived child process, IPC framing, back-pressure and
  cancellation paths, and a second source of truth for "what the firmware did" — plus a
  partly-observable run makes the *evidence* weaker (the returned trace would depend on when
  the caller polled).

The honest middle ground, if live interaction is ever wanted, is a **scripted event list**:
`run.mjs --events '[{"at_ms":250,"pin":2,"level":1}]'` (the same shape `apply_firmware_pins`
already uses, but many events in one run). That keeps runs deterministic and the record
complete, so it should be preferred over a streaming protocol if the need appears. Recording
interactively — a user clicking a button in the GUI and the emulator pausing — is a UI
feature on top of that, not a different backend.


