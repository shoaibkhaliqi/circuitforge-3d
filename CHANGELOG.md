# Changelog

All notable changes to CircuitForge 3D are documented here. This project aims to
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Data-driven component catalog** (schema v2) replacing the hardcoded list:
  - `scripts/components/component_schema.gd` — one versioned definition format
    with `normalize()`/`validate()` and an honest implementation-status
    vocabulary (`full`/`partial`/`visual`/`external`/`planned`).
  - `scripts/components/component_catalog.gd` — loads + validates
    `data/components/*.json`, exposes facets and tokenised search with filters
    (category, status, protocol, interface, mounting, arduino-compatible,
    simulatable-only, pagination).
  - **243 definitions across 16 categories** (`data/components/`), 0 validation
    errors: passives, sources, semiconductors, logic, analog ICs, displays,
    sensors, communication, power, motors, connectors, instruments, development
    boards, Android hardware and mobile devices.
  - UI library filters (Fully simulated / Simulatable / Arduino-compatible /
    Not yet simulated) with status tags; MCP `get_component_catalog` filters +
    metadata and new `get_catalog_facets`.
  - `tools/catalog_report.gd` and `docs/catalog/{schema,import,status_report}.md`.
  - New unit tests `test_schema.gd` / `test_catalog.gd`.
- AI-native **MCP (Model Context Protocol) server** (`circuitforge-3d`):
  - Shared, UI-free application service layer (`scripts/api/app_service.gd`)
    used by the GUI, the tests and MCP.
  - Headless engine host (`scripts/api/api_server.gd`) exposing a token-
    authenticated, loopback-only, line-JSON local API
    (`circuitforge-local-api/1`).
  - Python adapter (`mcp_server/circuitforge_mcp/`) built on the official
    `mcp==2.3.0` SDK, speaking MCP over stdio.
  - 42 tools, 7 resources (`circuit://…`) and 8 prompts; read/inspect/edit/
    simulate/persist workflow; `read_only_hint`/`destructive_hint` annotations.
  - Structured error codes, `expected_revision` optimistic locking and
    `operation_id` idempotency; sandboxed persistence and hard limits.
  - MCP documentation set under `docs/mcp/` and an end-to-end protocol test
    suite (Tests A–J) driven through the real MCP client.
- **3D model quality + pin alignment** pass (`scripts/components/component_factory.gd`):
  - Package bodies chosen from the definition's `model.shape` (DIP, TO-92,
    TO-220, seven-segment, servo, LED, PCB module, developer board) with a
    keyword classifier and a pin-count fallback, so every catalog part renders
    as a plausible package instead of a generic box.
  - A lead is drawn to **every** terminal (not just the two outer pins), and
    bodies are sized from the real pin span so they never overhang their pins.
  - Bodies now rest on the board surface and pin/label sizes were tuned.
  - New `tests/unit/test_factory.gd` (55 checks) asserting each terminal has a
    mesh at its exact hole position.
- **Board pin metadata** (`scripts/components/board_pins.gd`): board-aware
  helpers over the documented pin maps — discovery (`all_boards`), grouping
  (digital/analog/power/ground/other), lookup (`named`/`first`/`by_type`),
  counts, structural consistency checks (`issues`) and a `summary` payload.
  Sourced provenance references added to every board (and the Android USB host
  shield). Exposed as the `get_board_pinout` MCP/API tool. New `test_boards.gd`
  (108 checks). Descriptive only — it never claims a board is simulatable.
- **Pin-level simulation (Stage A) + truthful peripherals**:
  - New `mcu_pin` ("Virtual MCU Pin (Stage A)", `data/components/virtual.json`):
    an ideal pin driver (`level`/`vlogic`/`rout`) stamped in the solver as a
    `gpio` element — a Thevenin source written as its Norton equivalent, so it
    needs no branch unknown. High, low and high-impedance levels are modelled.
  - Catalogue parts now map to real solver models: capacitor variants,
    `ferrite_bead`, `trimmer`, `shunt_resistor`, `polyfuse`,
    `push_button`/`reed_switch`, `toggle_switch` (COM–NO/COM–NC pair), LED
    variants, `rectifier_diode`/`schottky_diode`, the battery family (ideal
    source plus a series resistor from internal resistance), `usb_power_5v`,
    `bench_psu`, `breadboard_psu_5v` (5 V + 3.3 V rails) and `ac_source` (sine).
  - New `NetlistBuilder.handles(type)` and `tests/unit/test_netlist.gd` (47
    checks) guarantee a part may only claim `full`/`partial` status if the solver
    actually maps it; 23 parts with no honest model were downgraded to `visual`.
