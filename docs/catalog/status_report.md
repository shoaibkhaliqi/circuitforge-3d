# Catalog status report

Generated from `tools/catalog_report.gd`
(`godot --headless --path <project> --script res://tools/catalog_report.gd`).

This report is deliberately blunt: it separates *what looks like a part* from
*what the solver can actually compute*.

## Totals

| metric | value |
|--------|-------|
| Definitions | 239 |
| Categories | 16 |
| Simulatable (`full` + `partial`) | 73 |

## By simulation status

| status | count | meaning |
|--------|------:|---------|
| `full` | 25 | working solver model, covered by tests |
| `partial` | 48 | real but approximate electrical model |
| `visual` | 23 | rendered only, no electrical behaviour |
| `external` | 36 | host/backend behaviour (USB, ADB, firmware) |
| `planned` | 107 | catalogued and placeable, not simulated yet |
| **errors** | **0** | no schema/validation problems |

## By category

| category | count |
|----------|------:|
| Passive | 21 |
| Sources | 11 |
| Semiconductor | 22 |
| Logic | 13 |
| Analog IC | 13 |
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
`ac_source`; the infra-red `led_ir`; the Stage-A virtual MCU pin `mcu_pin`
(an ideal Thevenin driver); resistive sensors (`thermistor_ntc`,
`photoresistor_ldr`, `rtd_pt100`) whose resistance is set by a stimulus
parameter; and brushed motors (`dc_motor`, `dc_gearmotor_tt`, `fan_5v`,
`vibration_motor`) modelled as winding resistance plus an assumed back-EMF,
with `solenoid_12v` as a coil. Also `seven_segment` (8 LEDs to the common pin),
`limit_switch` (SPDT COM-NO/COM-NC), the analog-output `lm35`/`tmp36`
temperature sensors and the `voltage_sensor_module` divider. Digital-output
sensors (`pir_hcsr501`, `ir_obstacle`, `hall_a3144`, `flame_sensor`,
`sound_sensor`, `ldr_module`, `soil_moisture`, `rain_sensor`, `mq2_gas`,
`mq135_air`) drive their OUT/DO pin as an ideal logic level set by a `detected`
stimulus (analog outputs are not modelled). Analog modules: `acs712` (linear
current sensor, `Vcc/2 + sensitivity·I`), `pressure_transducer_420ma` (4–20 mA
loop source) and `load_cell_5kg` (four-arm Wheatstone bridge). The `pcf8574`
I2C I/O expander drives P0..P7 as ideal quasi-bidirectional outputs from its
`state` byte (or from firmware I2C writes via `apply_firmware_device`).

## Honest caveats

- A part may only claim `full`/`partial` if the netlist builder actually maps it;
  this is enforced by `tests/unit/test_netlist.gd`, so the status can never drift
  ahead of the solver. Parts without a truthful model are `visual`.
- Connectors and IC sockets, stepper and servo motors and their drivers, multi-pin
  regulators and DC-DC modules, relays, the USB power meter, and protocol/digital
  sensors and displays that need a bus or timing (LCD/OLED/I2C/SPI, DHT,
  ultrasonic, IMU, quadrature encoders) are `visual`/`planned` for now — they need
  a firmware/Stage-B backend to be honest. The `seven_segment` display and the
  digital-output sensors are the exceptions: they are plain LEDs or ideal logic
  levels, so they run without firmware by driving their pins directly. The
  `pcf8574` I2C expander is the first *bus* part backed by firmware: it drives its
  port from the byte the firmware writes (open-loop, no device→firmware feedback).
- Boards, phones, TV boxes and instruments are `planned`/`external` on purpose.
  A board's 3D model is **not** a CPU. An optional, open-loop firmware backend now
  exists (AVR firmware on the MIT avr8js engine, driving `mcu_pin`s from firmware
  output and exposing UART/`Serial` plus I2C/SPI bus traces); other protocol/digital
  parts stay `planned` until a firmware-driven part is itself tested and mapped.
- Android devices are host/client hardware with **no breadboard GPIO**; only USB,
  OTG, ADB and UART debug are modelled, and UART debug wiring varies per device.
- `xnor` is catalogued but not solved; sequential logic (`d_flip_flop`, counters,
  shift registers) are `planned`.
- eCO2 sensors report an *estimate*, not a true NDIR measurement; the catalog
  says so in their `notes`.

Re-run the report after any catalog change to keep these numbers honest.
