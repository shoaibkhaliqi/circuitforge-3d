# Catalog status report

Generated from `tools/catalog_report.gd`
(`godot --headless --path <project> --script res://tools/catalog_report.gd`).

This report is deliberately blunt: it separates *what looks like a part* from
*what the solver can actually compute*.

## Totals

| metric | value |
|--------|-------|
| Definitions | 243 |
| Categories | 16 |
| Simulatable (`full` + `partial`) | 76 |

## By simulation status

| status | count | meaning |
|--------|------:|---------|
| `full` | 25 | working solver model, covered by tests |
| `partial` | 51 | real but approximate electrical model |
| `visual` | 21 | rendered only, no electrical behaviour |
| `external` | 57 | host/backend behaviour (USB, ADB, firmware) |
| `planned` | 89 | catalogued and placeable, not simulated yet |
| **errors** | **0** | no schema/validation problems |

## By category

| category | count |
|----------|------:|
| Passive | 21 |
| Sources | 11 |
| Semiconductor | 22 |
| Logic | 13 |
| Analog IC | 15 |
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
| Virtual | 3 |

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
`ac_source`; the infra-red `led_ir`; the Stage-A virtual pins `mcu_pin` (an ideal
Thevenin driver) and `mcu_analog_in` (an ideal 1 GΩ high-impedance ADC probe);
resistive sensors (`thermistor_ntc`,
`photoresistor_ldr`, `rtd_pt100`) whose resistance is set by a stimulus
parameter; and brushed motors (`dc_motor`, `dc_gearmotor_tt`, `fan_5v`,
`vibration_motor`) modelled as winding resistance plus an assumed back-EMF,
with `solenoid_12v` as a coil. Also `seven_segment` (8 LEDs to the common pin),
`limit_switch` (SPDT COM-NO/COM-NC), the analog-output `lm35`/`tmp36`
temperature sensors and the `voltage_sensor_module` divider. The virtual
`mcu_pwm_out` is the average-voltage (`duty · vlogic`) analog output of a PWM
pin, driven by firmware `analogWrite()` via `apply_firmware_pwm`. Digital-output
sensors (`pir_hcsr501`, `ir_obstacle`, `hall_a3144`, `flame_sensor`,
`sound_sensor`, `ldr_module`, `soil_moisture`, `rain_sensor`, `mq2_gas`,
`mq135_air`) drive their OUT/DO pin as an ideal logic level set by a `detected`
stimulus (analog outputs are not modelled). Analog modules: `acs712` (linear
current sensor, `Vcc/2 + sensitivity·I`), `pressure_transducer_420ma` (4–20 mA
loop source) and `load_cell_5kg` (four-arm Wheatstone bridge). The `pcf8574`
I2C I/O expander drives P0..P7 as ideal quasi-bidirectional outputs from its
`state` byte (or from firmware I2C writes via `apply_firmware_device`); firmware
can also read it back (`run_firmware(..., attach_devices=true)`), where `inputs`
marks bits externally held low. The `pcf8591` I2C ADC/DAC exposes AIN0..AIN3 as
ideal 1 GΩ ADC probes (firmware reads each solved node's 8-bit code) and AOUT as an
ideal Thevenin DAC output driven by `aout` (or from firmware writes via
`apply_firmware_device`).

## Honest caveats

- A part may only claim `full`/`partial` if the netlist builder actually maps it;
  this is enforced by `tests/unit/test_netlist.gd`, so the status can never drift
  ahead of the solver. Parts without a truthful model are `visual`.
- Connectors and IC sockets, the remaining SPI displays (the e-paper module) and the gas/analog sensor modules that need a real
  ADC path, multi-pin regulators and DC-DC modules, relays, the USB power meter, and any
  remaining protocol parts that need a bus or timing they do not yet have are
  `visual`/`planned` for now — they need a firmware/Stage-B backend or a model that does not
  exist yet. The `seven_segment` display and the
  digital-output sensors are the exceptions: they are plain LEDs or ideal logic
  levels, so they run without firmware by driving their pins directly. The
  `pcf8574` I2C expander is the first *bus* part backed by firmware: firmware drives
  its port (last I2C write byte) and can read it back (device → firmware). The
  `eeprom_i2c` 24C02, the `pcf8591` ADC/DAC (channels from solved nodes) and the
  `i2c_lcd1602` character display are pure-backend parts (`external`): they have no
  breadboard electrical model and are served on the I2C bus only while firmware runs
  (the LCD's visible text comes back as `devices[].lines`). The `hcsr04` ultrasonic
  sensor is the first *pin* part backed by firmware: the harness watches its TRIG
  pulse and drives its ECHO line (an MCU input) for a distance-proportional time. The
  `mpu6050` IMU is the first *register-map* part: a served I2C register file (pointer
  + auto-increment) whose accel/temp/gyro counts come from its parameters. The
  `adxl345` accelerometer is the same pattern with a different map (DEVID `0xE5`,
  little-endian data registers) and one property the IMU does not have: its scale is the
  firmware's choice, so `DATA_FORMAT`'s range/FULL_RES bits decide the LSB/g and the counts
  are recomputed from the live configuration at read time. The
  `oled_ssd1306` is the first *framebuffer* part: the harness decodes the SSD1306
  command/data stream into GDDRAM and returns the frame (`devices[].pages_hex`). Its
  `oled_ssd1306_spi` sibling is the first *SPI-peripheral* part: there is no address to
  serve, so the harness tags each transfer from the ATmega's SPI peripheral with the
  panel's DC line (command vs data) and CS (selected), both resolved to firmware pins
  through `pin_map`, and feeds the same GDDRAM model. The `tft_ili9341` colour panel uses
  the same plumbing with an RGB565 engine: DC low is a command, DC high its parameters and
  the `0x2C` pixel stream, and because a full frame is 153600 bytes the result is a
  *summary* (pixels_written, colours, an FNV-1a `frame_hash`, probe pixels, MADCTL/COLMOD)
  rather than the buffer. The `mcp3008` is the first SPI part the firmware can *read*: the
  two panels never answer, so until it arrived MISO was ignored — now each selected device
  returns the byte MISO carries, and the CS edge (not the byte values) frames a conversion.
  It serves the datasheet's three transfers (`0x01`, `0x80 | channel << 4`, a don't-care) and
  clocks out a leading zero bit plus the 10-bit code, taken from the solved voltage on that
  channel's net over the `vref` parameter. The `ads1115` is the I2C twin of that read path and
  the point where the two proven mechanisms meet: an addressed register file whose conversion
  comes from the solved voltages on A0..A3, scaled by whatever MUX/PGA the firmware writes —
  and because both members of a differential pair are resolved, its differential mode is
  modelled (the MCP3008's is not). The
  `rotary_encoder` is a pin device like the HC-SR04: the harness steps an ideal
  quadrature A/B pair, so a firmware decoder can be checked. `dht11`/`dht22` are
  bidirectional one-wire pin devices: the harness answers the start signal with a
  datasheet-timed bit train. `sht31` is the first *command-driven, checksum-protected*
  I2C part: the harness decodes 16-bit commands and answers with two CRC-8-checked
  16-bit words. `servo_sg90`/`servo_mg996r` are the first *mechanical-output* parts:
  no device is attached at all — the app decodes the commanded angle from the firmware's
  own 50 Hz pulse train (`servos`, `apply_firmware_servo`), which is a mechanical state
  rather than an electrical one. `stepper_nema17` with the STEP/DIR drivers
  (`a4988_driver`/`drv8825_driver`) is the same idea for travel: the STEP edges are
  counted with the sign DIR held at each one and applied to the motor on the driver's
  coil outputs (`steppers`, `apply_firmware_stepper`). `stepper_28byj48` with the
  four-phase `uln2003_driver` is measured from the phase sequence instead: each valid
  pattern change is worth the shortest move around the drive cycle, so wave, full-step and
  half-step sketches all decode to half steps.
- Boards, phones, TV boxes and instruments are `planned`/`external` on purpose.
  A board's 3D model is **not** a CPU. An optional firmware backend now exists (AVR
  firmware on the MIT avr8js engine): it drives `mcu_pin`s and `mcu_pwm_out`
  (`analogWrite()` duty) from firmware output, and reads the circuit back into the
  firmware through `mcu_analog_in` (`analogRead()`), served I2C devices
  (`pcf8574`) and pin sensors (`hcsr04`); it also exposes UART/`Serial` plus
  I2C/SPI bus traces (an SPI panel is decoded from that trace, and a trace larger than
  4096 bytes is capped with its true length reported in `spi_byte_count` — never passed off
  as the whole one). Other
  protocol/digital parts stay `planned` until a firmware-driven part is itself
  tested and mapped.
- Android devices are host/client hardware with **no breadboard GPIO**; only USB,
  OTG, ADB and UART debug are modelled, and UART debug wiring varies per device.
- `xnor` is catalogued but not solved; sequential logic (`d_flip_flop`, counters,
  shift registers) are `planned`.
- eCO2 sensors report an *estimate*, not a true NDIR measurement; the catalog
  says so in their `notes`.

Re-run the report after any catalog change to keep these numbers honest.
