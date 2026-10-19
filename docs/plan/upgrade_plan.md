# CircuitForge 3D — Upgrade Plan (Audit → Milestones)

This document records the audit of the existing project and the incremental plan
for the "beautiful, realistic 3D electronics simulator" upgrade. It is kept up to
date as milestones land.

## 1. Audit (current state before this upgrade)

| Area | Current implementation | Assessment |
| --- | --- | --- |
| Engine | Godot **4.7.2**, Forward+ renderer | Keep. Add a low-end graphics path. |
| Entry | `scenes/main/main.tscn` → `scripts/app/main.gd` (Node3D) | Scene is a stub; **all UI is built in code** in `main.gd` (~1000 lines). |
| Simulation | `scripts/simulation/*` — MNA, DC, backward-Euler transient, Newton–Raphson | Real and tested. Keep as the authoritative solver. |
| Connectivity | `scripts/connectivity/netlist_builder.gd` + `scripts/breadboard/breadboard.gd` | Correct topology; wire/proximity is safe. |
| Components | `scripts/components/component_db.gd` (18 types, data-driven) + `component_factory.gd` (procedural boxes) | Definitions good; **visuals are placeholder boxes/cylinders**. |
| Breadboard view | `scripts/breadboard/breadboard_view.gd` — flat box, cylinder "holes" | Needs realism: recessed holes, printing, rails, bevels, labels. |
| Persistence | `scripts/persistence/persistence.gd` — versioned `.cf3d` JSON | Keep; extend schema for new component metadata. |
| MCP | `mcp_server/` adapter + `scripts/api/app_service.gd` | Working (32 tools). Must be extended, not replaced. |
| UI/Theme | Default Godot theme, fixed-pixel overlays | **No design system.** Right panel pushed off-screen; labels dominate the view. |
| Tests | `tests/` — 248 passing | Keep green; extend for new features. |
| Platform | Windows verified; Linux ELF-validated (runtime unverified) | Keep documented; verify again at the end. |

### Baseline evidence (before changes)

- Tests: **248 / 248 passing** (`godot --headless --script res://tests/run_tests.gd`).
- App launches and solves the LED example (DC, 12 iterations, 9.733 mA).
- Screenshot baseline: `docs/plan/baseline_ui.png` (default theme, oversized labels,
  right panel clipped, toolbar overflow).

### Key reusable assets

- The MNA/Newton solver, netlist builder, breadboard topology, persistence and
  MCP service layer are **solid and authoritative** — reused unchanged.
- `ComponentDB` is already data-driven; it is the natural place to grow the
  catalog (pins, categories, metadata, simulation status).

### Architectural limitations found

1. UI is imperative and untokenised (no theme, no reusable widgets).
2. Component visuals are generic and unrelated to the component type.
3. No SubViewport; panels overlay a full-screen 3D view, so layout must be
   anchor-based and collision-aware.
4. No notion of "simulation status per component" (full / partial / visual-only).
5. No microcontroller concept at all; component model is fixed 2–3 pin devices.
6. New components cannot express >2-terminal packages with named pins.

## 2. Guiding decisions

- **Reuse, don't rewrite.** The solver, connectivity, persistence and MCP layers
  stay authoritative. All new features feed through them.
- **Honesty over polish.** Every component carries a `simulation_status` of
  `full`, `partial`, or `visual`. The UI and MCP surface it; nothing is claimed
  simulated unless the solver (or a real backend) produced the numbers.
- **Data-driven catalog.** New components are definition dictionaries, not code.
- **No fake hardware data.** Pin maps come from datasheets and are documented in
  `data/boards/*.json` with sources.
- **Incremental + verified.** After each milestone: run the full test suite,
  launch the app, capture a screenshot, and commit.

## 3. Milestones

| # | Milestone | Status |
| --- | --- | --- |
| 1 | Audit + **visual design system** (theme, palette, typography, reusable widgets) | done |
| 2 | Professional layout: toolbar, resizable/collapsible panels, status bar, component browser | done |
| 3 | Breadboard realism, camera controls, wire rendering, placement preview/highlight | done |
| 4 | High-quality reusable 3D models for basic components | done |
| 5 | Boards + pin metadata (Arduino/ESP/Pico/Pi/STM32/Teensy/Android) | done (sourced pin maps + helpers; 3D is representative, not dimensioned) |
| 6 | Pin-level simulation (Stage A) + basic peripherals | done (Stage-A pin driver + truthful full/partial mapping; enforced by tests) |
| 7 | Code execution backend (Stage B/C) — feasibility-gated | done (avr8js/MIT runs a compiled Uno blink deterministically on Windows; see `docs/plan/m7_firmware_backend.md`); app-side integration done (UART/I2C/SPI traces); device (PCF8574) modelled + read/written; `mcu_analog_in` feeds firmware ADC; `mcu_pwm_out` driven by `analogWrite()`; I2C EEPROM (`eeprom_i2c`) readable/writable; PCF8591 I2C ADC/DAC reads solved nodes and drives an analog output; I2C 16x2 LCD decodes display text; HC-SR04 drives an MCU input pin via pulseIn; MPU-6050 IMU serves an I2C register file; SSD1306 OLED decodes the GDDRAM frame over I2C and over SPI (DC/CS mapped like a sensor) and the ILI9341 TFT an RGB565 frame over SPI; rotary encoder steps an ideal quadrature pair; DHT11/DHT22 answer a one-wire start signal; SHT31 answers command-driven reads with CRC-8-checked words; a servo's commanded angle is decoded from the firmware's own pulse train; stepper travel is decoded from STEP/DIR pulses and from a four-phase (ULN2003) sequence; the `mcp3008` SPI ADC answers firmware reads on MISO with codes from the solved node voltages, the `adxl345` serves an accelerometer register file whose counts follow the scale the firmware selected, and the `ads1115` answers I2C conversion reads with codes from its A0..A3 solved nets at the MUX/PGA the firmware selects; the `mcp4725` closes the loop the other way — its 12-bit code becomes a VOUT Thevenin source (or a pull-down resistor in a power-down write) |
| 8 | Sensors, displays, motors, advanced analog/digital parts | done for the firmware-free subset (resistive/analog sensors, brushed motors, 7-segment, limit switch); the protocol/display part of it is now backed by plan M7, and the motor gap is closed by the firmware-driven servos and steppers |
| 9 | Extend MCP tools/metadata for boards, pinouts, pin states, firmware | done (43 tools: `get_board_pinout`, `get_pin_states`, `set_pin_levels`, `get_catalog_facets` and the 7 firmware tools; integration suite 29/29) |
| 10 | Performance pass, examples, tests, Windows/Linux verification, docs | done (performance/component-count pass + dense guard, examples + gmin fix + scale test, Windows + firmware screenshot evidence, suite 776/776; Linux runtime verification blocked on WSL — ELF-validated only) |

