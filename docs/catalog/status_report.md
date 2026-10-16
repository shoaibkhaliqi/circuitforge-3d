# Catalog status report

Generated from `tools/catalog_report.gd`
(`godot --headless --path <project> --script res://tools/catalog_report.gd`).

This report is deliberately blunt: it separates *what looks like a part* from
*what the solver can actually compute*.

## Totals

| metric | value |
|--------|-------|
| Definitions | 237 |
| Categories | 15 |
| Simulatable (`full` + `partial`) | 68 |

## By simulation status

| status | count | meaning |
|--------|------:|---------|
| `full` | 25 | working solver model, covered by tests |
| `partial` | 43 | real but approximate electrical model |
| `visual` | 6 | rendered only, no electrical behaviour |
| `external` | 36 | host/backend behaviour (USB, ADB, firmware) |
| `planned` | 127 | catalogued and placeable, not simulated yet |
| **errors** | **0** | no schema/validation problems |

## By category

| category | count |
|----------|------:|
| Passive | 21 |
| Sources | 11 |
| Semiconductor | 22 |
| Logic | 13 |
| Analog IC | 12 |
| Display | 9 |
| Sensor | 38 |
| Communication | 11 |
| Power | 12 |
| Motor & Actuator | 16 |
| Connector | 16 |
| Instrument | 9 |
| Board | 20 |
| Android Hardware | 12 |
| Mobile Device | 15 |

## Fully simulated core (`full`)

Passives: `resistor`, `capacitor`, `inductor`, `potentiometer`, `switch`,
`push_button`. Sources: `vsource`, `isource`, `ground`. Semiconductors: `led`
(and colour variants), `diode`, `rectifier_diode`, `schottky_diode`, `zener`.
Logic: `and`, `or`, `not`, `nand`, `nor`, `xor`, `buffer`.

## Partially simulated (`partial`)

Ideal-source-style approximations: batteries and cells, `breadboard_psu_5v`,
regulators (`lm7805`, `lm1117_33`, `ams1117_50`), DC-DC modules, `bench_psu`,
relay coil, and component models that reduce to resistors (motors, solenoids,
coils, fuses/varistors cold, connector pass-throughs).

## Honest caveats

- Boards, phones, TV boxes and instruments are `planned`/`external` on purpose.
  A board's 3D model is **not** a CPU; firmware execution is a separate, gated
  milestone.
- Android devices are host/client hardware with **no breadboard GPIO**; only USB,
  OTG, ADB and UART debug are modelled, and UART debug wiring varies per device.
- `xnor` is catalogued but not solved; sequential logic (`d_flip_flop`, counters,
  shift registers) are `planned`.
- eCO2 sensors report an *estimate*, not a true NDIR measurement; the catalog
  says so in their `notes`.

Re-run the report after any catalog change to keep these numbers honest.