- **Honest analog sensors + brushed DC motors**:
  - Resistive sensors whose resistance follows a stimulus parameter:
    `thermistor_ntc` (beta equation), `photoresistor_ldr` (log-linear from a 0–1
    light level) and `rtd_pt100` (linear RTD).
  - Brushed motors `dc_motor`, `dc_gearmotor_tt`, `fan_5v` and `vibration_motor`
    are modelled as winding resistance plus an **assumed back-EMF** you set
    (0 V = stalled); `solenoid_12v` as a coil. Steady state only — no spin-up,
    torque or speed dynamics, and the catalog notes say so.
  - New 3D package bodies: a sensing bead (thermistor/LDR/RTD) and motor shapes
    (brushed motor, vibration motor, solenoid, fan).
  - Firmware-free display/switch/analog-output parts: `seven_segment` (8 LEDs to
    the common pin, common-anode or common-cathode, driven by `mcu_pin`s),
    `limit_switch` (SPDT COM-NO/COM-NC), `lm35`/`tmp36` (linear analog voltage
    from a temperature stimulus) and `voltage_sensor_module` (resistive divider).
    Motors, displays and digital/protocol sensors that need firmware stay
    `planned`/`visual`.
  - Firmware-free digital/analog sensor modules: `pir_hcsr501`, `ir_obstacle`,
    `hall_a3144`, `flame_sensor`, `sound_sensor`, `ldr_module`, `soil_moisture`,
    `rain_sensor`, `mq2_gas` and `mq135_air` drive their digital output as an
    ideal logic level from a `detected` stimulus; `acs712` is a linear Hall
    current sensor, `pressure_transducer_420ma` a 4-20 mA loop source, and
    `load_cell_5kg` a four-arm Wheatstone bridge.