## 3a. Progress log

### Milestone 1 — design system (done)
- Added `scripts/ui/design.gd`: central palette (void/panel/input/sunken/border, text
  tiers, accent, ok/warn/err/select), font sizes, `theme()` builder (Button,
  LineEdit, ItemList, Tree, ScrollBar, SplitContainer, PopupMenu, TabContainer,
  Tooltip, separators) and helpers `section()`, `heading()`, `hint()`,
  `status_dot()`, `status_color()`.

### Milestone 2 — layout (done)
- `main.gd` rebuilt: `VBoxContainer` → toolbar (`HFlowContainer`, wraps) +
  `HSplitContainer` (library / centre / inspector) + status bar.
- Collapsible panels (`_toggle_panel`), component browser with search + category
  filter + hints, `View ▾` camera presets / Frame All / Reset.
- Status bar shows state dot, message, project name, tool, zoom, warning count.
- Evidence: `docs/plan/m2_layout.png`.

### Milestone 3 — breadboard realism (done)
- 3D world moved into a `SubViewport` (MSAA 2×) inside a `SubViewportContainer`,
  so the workspace no longer sits behind the panels; picking maps root-window
  coordinates into the SubViewport's pixel space via `_work_pos()`.
- Board: chamfered two-tone rim (foot + body + inset top plates), split centre
  channel recessed below the surface, printed red/blue rails, horizontally
  **recessed** holes (dark, flush with the surface).
- Printed markings: column letters (a–j) at both ends, row numbers (5…30) on both
  sides, and +/− rail polarity marks.
- Wires: drawn as shallow arched curves in a per-wire colour from a palette
  (`WIRE_PALETTE`, chosen from the endpoint key so a wire keeps its colour).
- Placement preview: a translucent ghost of the component being placed, tinted
  green (valid) or red (blocked by an occupied hole), plus a wire rubber-band
  from the first hole while wiring.
- Camera presets (Top/Front/Side/Isometric), Frame All and Reset View.
- Evidence: `docs/plan/m3_board.png`, `docs/plan/m3_wires.png`,
  `docs/plan/m3_preview.png`.
- Regression: **248 / 248 tests pass**, headless load exits 0.

### Milestone 4 — component models (done, first pass)
- Rewrote `scripts/components/component_factory.gd`: models are built in a local
  frame (origin at the pin mid-point, local +Z along pin 0 → pin N) so they always
  align with the real terminals.
- Models: resistor (with real 4-band colour code computed from the value),
  ceramic capacitor, inductor (coil rings), potentiometer, battery/current source,
  ground symbol, switch (lever reflects open/closed state), **LED (emissive dome
  that lights with forward current)**, diode/zener (cathode band), logic gates
  (DIP body + function marking), silver pin pads, and a selection highlight.
- Live data (params, current, voltage, switch state) flows in via the `info`
  argument from `_rebuild_3d()`.
- Evidence: `docs/plan/m4_components.png`, `docs/plan/m4_led_on.png` (LED lit at
  9.73 mA; resistor shows orange-orange-brown = 330 Ω).
- Regression: **248 / 248 tests pass**, headless load exits 0.

### Library catalog foundation (done)
The largest sub-project so far: a single, versioned, data-driven component
catalog that replaces the hardcoded definition list.
- `scripts/components/component_schema.gd` (v2): `normalize()` /
  `validate()` and the honest status vocabulary
  (`full`/`partial`/`visual`/`external`/`planned`) with `is_simulatable()`.
- `scripts/components/component_catalog.gd`: loads + validates every
  `data/components/*.json`, exposes facets and `search(query, filters)`
  (category, subcategory, package, mounting, manufacturer, status, protocol,
  interface, arduino_compatible, simulatable_only, pagination); `MANIFEST`
  fallback for exports.
- `scripts/components/component_db.gd`: façade kept API-compatible; adds
  status/search/facets + `count()`.
- **15 category files, 237 definitions, 0 validation errors.** Preserves all 18
  original types/params exactly. Honest statuses: 25 `full`, 43 `partial`,
  6 `visual`, 36 `external`, 127 `planned`.
- UI: `main.gd` library now filters by *Fully simulated / Simulatable /
  Arduino-compatible / Not yet simulated* and tags non-simulatable parts with
  their status.
- MCP: `get_component_catalog` gains filters + richer metadata;
  new `get_catalog_facets`.
- Docs: `docs/catalog/{schema,import,status_report}.md`;
  `tools/catalog_report.gd` prints the live breakdown.
- Evidence: `docs/plan/catalog_ui.png`.
- Regression: **322 / 322 tests pass** (added `test_schema`, `test_catalog`);
  MCP suite **12 / 12**; headless load exits 0.

### Milestone 4b — 3D model quality + pin alignment (done)
- `scripts/components/component_factory.gd` now picks the body from the
  definition's `model.shape` (DIP, TO-92, TO-220, seven-segment, servo, LED, PCB
  module, developer board) via a keyword classifier plus a pin-count fallback, so
  catalog parts render as plausible packages rather than a generic box.
- Every terminal gets a real lead (previously only the two outer pins did), and
  bodies are sized from the real pin span so they never overhang their pins.
