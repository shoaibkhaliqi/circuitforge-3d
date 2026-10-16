# Catalog status report

Generated from `tools/catalog_report.gd`
(`godot --headless --path <project> --script res://tools/catalog_report.gd`).

This report is deliberately blunt: it separates *what looks like a part* from
*what the solver can actually compute*.

## Totals

| metric | value |
|--------|-------|
| Definitions | 238 |
| Categories | 16 |
| Simulatable (`full` + `partial`) | 46 |

## By simulation status

| status | count | meaning |
|--------|------:|---------|
| `full` | 25 | working solver model, covered by tests |
| `partial` | 21 | real but approximate electrical model |
| `visual` | 29 | rendered only, no electrical behaviour |
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
| Virtual | 1 |

## Fully simulated core (`full`)

Passives: `resistor`, `capacitor`, `inductor`, `potentiometer`, `trimmer`,
`shunt_resistor`, `switch`, `push_button`. Sources: `vsource`, `isource`,
`ground`. Semiconductors: `led` (and green/blue variants), `diode`,
`rectifier_diode`, `schottky_diode`, `zener`. Logic: `and`, `or`, `not`, `nand`,
`nor`, `xor`, `buffer`.

## Partially simulated (`partial`)

Documented approximations: capacitor variants (`electrolytic_capacitor`,
`film_capacitor`, `tantalum_capacitor`, `supercapacitor`), `ferrite_bead`, SPDT
`toggle_switch`, `reed_switch`, `polyfuse`; ideal-source batteries and cells
(`battery_aa`/`aaa`/`9v`/`18650`, `coin_cell_cr2032`, `lipo_1s`,
`battery_aa_holder`), `usb_power_5v`, `bench_psu`, `breadboard_psu_5v`,
`ac_source`; the infra-red `led_ir`; and the Stage-A virtual MCU pin `mcu_pin`
(an ideal Thevenin driver).

## Honest caveats

- A part may only claim `full`/`partial` if the netlist builder actually maps it;
  this is enforced by `tests/unit/test_netlist.gd`, so the status can never drift
  ahead of the solver. Parts without a truthful model are `visual`.
- Connectors and IC sockets, motors/solenoids/steppers, multi-pin regulators and
  DC-DC modules, relays, the USB power meter and sensor modules are `visual` for
  now — their 3D models render, but no electrical model is claimed. Sensors,
  displays and motors are the M8 milestone.
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