- **Optional firmware execution (M7, open loop)** — the app can now run a compiled
  Arduino HEX and drive real pins from it:
  - `scripts/simulation/firmware_backend.gd` detects Node + the harness honestly
    and runs a HEX on avr8js (MIT); it is unavailable-by-default and never fakes
    success.
  - New API/MCP tools: `get_firmware_capabilities` (read), `run_firmware` (read,
    returns pin transitions), `apply_firmware_pins` (drives `mcu_pin` components
    from firmware output at a chosen instant, optional DC re-solve). MCP tools
    36 → **39**.
  - New test file `tests/unit/test_firmware.gd` (pin-key normalisation, sampling,
    capability honesty); suite 607 → **627**. MCP integration 14 → **15**.
  - Firmware is open-loop Stage B: digital pins only, no analog/ADC feedback, AVR
    only, and Node stays an optional external tool (Godot suite needs no Node).
  - **First protocol surface (UART)**: the harness instantiates USART0 and captures
    transmitted bytes, so `Serial.print` output is returned by `run_firmware` as
    `serial` / `serial_lines` (`firmware/sketches/serial_hello` verifier asserts
    "CircuitForge tick 0…4"). Suite 627 → **632**.
  - **I2C/SPI bus traces**: the harness records I2C transactions (address,
    direction, bytes) and SPI MOSI bytes; `run_firmware` returns `i2c`,
    `i2c_addresses` and `spi_bytes`. No device is modelled — I2C is ACKed and reads
    return 0xFF (`firmware/sketches/i2c_write` verifier asserts the `0x27` write).
    Suite 632 → **634**.
  - **First firmware-driven device — PCF8574 I2C I/O expander** (`data/components/analog_ic.json`,
    `partial`): the netlist maps its `state` byte to eight ideal quasi-bidirectional
    `gpio` outputs P0..P7 against VSS (default 1 kΩ, approximating the part's weak
    pull-up). New API/MCP tool `apply_firmware_device` runs firmware, takes the last
    byte written to the device's I2C address (0x27 default) and sets `state` from it
    (`FirmwareBackend.last_i2c_write_byte`), optionally re-solving DC. Sketch
    `firmware/sketches/expander` writes `0x55` → P0..P7 = 1,0,1,0,1,0,1,0. MCP tools
    39 → **40**; suite 634 → **645**; MCP integration 15 → **16**.
  - **Closed bus loop (device → firmware)**: the harness serves devices on the I2C
    bus (via `CF_DEVICES`), so firmware can *read* them. `run_firmware(...,
    attach_devices=true)` attaches the circuit's `pcf8574` (`state`/`inputs`/`address`);
    with `inputs=0x0F` the port reads back `0xF0`. Sketch
    `firmware/sketches/expander_read` + `verify_expander_read.mjs` assert "port 240";
    `FirmwareBackend.last_i2c_read_byte` extracts the value. The harness also models
    a 24xx-style `eeprom` device. Suite 645 → **648**. Still no analog/ADC feedback
    (the electrical solver is not in the loop).
  - **Closed analog loop (circuit → firmware)**: new virtual part
    **`mcu_analog_in`** (an ideal 1 GΩ high-impedance ADC probe); the harness
    instantiates `AVRADC` and sets channel voltages from `CF_ADC`.
    `run_firmware(..., analog_map={"A0": "AIN1"})` solves the circuit and feeds each
    mapped node's voltage to `analogRead()`. Sketch `firmware/sketches/analog_read`
    + `verify_analog.mjs` assert 2.5 V → code 512; a divider midpoint solves to
    2.0 V → code 409. MCP tools unchanged (40); MCP integration 16 → **17** (Test
    B7); suite 648 → **653**; catalog 239 → **240** defs (Virtual 1 → 2), simulatable
    73 → **74**.
  - **Closed output loop (firmware → circuit)**: new virtual part **`mcu_pwm_out`**
    (the average-voltage model of a PWM pin, `duty · vlogic`, an ideal Thevenin
    `vout` source). The harness measures each pin's PWM duty from its transitions
    (`pwm` summary), and `apply_firmware_pwm(hex_path, pin_map={"9":"PWM1"})` sets the
    target's `voltage` to `duty·vlogic`, optionally re-solving DC. Sketch
    `firmware/sketches/pwm_out` (`analogWrite(9,128)`) + `verify_pwm.mjs` measure
    ~50.2% duty at ~490 Hz (2.51 V), and a 1 kΩ load sags to 2.448 V. MCP tools
    40 → **41**; MCP integration 17 → **18** (Test B8); suite 653 → **663**; catalog
    240 → **241** defs (Virtual 2 → 3), simulatable 74 → **75**.
  - **I2C EEPROM device — 24C02** (`data/components/analog_ic.json`, `external`):
    a pure-backend part with no breadboard model, served on the I2C bus by the
    harness. `run_firmware(..., attach_devices=true)` now attaches `eeprom_i2c`
    (`address`, `size`); the `eeprom` device implements the standard two-byte
    address + data write and returns the resulting memory image (`devices[].mem`).
    Sketches `firmware/sketches/eeprom_roundtrip` (store `0xA5`, read back) and
    `eeprom_read` + `verify_eeprom.mjs` assert "eeprom 165". MCP integration
    18 → **19** (Test B9); suite 663 → **665**; catalog 241 → **242** defs
    (`external` 36 → **37**). Memory does not persist across separate runs.
  - **I2C ADC/DAC device — PCF8591** (`data/components/analog_ic.json`, `partial`):
    AIN0..AIN3 map to ideal 1 GΩ ADC probes and AOUT to an ideal Thevenin DAC
    output (`vout` at `aout`). `run_firmware(..., attach_devices=true)` solves the
    circuit and serves the part on the bus with each AIN channel's solved node
    voltage, so firmware reads an 8-bit code (`ain`, `read`). Conversely
    `apply_firmware_device` sets the DAC `aout` from the byte firmware writes
    (`byte/255 * vref`). Sketches `firmware/sketches/pcf8591_read` (2.0 V divider →
    code 102) and `pcf8591_dac` + `verify_pcf8591.mjs` (2.5 V → code 128). MCP
    integration 19 → **20** (Test B10); suite 665 → **672**; catalog 242 → **243**
    defs, `partial` 50 → **51**, simulatable 75 → **76**.
  - **I2C character LCD device — 16x2 HD44780 backpack** (`data/components/displays.json`,
    `i2c_lcd1602`, `external`): the harness decodes the HD44780 4-bit protocol from the
    backpack's PCF8574 writes (RS/RW/E/backlight + D4..D7), tracking clear/home/address
    commands and character writes, and returns the visible text as `devices[].lines`.
    `run_firmware(..., attach_devices=true)` attaches the circuit's `i2c_lcd1602`
    (`address`, `cols`, `rows`). Sketch `firmware/sketches/lcd_hello` (no library) +
    `verify_lcd.mjs` assert "CircuitForge" / "3D". MCP integration 20 → **21** (Test
    B11); suite 672 → **674**; catalog `external` 37 → **38**, `planned` 107 → **106**.
  - **HC-SR04 ultrasonic — firmware-driven MCU input pin** (`data/components/sensors.json`,
    `hcsr04`, `external`): the first attached part to drive an MCU **input** pin during a
    run. The harness watches the firmware's TRIG pulse and, after a 200 µs propagation
    delay, drives ECHO high for `distance_cm · 58 µs`, so `pulseIn()` measures a real
    echo. `run_firmware(..., pin_map={"9": "<TRIG>", "10": "<ECHO>"})` resolves TRIG/ECHO
    from the netlist (like `analog_map`); the result adds `pin_devices` / `pin_inputs`.
    Sketch `firmware/sketches/ultrasonic` + `verify_ultrasonic.mjs` assert
    `echo 1735 dist 30` for a 30 cm target. MCP integration 21 → **22** (Test B12);
    suite 674 → **676**; catalog `external` 38 → **39**, `planned` 106 → **105**.
  - **MPU-6050 IMU — served I2C register file** (`data/components/sensors.json`,
    `mpu6050`, `external`): the harness serves an MPU-6050 register file on the bus
    while firmware runs. A write transaction's first byte sets the register pointer and
    further bytes auto-increment; reads return and auto-increment, so a 14-byte burst
    from 0x3B returns accel XYZ + temperature + gyro XYZ. WHO_AM_I (0x75) = 0x68 and the
    sample counts come from the `ax`..`gz`/`temp_c` parameters (16384 LSB/g,
    131 LSB/(deg/s), 340 LSB/degC). Sketch `firmware/sketches/mpu6050_read` +
    `verify_mpu6050.mjs` decode the served values exactly. MCP integration 22 → **23**
    (Test B13); suite 676 → **678**; catalog `external` 39 → **40**, `planned` 105 →
    **104**.
  - **SSD1306 OLED — decoded GDDRAM framebuffer** (`data/components/displays.json`,
    `oled_ssd1306`, `external`): the harness splits the control byte (bit6 = D/C) from
    the payload and tracks page/horizontal/vertical addressing, the 0x21/0x22 range
    commands and the B0-B7 column-set, so a driver's frame writes land in the right
    place. The decoded frame is returned as `devices[].pages_hex` (plus `pixels_set` and
    `display_on`). `run_firmware(..., attach_devices=true)` attaches the circuit's
    `oled_ssd1306` (`address`, `cols`, `pages`). Sketch `firmware/sketches/oled_fill`
    (hand-written init, no library) + `verify_oled.mjs` assert 4096 lit pixels and the
    exact per-page hex. MCP integration 23 → **24** (Test B14); suite 678 → **680**;
    catalog `external` 40 → **41**, `planned` 104 → **103**.
  - **Rotary encoder — ideal quadrature pin device** (`data/components/sensors.json`,
    `rotary_encoder`, `external`): the second firmware-driven *pin* device. The harness
    walks the Gray cycle `(A,B) = 00 → 10 → 11 → 01` (or in reverse) from the power-on
    state, changing exactly one pin per count, so a polling decoder never sees a two-bit
    hop; `counts` steps are emitted from `start_us` at one per `step_us` and reported
    under `pin_devices`. `run_firmware(..., pin_map={"2":"A","3":"B"})` resolves the A/B
    nets from the netlist (like the HC-SR04). Sketch `firmware/sketches/encoder_read`
    (hand-written quadrature table decoder) + `verify_encoder.mjs` assert 50 steps
    forward, 50 reverse and 200 at a 500 µs step. MCP integration 24 → **25** (Test B15);
    suite 680 → **682**; catalog `external` 41 → **42**, `planned` 103 → **102**.
  - **DHT11/DHT22 — bidirectional one-wire pin device** (`data/components/sensors.json`,
    `dht11` + `dht22`, both `external`): the harness holds the line high (module pull-up)
    when the MCU releases it, detects the start signal (driven low ≥ 500 µs, then
    released — on PORT *or* DDR writes), then answers with the datasheet bit train
    (20-40 µs wait, 80 µs low, 80 µs high, then 40 bits of 50 µs low with a 27 µs or
    70 µs high). Edges land at instruction precision, so a `micros()`-timed reader sees
    sub-100 µs pulses exactly. DHT22 = 16-bit tenths with a sign bit; DHT11 = integer
    framing. `run_firmware(..., pin_map={"2":"DATA"})` resolves the data net. Sketch
    `firmware/sketches/dht_read` (hand-written one-wire driver) + `verify_dht.mjs` assert
    the raw frames for 23.0/48.0, −5.5/99.9 and a DHT11 frame, plus an unwired-pin
    timeout. MCP integration 25 → **26** (Test B16); suite 682 → **686**; catalog
    `external` 42 → **44**, `planned` 102 → **100**.
  - **Bundled firmware example — DHT22 + I2C LCD logger** (`data/examples/
    15_firmware_env_logger.cf3d` + `firmware/sketches/env_logger`): the capstone that
    demonstrates the whole path with a real circuit, not just a harness spike. One
    hand-written sketch reads the DHT22 on D2 through the virtual pin `P1` and reports
    through both the I2C LCD and serial; the app's `pin_map` resolves the sensor from that
    net. `verify_env_logger.mjs` asserts the LCD text and serial agree (including a
    missing-sensor case); `tests/integration/test_examples.gd` loads the project, checks
    the sensor DATA net is the `mcu_pin` net, and that unmapped models are skipped with a
    warning. Bundled examples 14 → **15**; suite 686 → **692**.
  - **SHT31 — command-driven I2C temp/humidity with CRC-8** (`data/components/sensors.json`,
    `sht31`, `external`): the first part whose protocol is *command then read with a
    checksum*. The harness decodes the 16-bit commands (0x2400/0x2406/0x240B measure,
    0xF32D reset, 0x306D/0xE000 heater) and answers a read with six bytes — temperature
    MSB/LSB + CRC, humidity MSB/LSB + CRC — using the SHT3x CRC-8 (poly 0x31, init 0xFF;
    it matches the datasheet's 0xBE 0xEF → 0x92 vector). `T = -45 + 175·raw/65535`,
    `RH = 100·raw/65535`. Sketch `firmware/sketches/sht31_read` (hand-written driver) +
    `verify_sht31.mjs` assert the raw words and both CRCs, and that a `corrupt_crc` part
    and a sensor at the wrong address are both rejected by the driver. MCP integration
    26 → **27** (Test B17); suite 692 → **694**; catalog `external` 44 → **45**,
    `planned` 100 → **99**.
  - **Servo motors — firmware-driven actuator with the angle read back**
    (`data/components/motors.json`, `servo_sg90`/`servo_mg996r`, `planned` → `external`):
    the first *mechanical output* part. No device is attached — a servo's control signal is
    the MCU's own 50 Hz pulse train, so `FirmwareBackend.pulse_widths`/`servo_angle`/
    `servo_position` decode the commanded angle from the harness's exact-cycle transition
    record using each part's `min_us`/`max_us`/`range_deg` band. `run_firmware(pin_map=…)`
    returns it in `servos`; the new `apply_firmware_servo(hex_path, pin_map)` writes it to
    the part's `angle`. Sketch `firmware/sketches/servo_sweep` (hand-written software PWM —
    no `Servo` library is bundled) + `verify_servo.mjs` recover a 0→180° sweep and a
    settled 90° to within 3°; MCP integration 27 → **28** (Test B18); suite 694 → **713**;
    catalog `external` 45 → **47**, `planned` 99 → **97**.