- Bodies rest on the board surface; pin-pad and label sizes tuned down.
- **Fixed**: the model frame called `Node3D.to_local()` before the node joined the
  SceneTree, so only one lead was drawn and the console logged
  "not inside tree" errors. The pin axis is now projected directly.
- Ghost preview clears all labels (value + package name) when tinting.
- New `tests/unit/test_factory.gd` (55 checks): every terminal has a mesh at its
  exact hole position; core and catalog package shapes build.
- Evidence: `docs/plan/m7_package_models.png`.
- Regression: **377 / 377 tests pass**, headless load exits 0.

### Milestone 5 — board pin metadata (done)
- `scripts/components/board_pins.gd`: board-aware helpers over the documented pin
  maps — `all_boards`, `is_board`, `pinout`, `named`/`first`/`by_type`,
  `groups` (digital/analog/power/ground/other), `counts`, `issues` (structural
  checks) and `summary` (a presentation payload).
- Provenance: every board now carries a `references` citation (official vendor
  documentation / datasheets); the Android USB host shield too. No pin values were
  invented — the maps are the ones already documented in `data/components/`.
- Exposed as `get_board_pinout` in the local API and the MCP server
  (**34 tools**; the integration suite now runs Tests A–J + B2 + B3 = 13/13).
- New `tests/unit/test_factory.gd`-style suite `tests/unit/test_boards.gd`:
  discovery, per-board consistency, group/count arithmetic, the documented Uno R3
  map, summary payload, and provenance for every board.
- **Honest scope**: this is descriptive metadata. Boards remain
  `simulation_status: planned` and are never reported as simulated.
- Regression: **485 / 485 tests pass**, MCP **13 / 13**, headless load exits 0.

### Milestone 6 — pin-level simulation Stage A + truthful peripherals (done)
- **`mcu_pin`** ("Virtual MCU Pin (Stage A)", new `data/components/virtual.json`):
  an ideal pin driver with `SIG`/`GND` terminals and `level`/`vlogic`/`rout`
  parameters. Stamped in the solver as a `gpio` element — a Thevenin source
  written as its **Norton equivalent** (`add_g` + `add_i`), so it needs no branch
  unknown. `level ≥ 0.5` drives `vlogic`, `level ≤ −1` is high-impedance, and
  `level 0` drives low.
- **Catalogue aliases mapped to real models** in `netlist_builder.gd`: capacitor
  variants, `ferrite_bead`, `trimmer`, `shunt_resistor`, `polyfuse`,
  `push_button`/`reed_switch` (→ resistor), `toggle_switch` (COM–NO/COM–NC pair),
  LED variants, `rectifier_diode`/`schottky_diode`, the battery family (ideal
  source plus a series resistor from `r_internal`/`r_int`), `usb_power_5v`,
  `bench_psu`, `breadboard_psu_5v` (5 V + 3.3 V rails) and `ac_source` (sine).
- **Honesty fix**: 23 parts that claimed `partial` but had no solver model
  (connectors, IC sockets, motors, multi-pin regulators/DC-DC modules, relay,
  USB power meter, sensor module, RGB LED) are now `visual`. A new
  `NetlistBuilder.handles(type)` predicate plus `tests/unit/test_netlist.gd`
  enforce that **no part may claim `full`/`partial` unless it is mapped**, and no
  `visual` part is secretly simulated.
- New `tests/unit/test_netlist.gd` (47 checks): honesty sweep over the catalogue,
  `gpio` Thevenin behaviour (sag, low, high-Z), every alias mapping, and a
  battery-with-internal-resistance numerical solve.
- Regression: **532 / 532 tests pass**, MCP **13 / 13**, headless load exits 0.

### Milestone 7 — code-execution backend (feasibility spike passed)
- Assessed the real engines rather than guessing: **simavr** (GPL-3, Linux/macOS,
  AVR, loads ELF/iHEX), **simulavr** (GPL-2, Linux), **avr8js** (MIT, JS),
  **Renode** (MIT, Cortex-M/RISC-V), Espressif QEMU (GPL-2, ESP32) and the
  proprietary Microchip AVR Simulator. Off-the-shelf compile via `arduino-cli`
  (GPL-3) or `avr-gcc`/`avr-libc`.
- Because the app is **MIT**, a GPL engine is not vendored; the recommended shape
  is an **external, separately-installed** engine (simavr) or a **permissive**
  engine (avr8js), talked to over the existing local line-JSON bridge and stamped
  into the existing `gpio` element. Stage B = open loop, Stage C = ADC feedback.
- Full write-up, API sketch and **gate criteria** in
  `docs/plan/m7_firmware_backend.md`. **Nothing is implemented**; protocol parts
  stay `planned`/`visual` until a Windows spike passes the gate.
- **Spike executed (Windows, permissive path)**: `arduino-cli` compiles
  `firmware/sketches/blink` for `arduino:avr:uno`; `firmware/harness/run.mjs`
  loads the HEX into **avr8js (MIT)** and streams pin transitions; a 1 Hz blink on
  D13 is deterministic (edge gaps 500.009/500.008/500.012/500.011 ms) and
  `verify.mjs` passes. Engine license is MIT, so nothing GPL is vendored.
- **App-side integration (open loop)**: `FirmwareBackend`
  (`scripts/simulation/firmware_backend.gd`) detects Node + the harness honestly
  and runs a HEX; new API/MCP tools `get_firmware_capabilities`, `run_firmware`
  and `apply_firmware_pins` let a caller run firmware and drive real `mcu_pin`
  components from firmware output at a chosen instant (verified: D13 high at
  100 ms drives the signal node to 4.878 V = 5 V·1000/1025). **No catalog status
  changes** — protocol parts stay `planned`/`visual` until that is backed by tests.
  Node remains an optional external tool; the Godot suite is Node-free (632/632).
- **First protocol surface (UART)**: the harness instantiates USART0 and captures
  transmitted bytes, so `Serial.print` output is readable through `run_firmware`
  (`serial` / `serial_lines`). Verified with `firmware/sketches/serial_hello`
  ("CircuitForge tick 0…4", 105 bytes). Groundwork for protocol parts; no device
  is modeled on the other end yet.
