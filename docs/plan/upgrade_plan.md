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
| 7 | Code execution backend (Stage B/C) — feasibility-gated | spike done (avr8js/MIT runs a compiled Uno blink deterministically on Windows; see `docs/plan/m7_firmware_backend.md`); app-side integration done (UART/I2C/SPI traces); first device (PCF8574) modelled `partial` |
| 8 | Sensors, displays, motors, advanced analog/digital parts | done for the firmware-free subset (resistive/analog sensors, brushed motors, 7-segment, limit switch); protocol/digital parts gated on plan M7 |
| 9 | Extend MCP tools/metadata for boards, pinouts, pin states, firmware | in progress (pin-state tools + board pinouts/facets exposed; firmware gated) |
| 10 | Performance pass, examples, tests, Windows/Linux verification, docs | nearly done (examples + gmin fix + scale test + Windows screenshot evidence, suite 607/607; Linux runtime verification remains blocked on WSL) |

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

### Milestone 8 — honest analog/digital parts (firmware-free subset complete)
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
- Still planned/visual (needs a firmware/Stage-B backend): stepper and servo
  motors and their drivers, LCD/OLED/I2C/SPI displays, and digital/protocol
  sensors (DHT, ultrasonic, gas, IMU, ...).

### Milestone 9 — MCP pin/metadata tooling (in progress)
- New MCP tools (34 → **36**, later **39** with the M7 firmware tools):
  `get_pin_states` (read the state of every
  `mcu_pin`: level, high/low/high-Z, logic voltage, output resistance, driven
  node and solved voltage) and `set_pin_levels` (drive one or more pins, with an
  optional DC re-solve). This is the Stage-A "pin states" workflow — ideal pins,
  no firmware execution.
- `get_board_pinout` (M5) already exposes documented board pin maps with
  provenance. Firmware upload/execution stays gated (plan M7).
- Integration suite now runs Tests A–J + B2 + B3 + B4 = **14 / 14**.

### Milestone 10 — examples, robustness, docs (in progress)
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
- **Visual evidence**: the app takes `-- --screenshot=<path>` (load, settle,
  save PNG, quit); `docs/plan/m10_seven_segment.png` and
  `docs/plan/m10_ntc_thermistor.png` show the new examples solving in the UI.
- Regression: **607 / 607 tests pass**, MCP **14 / 14**, headless load exits 0,
  catalog report has 0 errors.
- Remaining: a component-count/performance pass, and a windowed screenshot pass
  into `docs/plan/`.

### Verification habit (per milestone)
1. `godot --headless --script res://tests/run_tests.gd` → must stay green
   (currently 607/607).
2. `godot --headless --quit-after 90` → exit 0 (no parse/runtime errors).
3. Launch windowed, load an example, screenshot into `docs/plan/`.
4. `CIRCUITFORGE_GODOT=... python mcp_server/tests/test_mcp_integration.py` →
   14/14.

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