- **Firmware-backend spike (M7, Stage B open loop)** — `firmware/`: `arduino-cli`
  compiles `sketches/blink` for `arduino:avr:uno`; `harness/run.mjs` runs the HEX
  on **avr8js (MIT)** and streams digital pin transitions as JSON; `verify.mjs`
  asserts a deterministic ~1 Hz blink on D13 (edge gaps ≈500 ms). Engine is MIT,
  so nothing GPL is vendored; app-side integration is still gated (no catalog
  status changes).
- **Firmware-backend feasibility write-up** (`docs/plan/m7_firmware_backend.md`):
  a researched, honest assessment of real code-execution engines (simavr GPL-3,
  simulavr GPL-2, avr8js MIT, Renode MIT, Espressif QEMU, Microchip AVR
  Simulator), the MIT-vs-GPL licensing implication, the sidecar integration shape
  (Stage B/C) and the gate criteria. Assessment only — nothing is implemented, so
  protocol parts keep their `planned`/`visual` labels.
- **MCP pin/metadata tooling** (34 → **36** tools): `get_pin_states` reads every
  virtual MCU pin (level, high/low/high-Z, driven node, solved voltage) and
  `set_pin_levels` drives pins with an optional DC re-solve — the Stage-A
  pin-state workflow, ideal pins with no firmware. Integration suite 14/14.