- **I2C/SPI bus traces**: the harness records I2C transactions (address, direction,
  bytes) and SPI MOSI bytes; `run_firmware` returns `i2c` / `i2c_addresses` /
  `spi_bytes`. No device is modelled (I2C is ACKed, reads return 0xFF). Verified
  with `firmware/sketches/i2c_write` (write to `0x27`, bytes `0x00,0x41`). Suite
  634/634.
- **First firmware-driven device — PCF8574 I2C I/O expander** (catalog
  `planned` → **`partial`**, the first status change justified by a real
  firmware test): the netlist maps the `state` byte to eight ideal
  quasi-bidirectional `gpio` outputs P0..P7 against VSS (default 1 kΩ). New tool
  `apply_firmware_device` runs a HEX, takes the last byte written to the device's
  I2C address (`FirmwareBackend.last_i2c_write_byte`, default `0x27`) and sets
  `state` from it, optionally re-solving DC. Verified with
  `firmware/sketches/expander` (writes `0x55` → state `0x55`, levels
  `[1,0,1,0,1,0,1,0]`). Suite **645/645**; MCP **16/16** (new Test B6); tools
  **40**. Open loop: the port does not feed back into the firmware, and it is the
  only device modelled so far.
- **Closed bus loop (device → firmware)**: the harness now serves devices on the
  I2C bus (`CF_DEVICES`), so firmware can **read** them. `run_firmware(...,
  attach_devices=true)` attaches the circuit's `pcf8574`
  (`state`/`inputs`/`address`); with `inputs=0x0F` the port reads back `0xF0`.
  New sketch `firmware/sketches/expander_read` + `verify_expander_read.mjs`
  assert "port 240"; a PCF8574 write-back path (`state = writer byte`) already
  exists via `apply_firmware_device`, so both directions are covered. Helpers
  `FirmwareBackend.last_i2c_read_byte`; harness device models include a 24xx-style
  `eeprom`. Suite **648/648**; MCP **16/16**. Still no analog/ADC feedback.
- **Closed analog loop (circuit → firmware)**: new virtual part **`mcu_analog_in`**
  (ideal 1 GΩ high-impedance ADC probe, `partial`, `Virtual` 1 → 2 parts); the
  harness instantiates `AVRADC` and sets channel voltages from `CF_ADC`.
  `run_firmware(..., analog_map={"A0": "AIN1"})` solves the circuit and feeds each
  mapped node's voltage to `analogRead()`. Verified: 2.5 V → code 512
  (`verify_analog.mjs`); a 4 V/1k+1k divider midpoint (2.0 V) → code 409. Suite
  **653/653**; MCP **17/17** (new Test B7); catalog **240** defs, simulatable **74**.
- **Closed output loop (firmware → circuit)**: new virtual part **`mcu_pwm_out`**
  (average-voltage `vout`: `duty · vlogic` in series with `rout`; `partial`,
  `Virtual` 2 → 3). The harness reports each pin's PWM `duty`/`freq_hz`, and
  `apply_firmware_pwm(hex_path, pin_map={"9": "PWM1"})` sets the target's `voltage`
  to `duty·vlogic`, optionally re-solving. Verified: `analogWrite(9,128)` measures
  ~50.2% duty at ~490 Hz → 2.509 V, sagging to 2.448 V across 1 kΩ (`verify_pwm.mjs`).
  Suite **663/663**; MCP **18/18** (new Test B8); catalog **241** defs, simulatable **75**.
- **I2C EEPROM device — 24LC256**: new `eeprom_i2c` part (`external`, no breadboard
  model). `run_firmware(..., attach_devices=true)` attaches it; the harness `eeprom`
  device does two-byte-address writes plus sequential reads and returns the memory
  image (`devices[].mem`). Sketches `eeprom_roundtrip` (store `0xA5`, read back) and
  `eeprom_read` + `verify_eeprom.mjs` assert "eeprom 165". Honest limit: memory does
  not persist across separate runs. Suite **665/665**; MCP **19/19** (new Test B9);
  catalog **242** defs (`external` 36 → 37).
- **I2C ADC/DAC device — PCF8591**: new `pcf8591` part (`partial`). AIN0..AIN3 map to
  ideal 1 GΩ ADC probes and AOUT to an ideal Thevenin DAC (`vout`).
  `run_firmware(..., attach_devices=true)` solves the circuit and feeds each AIN
  channel's node voltage (8-bit over `vref`); `apply_firmware_device` drives `aout`
  from the firmware DAC byte. Sketches `pcf8591_read` (2.0 V divider → code 102) and
  `pcf8591_dac` + `verify_pcf8591.mjs` (2.5 V → 128). Suite **672/672**; MCP
  **20/20** (new Test B10); catalog **243** defs, `partial` 50 → 51, simulatable
  **76**.
- **I2C character LCD — 16x2 HD44780 backpack**: `i2c_lcd1602` promoted from
  `planned` to `external`. The harness decodes the 4-bit HD44780 protocol out of the
  backpack's PCF8574 writes (RS/RW/E/backlight + D4..D7), tracking clear/home/
  address commands and character writes, and returns the visible text as
  `devices[].lines`. Sketch `lcd_hello` (hand-written driver, no library) +
  `verify_lcd.mjs` assert "CircuitForge" / "3D". Suite **674/674**; MCP **21/21**
  (new Test B11); catalog `external` 37 → 38, `planned` 107 → 106.
- **HC-SR04 ultrasonic — firmware-driven MCU input pin**: `hcsr04` promoted from
  `planned` to `external`. The harness watches the firmware's TRIG pulse and drives
  ECHO (an MCU *input*) high for `distance_cm · 58 µs` after a 200 µs propagation
  delay, so `pulseIn()` measures a real echo — the first attached part to drive an MCU
  input *during* a run. Resolved from the netlist via `run_firmware(pin_map)` (like
  `analog_map`); the result adds `pin_devices` / `pin_inputs`. Sketch `ultrasonic` +
  `verify_ultrasonic.mjs` assert `echo 1735 dist 30` for a 30 cm target. Suite
  **676/676**; MCP **22/22** (new Test B12); catalog `external` 38 → 39,
  `planned` 106 → 105.
