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
  - **238 definitions across 16 categories** (`data/components/`), 0 validation
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
  - 33 tools, 7 resources (`circuit://…`) and 8 prompts; read/inspect/edit/
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