- **New bundled examples** (11 → **14**): `12_seven_segment.cf3d` (a
  common-cathode 7-segment digit driven by virtual MCU pins), `13_ntc_thermistor.cf3d`
  (an NTC + fixed-resistor divider that tracks temperature) and
  `14_limit_switch_motor.cf3d` (a limit switch switching a stalled DC motor).
  The example test now spot-checks their documented values. `Session.add_component`
  gained an optional explicit id (used by `tools/make_examples.gd` so the
  generated examples keep stable, readable reference designators).
- **Solver scale test** (`tests/solver/test_scale.gd`): a 200-node resistor
  ladder solves in ~14 ms (well under the 5 s guard), protecting against
  accidental complexity regressions.
- **Windows screenshot option**: `-- --screenshot=<path>` loads a circuit, lets
  the window settle, saves a PNG and quits — used to produce
  `docs/plan/m10_*.png` visual evidence.

### Fixed
- Component visuals drew only one lead: the model frame used `Node3D.to_local()`
  before the node was inside the SceneTree. The pin axis is now projected
  directly, so leads are symmetric and the "not inside tree" errors are gone.
- The solver's `gmin` leakage was a no-op: `_add_gmin` called
  `add_g(i, i, gmin)`, which `add_g` cancels out for `p == n`, so a node with no
  resistive path (e.g. an unwired 7-segment segment) went singular. A dedicated
  `MNA.add_shunt` now adds a real 1e-9 S to ground on every node, so dangling
  nodes solve to ~0 V instead of failing.