- **MPU-6050 IMU — served I2C register file**: `mpu6050` promoted from `planned` to
  `external`. The harness serves a register file (a write transaction's first byte
  sets the register pointer, further bytes auto-increment; reads return and
  auto-increment), with WHO_AM_I = 0x68 and the accel/temp/gyro counts filled from the
  component's `ax`..`gz`/`temp_c` parameters (16384 LSB/g, 131 LSB/(deg/s),
  340 LSB/degC). `run_firmware(..., attach_devices=true)` attaches it; a 14-byte burst
  from 0x3B decodes exactly. Sketch `mpu6050_read` + `verify_mpu6050.mjs`. Suite
  **678/678**; MCP **23/23** (new Test B13); catalog `external` 39 → 40,
  `planned` 105 → 104.
- **SSD1306 OLED — decoded GDDRAM framebuffer**: `oled_ssd1306` promoted from
  `planned` to `external`. The harness distinguishes the control byte (bit6 = D/C) and
  tracks page/horizontal/vertical addressing with the 0x21/0x22 range commands and the
  B0-B7 column-set, so a driver's frame writes land in the right place; the frame comes
  back as `devices[].pages_hex` plus `pixels_set` and `display_on`. Sketch `oled_fill`
  (hand-written init, no library) fills the top half; `verify_oled.mjs` asserts 4096 lit
  pixels and the exact per-page hex. Suite **680/680**; MCP **24/24** (new Test B14);
  catalog `external` 40 → 41, `planned` 104 → 103.
- **Rotary encoder — ideal quadrature pin device**: `rotary_encoder` promoted from
  `planned` to `external`, the second firmware-driven pin device after the HC-SR04. The
  harness walks the Gray cycle from the power-on state, changing exactly one pin per
  count so a polling decoder never sees a two-bit hop; the steps are reported under
  `pin_devices`. `run_firmware(..., pin_map=...)` resolves A/B from the netlist. Sketch
  `encoder_read` (hand-written quadrature table decoder) + `verify_encoder.mjs` assert
  50 forward, 50 reverse and 200 steps at a 500 µs step. Suite **682/682**; MCP
  **25/25** (new Test B15); catalog `external` 41 → 42, `planned` 103 → 102.
- **DHT11/DHT22 — bidirectional one-wire device**: both promoted from `planned` to
  `external`. The harness holds the line high (module pull-up) when the MCU releases it,
  detects the start signal (low ≥ 500 µs then released) and answers with the datasheet
  bit train, so sub-100 µs one-wire pulses are exact. Values come from `temp_c`/`humidity`
  and DATA is resolved from `pin_map`. Sketch `dht_read` (hand-written driver) +
  `verify_dht.mjs` assert the DHT22 frames (23.0/48.0 and −5.5/99.9, sign bit included),
  a DHT11 frame, and an unwired-pin timeout. Suite **686/686**; MCP **26/26** (new Test
  B16); catalog `external` 42 → 44, `planned` 102 → 100.
- **Bundled firmware example — DHT22 + I2C LCD logger**: `data/examples/
  15_firmware_env_logger.cf3d` (Arduino + DHT22 + I2C LCD + a virtual pin on the sensor's
  data net) with `firmware/sketches/env_logger`. The single hand-written sketch reads the
  sensor and reports through the LCD *and* serial, so circuit, `pin_map` resolution, device
  feedback and bus decoding are demonstrated together. `verify_env_logger.mjs` asserts both
  outputs agree; `test_examples.gd` loads the project and checks the DATA-net wiring.
  Bundled examples 14 → 15; suite **692/692**.