### Changed
- Screenshot/consistency: Linux build status documented honestly as ELF-validated
  but runtime-unverified (no Linux/WSL guest on the build host).

## [0.1.0] - 2026-10-16

First functional, production-oriented release.

### Added
- 3D breadboard workbench (30 rows, five-hole terminal groups, centre channel,
  four power rails with optional split-rail mode) with an orbit/pan/zoom camera.
- Modified Nodal Analysis engine: DC operating point, backward-Euler transient
  analysis (R/C/L) and Newton–Raphson nonlinear solving with junction limiting.
- Components: resistor, capacitor, inductor, potentiometer, switch, ground,
  DC voltage source (DC / sine / pulse / square), DC current source, diode, LED,
  zener diode.
- Combinational logic gates: AND, OR, NOT, NAND, NOR, XOR, buffer (5 V levels).
- Instruments: auto-scaling oscilloscope and a multimeter (net/component probe).
- Adjustable workbench lighting (studio / bright / night).
- Versioned, validated `.cf3d` JSON projects with migration, undo/redo and an
  unsaved-changes guard.
- 11 bundled example circuits, loadable from the toolbar or the command line.
- Full command-line file opening.
- 260+ automated tests (solver, connectivity, persistence, units, camera,
  placement, logic, end-to-end, examples).
- Windows and Linux export presets; GitHub Actions test workflow; MIT license.

### Fixed
- Clicking the breadboard placed all pins in one five-hole net (shorting the
  component); default placement now walks rows.
- `Node3D.modulate` was used for invalid placements (invalid property / crash);
  the value label is now tinted instead.
- MNA branch rows could overlap node rows.
- Newton–Raphson convergence now also requires junction-limiting state to settle.
- Persistence serialises with full precision so tiny values survive round-trips.
- Silent JSON parse errors during load are now reported with a line number.
- Non-finite solver output is detected and reported instead of shown as a result.
- Oscilloscope auto-scales and defaults to node-voltage probes.
- Default window size reduced to 1280×720 to fit ordinary screens.
- `_warnings` was being persisted into project files.

### Known limitations
- Linux build produced and ELF-validated, but its runtime was not executed (no
  Linux/WSL guest available on the build host). Full GPU runtime on a native
  Linux desktop was not exercised.
- Logic gates are combinational only; sequential logic (flip-flops, counters)
  and a programmable MCU are future work.
- No macOS / Android / Web export in this release.