- **SHT31 — command-driven I2C temp/humidity with CRC-8**: `sht31` promoted from
  `planned` to `external`. The harness decodes the part's 16-bit commands and answers a
  read with two CRC-protected 16-bit words using the SHT3x CRC-8 (verified against the
  datasheet's 0xBE 0xEF → 0x92 vector). Sketch `sht31_read` (hand-written driver) +
  `verify_sht31.mjs` cover the values, both checksums, a deliberately corrupted CRC and a
  wrong I2C address. Suite **694/694**; MCP **27/27** (new Test B17); catalog
  `external` 44 → 45, `planned` 100 → 99.

### Milestone 8 — honest analog/digital parts (firmware-free subset complete; motors closed by M7)
- **Resistive sensors** (two-terminal, resistance set by a stimulus parameter,
  so no solver change was needed): `thermistor_ntc` (beta equation
  `R = R25*exp(B*(1/T - 1/T25))`), `photoresistor_ldr` (log-linear
  `R = R_dark*(R_light/R_dark)^light`) and `rtd_pt100` (linear RTD).
- **Brushed motors** `dc_motor`, `dc_gearmotor_tt`, `fan_5v`, `vibration_motor`:
  winding resistance plus an **assumed back-EMF** the user sets (0 V = stalled);
  steady state only, no spin-up or torque. `solenoid_12v` is a coil (inductance
  in series with winding resistance).
- **Display / switch / analog-output parts** that need no firmware:
  `seven_segment` (8 LEDs to the common pin, common-anode or common-cathode),
  `limit_switch` (SPDT COM-NO/COM-NC), `lm35`/`tmp36` (linear analog voltage
  output from a temperature stimulus) and `voltage_sensor_module` (resistive
  divider).
- **Digital/analog sensor modules** (firmware-free): ten digital-output sensors
  (`pir_hcsr501`, `ir_obstacle`, `hall_a3144`, `flame_sensor`, `sound_sensor`,
  `ldr_module`, `soil_moisture`, `rain_sensor`, `mq2_gas`, `mq135_air`) drive an
  ideal logic level from a `detected` stimulus; `acs712` (linear current sensor),
  `pressure_transducer_420ma` (4-20 mA loop) and `load_cell_5kg` (Wheatstone
  bridge).
- 3D: new `_body_bead` (sensor bead) and `_body_motor` (motor/vibration/solenoid/
  fan) package bodies, wired to the catalog shapes.
- `tests/unit/test_netlist.gd` extended (sensor resistance at several stimulus
  points, motor stalled vs running, seven-segment/anode-cathode, limit switch,
  sensor voltages, a divider solve and a 5 V/10 Ω/2 V-BEMF = 0.3 A solve);
  `tests/unit/test_factory.gd` builds the new shapes.
- Regression: **572 / 572 tests pass**, MCP **14 / 14**, headless load exits 0.
- **Servo motors (`servo_sg90`, `servo_mg996r`) — the first interactive part of this
  milestone**: promoted `planned` → `external`. A hobby servo is not attached to the bus
  at all: the control signal *is* the firmware's own 50 Hz pulse train, so the app
  measures the widths from the harness's exact-cycle transition record
  (`FirmwareBackend.pulse_widths` → `servo_angle` → `servo_position`), maps each part's
  band (`min_us`/`max_us` at 0…`range_deg`) onto an angle, reports it in `run_firmware`'s
  `servos` array, and `apply_firmware_servo(hex_path, pin_map)` writes it to the part's
  `angle`. Sketch `servo_sweep` (hand-written software PWM — no `Servo` library is
  bundled) + `verify_servo.mjs` recover a 0→180° sweep and a settled 90° to within 3°,
  the decode path is unit tested, and MCP Test B18 covers the tool. The angle is a
  *mechanical* state: no drive current, torque, load or slew is modelled and the solved
  circuit is unchanged. Suite **713/713**; MCP **28/28**; catalog `external` 45 → 47,
  `planned` 99 → 97.
- **Stepper motors through a STEP/DIR driver (`a4988_driver`, `drv8825_driver`,
  `stepper_nema17`)**: `stepper_nema17` `visual` → `external` and both drivers `planned` →
  `external`. The caller maps the firmware pins driving the driver's STEP/DIR nets to the
  components on those nets (the driver itself cannot be mapped: its nets do not say which
  pin drives them); the app counts the STEP rising edges, takes the sign from DIR at each
  edge, finds the motor wired to the driver's coil outputs, and writes the net `steps` plus
  the wrapping shaft `angle` (`steps_per_rev × microsteps` per turn). Sketch `stepper_sweep`
  (+200/−100/+50 = net +150 steps) + `verify_stepper.mjs` recover the move and check the
  ≥1 µs STEP pulse the driver needs. Suite **733/733**; MCP **29/29** (new Test B19);
  catalog `external` 47 → 50, `planned` 97 → 95, `visual` 23 → 22.
- **Four-phase steppers (`uln2003_driver`, `stepper_28byj48`)**: `stepper_28byj48`
  `visual` → `external` and `uln2003_driver` `planned` → `external`, which closes M8's
  motor gap. The driver's own phase sequence is the evidence: the app groups the phase-pin
  transitions by port write (so a two-coil wave hop is not mistaken for an invalid pattern),
  measures each valid change as the shortest move around the eight-state drive cycle and
  reports half-step travel, so wave, full-step and half-step sketches all decode the same
  way; a coil-off pattern breaks the sequence and nothing is counted across it. Sketch
  `stepper_4phase` (half 32 forward, then wave 8 reverse and 8 forward) + `verify_4phase.mjs`
  recover net +32 half steps with the two coil-off gaps counted as skipped. Suite
  **748/748**; MCP **29/29**; catalog `external` 50 → 52, `planned` 95 → 94, `visual` 22 → 21.
- **Motion capstone example** (`data/examples/16_firmware_motion.cf3d`): the first *actuator*
  example and the first that drives two firmware outputs at once — an SG90 servo and an
  A4988/NEMA 17 stepper, each behind its own virtual pin, run by one sketch
  (`firmware/sketches/motion_demo`) that interleaves a 50 Hz servo sweep with a +200/−50 step
  move. `verify_motion.mjs` recovers both from the same transition record (servo 0..180
  settling at 90, stepper net +150 steps), which is a stronger check than the two separate
  verifiers. Writing it found two genuine firmware bugs (pulse-width math overflowing 16-bit
  `int`; the schedule not fitting in `int8_t`), and `apply_firmware_servo` was made to accept
  the same `pin_map` convention as `run_firmware` (servo id *or* the component on its PWM
  net). Bundled examples 15 → **16**; harness verifiers 19 → **20**; suite 748 → **756**.
- **SPI SSD1306 OLED** (`oled_ssd1306_spi`, `planned` → `external`): the SSD1306 decoded
  from the AVR's SPI peripheral instead of an I2C address, which closes the last named M7
  gap. The harness tags each transfer with the panel's DC (command/data) and CS (selected)
  levels, sampled live from the MCU's own port state, and the app resolves those two lines to
  firmware pins from `pin_map` when it builds the device spec from the circuit — so a panel
  is wired and mapped exactly like a sensor. The GDDRAM engine is shared with the I2C part
  (`makeSsd1306`). `oled_spi` (hardware SPI: a bit-banged bus would be invisible) draws the
  left half white; `verify_oled_spi.mjs` checks the frame *and* reruns the bytes with no DC
  line to prove DC is genuinely what splits command from data. Suite **764/764**; harness
  verifiers **21**; catalog `external` 52 → **53**, `planned` 94 → **93**.
- **ILI9341 colour TFT** (`tft_ili9341`, `planned` → `external`): the SPI plumbing proven
  general on a second, richer panel — a 240x320 RGB565 engine instead of a monochrome
  GDDRAM. The ILI9341 inverts the SSD1306's tagging rule (DC low = command, DC *high* = its
  parameters and the `0x2C` pixel stream), so the decoder holds a pending command and feeds
  DC-high bytes to it until its argument count is met; the usual init registers are consumed
  the same way so their bytes cannot be mistaken for commands. Since a frame is 153600 bytes
  the reply is a summary (`pixels_written`, `colors`, an FNV-1a `frame_hash` over the whole
  buffer, probe pixels, `window`, `madctl`/`colmod`, `display_on`) instead of the buffer.
  `tft_fill` draws the left half red / right half blue; `verify_tft.mjs` recomputes the hash
  from the expected pattern (all 76800 pixels) plus a no-DC negative control. The app
  resolves DC (pin 4) and CS (pin 2) from `pin_map` like the OLED. Suite **771/771**; harness
  verifiers **22**; catalog `external` 53 → **54**, `planned` 93 → **92**.
- **SPI trace cap**: a full-screen frame produced a ~1.1 MB `spi_bytes` array, so the trace
  is capped at 4096 bytes (`CF_SPI_LIMIT`) with the true length in `spi_byte_count`.
- **MCP3008 8-channel SPI ADC** (`mcp3008`, `planned` → `external`): the third SPI device and
  the first one firmware can *read*. The two panels are written to and never answer, so the
  monitor had ignored MISO (every transfer returned `0x00`); now each selected device returns
  what MISO carries, and the SPI monitor detects the CS high → low edge that starts a
  transaction, because a conversion is framed by CS rather than by byte values. The device
  serves the datasheet's three-transfer conversion inside one CS-low window (`0x01`, then
  `0x80 | channel << 4`, then a don't-care), clocking out a leading zero bit and then the
  10-bit code, so a driver's `((hi & 0x03) << 8) | lo` gets the value. Its CH0..CH7 pins are
  probes on the solved nets (the same closed loop as the PCF8591), coded by the `vref`
  parameter. `spi_adc` reads channels 0..3 with hand-written transfers; `verify_spi_adc.mjs`
  checks the codes the sketch printed against the spec (3.3 V → 675, 1.25 V → 256, 0 V → 0,
  5 V → 1023), the per-read volts, the trace and `deselected` = 0, plus a full-scale control and
  a **no-device control** (the bus then idles at 0x00, so the same firmware must read zeros —
  proving the codes came from the device, not the sketch). Suite **788/788**; harness verifiers
  **23**; catalog `external` 54 → **55**, `planned` 92 → **91**.
- **ADXL345 accelerometer** (`adxl345`, `planned` → `external`): a served I2C register file
  with the MPU-6050's plumbing but the ADXL345's own map — DEVID is `0xE5`, the data registers
  (0x32..0x37) are little-endian 16-bit two's complement, and the sample accelerations come
  from the part's `ax`/`ay`/`az` parameters. The interesting part is that the *scale* is the
  firmware's choice rather than a fixed full-scale: DATA_FORMAT (0x31) FULL_RES (bit 3) is
  3.9 mg/LSB (256 LSB/g) at every range, and in 10-bit mode it is `256 >> range` LSB/g (so
  ±4 g is 128 LSB/g), and the data registers are computed from the live configuration, so
  writing DATA_FORMAT changes the counts a read returns. `adxl345_read` writes the config,
  reads it back and then does a 6-byte burst; `verify_adxl345.mjs` checks DEVID, the
  read-back, the counts and the milli-g conversion at the scale the sketch selected, plus a
  positive control and a no-device control (the bus reads 0xFF, so the readings cannot have
  come from the sketch). Suite **796/796**; harness verifiers **24**; catalog `external`
  55 → **56**, `planned` 91 → **90**. Honest limits: only I2C is served, and the FIFO,
  tap/free-fall/activity interrupts, self-test and the offset registers are not modelled.
- **ADS1115 16-bit ADC** (`ads1115`, `planned` → `external`): the I2C twin of the MCP3008
  read path, and the point where the two proven mechanisms meet — an addressed register file
  (four 16-bit registers behind a pointer: 0x00 conversion, 0x01 config, 0x02/0x03
  thresholds, read and written MSB first) *and* solved-voltage probes (A0..A3 come from the
  nets they sit on, like the MCP3008's channels). The conversion depends on what the
  *firmware* wrote: the MUX bits pick single-ended A0..A3 against GND or one of the
  differential pairs, and the PGA bits pick ±6.144/4.096/2.048/1.024/0.512/0.256 V full
  scale as a 16-bit two's complement code. Conversion timing is not modelled, so single-shot
  and continuous drivers both work. `ads1115_read` reads A0..A3 single-ended, the A0/A1 pair
  and a finer gain; `verify_ads1115.mjs` checks every code and milli-volt at the settings the
  sketch wrote, the device-side read log, the final config/MUX/PGA, a positive control that
  reaches negative full scale and a no-device control (the bus reads 0xFF); a solved divider
  was read back end to end (2.5 V → code 20000, and 2.5 V differentially against a 0 V
  channel). Suite **806/806**; harness verifiers **25**; catalog `external` 56 → **57**,
  `planned` 90 → **89**. Honest limits: the ALERT/RDY comparator, the ADDR pin's address
  selection (the address is a parameter), the input loading and conversion timing are not
  modelled.
- **MCP4725 12-bit DAC** (`mcp4725`, `planned` → `partial`): the write-only end of the bus,
  and the first firmware part whose *output drives the circuit* through the netlist. There is
  nothing to read back, so the harness decodes the writes: the first byte is the general write
  command (0x40 = the DAC register, 0x60 = also the EEPROM, power-down in bits 1..0) and the
  next two data bytes carry the 12-bit code in their top 12 bits. `apply_firmware_device`
  serves the part, reads the decoded `code` from the device summary (one implementation of the
  protocol, in the harness) and sets the part's `vout` = `code/4096 · vref` — so firmware's
  code becomes a voltage the *next solve* sees. The netlist maps VOUT as a Thevenin source
  (`vout` + `rout`), and a non-zero power-down code is carried into `power_down`, where the
  netlist replaces the source with a 1 k/100 k/500 k resistor to GND (the real part only pulls
  down then). `dac_out` writes 2.5/1/4.878 V, an EEPROM write, a power-down write and a final
  normal write, then a fast-mode-style first byte; `verify_dac_out.mjs` recomputes every printed
  code and milli-volt, checks the decoded write/EEPROM/power-down bits, a 3.3 V reference
  control (only `volts` follows) and a wrong-address control (nothing is decoded), and a
  no-device run (the trace still records the writes, but no code is decoded). A circuit was
  driven end to end (code 3300 → `vout` 4.028 V → the solved load node at 3.930 V through the
  25 Ω source). Suite **817/817**; harness verifiers **26**; catalog `partial` 51 → **52**,
  `planned` 89 → **88**. Honest limits: the EEPROM is decoded and counted but nothing persists
  (no memory survives a run), the fast-mode write encoding is not decoded (an unrecognised
  command is counted), and the power-on-reset/MTP recall value, the `A` variant's internal
  reference and the part's supply/electrical limits are not modelled.
- Still planned/visual: the e-paper SPI display, and the gas/analog
  sensor modules (an SPI *ADC path* now exists — see the MCP3008 above — but those specific
  modules are not modelled). The remaining `planned`/`visual` parts generally need a model the
  app does not have yet — see `docs/catalog/status_report.md`. Servos, STEP/DIR steppers and the four-phase
  `uln2003_driver`/`stepper_28byj48` pair are done (above), and the LCD/OLED/I2C/DHT/
  ultrasonic/IMU parts are closed by the M7 device work above.

### Milestone 9 — MCP pin/metadata tooling (done)
- New MCP tools (34 → **36**, plus **7** M7/M8 firmware tools —
  `get_firmware_capabilities`, `run_firmware`, `apply_firmware_pins`,
  `apply_firmware_device`, `apply_firmware_pwm`, `apply_firmware_servo`,
  `apply_firmware_stepper` — for **43**
  total):
  `get_pin_states` (read the state of every
  `mcu_pin`: level, high/low/high-Z, logic voltage, output resistance, driven
  node and solved voltage) and `set_pin_levels` (drive one or more pins, with an
  optional DC re-solve). This is the Stage-A "pin states" workflow — ideal pins,
  no firmware execution.
- `get_board_pinout` (M5) already exposes documented board pin maps with
  provenance. Firmware upload/execution stays gated (plan M7).
- Integration suite now runs Tests A–J plus B2–B19 = **29 / 29** over the **43** tools
  (every tool's presence, input schema and the pin-state/board/firmware behaviour).

### Milestone 10 — examples, robustness, docs (done)
- **Solver robustness**: fixed the `gmin` leakage no-op (`_add_gmin` used
  `add_g(i, i, gmin)`, which cancels for `p == n`). A new `MNA.add_shunt` puts a
  real 1e-9 S shunt on every node, so a node with no resistive path solves to
  ~0 V instead of returning "singular matrix". This is what lets a partly-wired
  7-segment display (unlit segments floating) simulate.
- **Bundled examples** 11 → **14**: a 7-segment digit, an NTC thermistor divider
  and a limit-switch-driven DC motor, each with documented values that
  `test_examples.gd` spot-checks.
- **Scale test** (`tests/solver/test_scale.gd`): a 200-node resistor ladder
  solves in ~14 ms, guarding against accidental solver complexity regressions.
- **Component-count / performance pass**: `tools/bench.gd` times both the solver on
  synthetic ladders (200/400/800 nodes: 15.7 / 62.5 / 241.7 ms) and the *whole* pipeline
  on dense breadboard projects (25/50/100/200 LED+resistor branches, i.e. up to 402
  components and a nonlinear solve: netlist build 43 ms, solve 257 ms). Numbers and
  reading recorded in `docs/plan/m10_performance.md`. `test_scale.gd` now guards the
  component-count dimension too — the dense project's branch current must scale linearly
  (which also proves all branches were really wired in parallel) and stay inside a
  generous 5 s budget.
- **Visual evidence**: the app takes `-- --screenshot=<path>` (load, settle,
  save PNG, quit); `docs/plan/m10_seven_segment.png` and
  `docs/plan/m10_ntc_thermistor.png` show the new examples solving in the UI, and
  `m10_env_logger.png` / `m10_motion_demo.png` are the windowed pass over the two firmware
  examples (board rendered, project named, the "not yet simulatable; skipped" diagnostics
  visible and honest).
- Regression: **607 / 607 tests pass**, MCP **14 / 14**, headless load exits 0,
  catalog report has 0 errors.
- Remaining: nothing on this milestone's checklist; the Linux *runtime* pass stays blocked
  on WSL availability (the binary is ELF-validated and documented honestly instead).

### Verification habit (per milestone)
1. `godot --headless --script res://tests/run_tests.gd` → must stay green
   (currently 817/817).
2. `godot --headless --quit-after 90` → exit 0 (no parse/runtime errors).
3. Launch windowed, load an example, screenshot into `docs/plan/`.
4. `CIRCUITFORGE_GODOT=... python mcp_server/tests/test_mcp_integration.py` →
   29/29.
5. `cd firmware/harness` and run each `verify_*.mjs` against its compiled sketch →
   all pass (26 verifiers).

## 4. Component implementation status vocabulary

Every catalog entry gains:

```json
"simulation_status": "full" | "partial" | "visual" | "external" | "planned",
"simulation_models": ["ohmic", "nonlinear-diode", ...],
"simulation_backend": "" | "mna" | "gpio" | "mcu-avr",
"notes": "free text shown in the inspector and returned over MCP"
```

- **full** — the solver produces real voltages/currents for it.
- **partial** — simulated with documented simplifications (e.g. ideal switch,
  fixed-threshold logic, ideal source + series resistance).
- **visual** — appears in 3D and can be wired, but has no electrical model yet.
- **external** — behaviour belongs to a host/backend (USB, ADB, firmware).
- **planned** — catalogued and placeable, not simulated yet.
- Everything except `full`/`partial` is clearly labelled and never reported as
  working. See `docs/catalog/schema.md`.

## 5. Baseline preservation

Git history is the recovery mechanism. The pre-upgrade state is commit `5333270`
("M10: AI-native MCP integration"). A visual baseline screenshot is stored at
`docs/plan/baseline_ui.png`.
