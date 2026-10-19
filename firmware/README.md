# Firmware harness (M7 spike)

This is the **Stage B proof** that CircuitForge 3D can execute real Arduino
firmware without vendoring a GPL engine. It is a **spike**, not the product: the
Godot test suite never requires it, and only the app's capability-flagged tools
call it. It closes the loop in both directions — firmware reads the solved circuit
(ADC inputs, I2C devices) and drives it back (`mcu_pin`s, PWM outputs, device state).

## What it does

1. `arduino-cli` (external tool) compiles a sketch for `arduino:avr:uno` to Intel HEX.
2. `harness/run.mjs` loads that HEX into **avr8js** (MIT) — a pure-JS ATmega328P —
   wires up timer0/1/2, ports B/C/D, USART0, TWI, SPI and ADC, runs one instruction
   at a time and prints digital pin transitions (with a per-pin PWM duty summary),
   captured `Serial` output and I2C/SPI bus traces as JSON with emulated timestamps.
   By default the buses have **no device** (I2C is ACKed and recorded, SPI MISO
   returns 0x00); with `CF_DEVICES` a device is served on the bus, including SPI
   parts that answer firmware reads on MISO (the MCP3008).

avr8js is **MIT**, so it can be shipped alongside the MIT app; `arduino-cli` and
Node are treated as optional external tools, never bundled. See
`../docs/plan/m7_firmware_backend.md` for the full rationale and gate criteria.

## Run it

```sh
# 1. compile (external tools; not required by the Godot test suite)
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/blink firmware/sketches/blink
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/serial_hello firmware/sketches/serial_hello
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/i2c_write firmware/sketches/i2c_write
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/expander firmware/sketches/expander
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/expander_read firmware/sketches/expander_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/analog_read firmware/sketches/analog_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/pwm_out firmware/sketches/pwm_out
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/eeprom_roundtrip firmware/sketches/eeprom_roundtrip
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/eeprom_read firmware/sketches/eeprom_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/pcf8591_read firmware/sketches/pcf8591_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/pcf8591_dac firmware/sketches/pcf8591_dac
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/lcd_hello firmware/sketches/lcd_hello
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/ultrasonic firmware/sketches/ultrasonic
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/mpu6050_read firmware/sketches/mpu6050_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/oled_fill firmware/sketches/oled_fill
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/encoder_read firmware/sketches/encoder_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/dht_read firmware/sketches/dht_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/env_logger firmware/sketches/env_logger
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/sht31_read firmware/sketches/sht31_read
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/servo_sweep firmware/sketches/servo_sweep
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/stepper_sweep firmware/sketches/stepper_sweep
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/stepper_4phase firmware/sketches/stepper_4phase
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/motion_demo firmware/sketches/motion_demo
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/oled_spi firmware/sketches/oled_spi
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/tft_fill firmware/sketches/tft_fill
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/spi_adc firmware/sketches/spi_adc
arduino-cli compile --fqbn arduino:avr:uno \
  --output-dir firmware/build/adxl345_read firmware/sketches/adxl345_read

# 2. execute + inspect
cd firmware/harness
npm install
node run.mjs ../build/blink/blink.ino.hex 2500 > blink.json
node run.mjs ../build/serial_hello/serial_hello.ino.hex 2200 > serial.json
node run.mjs ../build/i2c_write/i2c_write.ino.hex 2200 > i2c.json

# 3. verify (exit 0/1)
node verify.mjs ../build/blink/blink.ino.hex
node verify_serial.mjs ../build/serial_hello/serial_hello.ino.hex
node verify_i2c.mjs ../build/i2c_write/i2c_write.ino.hex
node verify_expander_read.mjs ../build/expander_read/expander_read.ino.hex
node verify_analog.mjs ../build/analog_read/analog_read.ino.hex
node verify_pwm.mjs ../build/pwm_out/pwm_out.ino.hex
node verify_eeprom.mjs ../build/eeprom_roundtrip/eeprom_roundtrip.ino.hex
node verify_pcf8591.mjs ../build/pcf8591_read/pcf8591_read.ino.hex
node verify_lcd.mjs ../build/lcd_hello/lcd_hello.ino.hex
node verify_ultrasonic.mjs ../build/ultrasonic/ultrasonic.ino.hex
node verify_mpu6050.mjs ../build/mpu6050_read/mpu6050_read.ino.hex
node verify_oled.mjs ../build/oled_fill/oled_fill.ino.hex
node verify_encoder.mjs ../build/encoder_read/encoder_read.ino.hex
node verify_dht.mjs ../build/dht_read/dht_read.ino.hex
node verify_env_logger.mjs ../build/env_logger/env_logger.ino.hex
node verify_sht31.mjs ../build/sht31_read/sht31_read.ino.hex
node verify_servo.mjs ../build/servo_sweep/servo_sweep.ino.hex
node verify_stepper.mjs ../build/stepper_sweep/stepper_sweep.ino.hex
node verify_4phase.mjs ../build/stepper_4phase/stepper_4phase.ino.hex
node verify_motion.mjs ../build/motion_demo/motion_demo.ino.hex
node verify_oled_spi.mjs ../build/oled_spi/oled_spi.ino.hex
node verify_tft.mjs ../build/tft_fill/tft_fill.ino.hex
node verify_spi_adc.mjs ../build/spi_adc/spi_adc.ino.hex
node verify_adxl345.mjs ../build/adxl345_read/adxl345_read.ino.hex
```

`verify.mjs` asserts D13 (PB5) is a clean ~500 ms square wave (edge gaps
500.009/500.008/500.012/500.011 ms). `verify_serial.mjs` asserts the sketch's
`Serial.print` output is captured (`CircuitForge tick 0…4`, 105 bytes).
`verify_i2c.mjs` asserts a Wire write to `0x27` with bytes `0x00,0x41` is recorded
as an I2C bus trace. `sketches/expander` writes the port byte `0x55` to a PCF8574
at `0x27`; the app's `apply_firmware_device` tool consumes that byte to set the
device's `state` (P0..P7 = 1,0,1,0,1,0,1,0). `verify_ultrasonic.mjs` asserts a
harness-driven HC-SR04 ECHO pulse makes `pulseIn()` measure ~1740 µs → ~30 cm.
`verify_mpu6050.mjs` asserts the served MPU-6050 register file decodes to the exact
accel/temp/gyro counts. `verify_oled.mjs` asserts the decoded SSD1306 frame (4096 lit
pixels and the exact per-page hex), and `verify_oled_spi.mjs` asserts the same frame for the
SPI panel plus a negative control with no DC line, so the check fails if DC is not really
what tags command vs data. `verify_tft.mjs` does the same for the ILI9341 colour TFT: it
recomputes the FNV-1a hash from the expected red/blue pattern (so all 76800 pixels count),
checks the byte accounting and probe geometry, and reruns the bytes with no DC line.
`verify_spi_adc.mjs` is the *read* direction on that same peripheral: the MCP3008 answers
on MISO, and the verifier asserts the 10-bit codes the sketch printed are the ones the spec
implies (3.3 V → 675, 1.25 V → 256, 0 V → 0, 5 V → 1023 over a 5 V reference known as
`vref`), the per-read volts and the raw trace, plus a full-scale control and a no-device
control where the bus idles at 0x00 so the same firmware must read zeros.
`verify_encoder.mjs` asserts the incremental encoder
decodes to exactly the emitted steps, forwards and backwards. `verify_dht.mjs` asserts a
hand-written one-wire driver decodes DHT22 (including a negative temperature) and DHT11
frames exactly, and that a missing sensor times out. `verify_env_logger.mjs` is the
capstone: one sketch reads a DHT22 and reports through both a 16x2 I2C LCD and serial,
and the verifier asserts the LCD text and the serial report agree (and that a missing
sensor is reported on the display). That sketch is also the bundled example
`data/examples/15_firmware_env_logger.cf3d`. `verify_sht31.mjs` asserts the SHT31's
16-bit words and both CRC-8s (including the datasheet's `0xBE 0xEF -> 0x92` vector) and
that a corrupted checksum *and* a wrong I2C address are both caught by the driver.
`verify_servo.mjs` is the *output* direction: a hand-written 50 Hz software pulse train
(no `Servo` library is bundled) sweeps 0..180 degrees and settles at 90, and the verifier
recovers every angle from the recorded pin transitions to within 3 degrees.
`verify_stepper.mjs` is the same idea through a driver: a hand-written pulse generator
moves +200, -100, +50 steps with DIR set for each phase, and the verifier recovers exactly
250 forward / 100 reverse / net +150 steps and checks the STEP high pulse is wider than the
1 us an A4988 needs. `verify_4phase.mjs` drives a 28BYJ-48 through a ULN2003 the way real
sketches do - a pre-energized half-step burst, then wave-mode bursts each way with the coils
released in between - and recovers net +32 half steps with the two coil-off gaps counted as
skipped, which is the same measurement whatever mix of wave/full/half-step driving is used.
`verify_motion.mjs` is the capstone for the *actuators*: one sketch (`motion_demo`)
drives a servo and a STEP/DIR stepper at the same time, and the verifier recovers the
servo's 0..180 sweep (settling at 90) from the pulse widths *and* the stepper's net +150
steps (200 forward, 50 back) from the STEP edges in the same transition record, so the two
output decoders are checked together. That sketch is also the bundled example
`data/examples/16_firmware_motion.cf3d`.

## Devices on the bus (closed loop)

`run.mjs` reads an optional `CF_DEVICES` environment variable — a JSON array of
device specs — and serves the matching I2C addresses, so firmware can *read* a
device (device → firmware feedback), not just trace writes:

```sh
# PCF8574 at 0x27 with P0..P3 externally held low -> reads return 0xF0
CF_DEVICES='[{"kind":"pcf8574","address":39,"state":255,"inputs":15}]' \
  node run.mjs ../build/expander_read/expander_read.ino.hex 2200

# 24C02 EEPROM at 0x50: store a byte then read it back (prints "eeprom 165")
CF_DEVICES='[{"kind":"eeprom","address":80,"size":256,"init":[]}]' \
  node run.mjs ../build/eeprom_roundtrip/eeprom_roundtrip.ino.hex 600

# PCF8591 ADC at 0x48 with AIN0 = 2.5 V over a 5 V reference -> reads code 128
CF_DEVICES='[{"kind":"pcf8591","address":72,"ain":[2.5,0,0,0],"vref":5}]' \
  node run.mjs ../build/pcf8591_read/pcf8591_read.ino.hex 400

# 16x2 HD44780 LCD behind a PCF8574 backpack at 0x27 -> decoded text
CF_DEVICES='[{"kind":"lcd1602","address":39,"cols":16,"rows":2}]' \
  node run.mjs ../build/lcd_hello/lcd_hello.ino.hex 800

# HC-SR04 at a 30 cm target on TRIG D9 / ECHO D10 -> pulseIn reads ~1740 us
CF_DEVICES='[{"kind":"hc_sr04","trig":9,"echo":10,"distance_cm":30}]' \
  node run.mjs ../build/ultrasonic/ultrasonic.ino.hex 600

# MPU-6050 at 0x68 with az = 1 g and 26.53 C -> WHO_AM_I 0x68, az 16384, temp 2653
CF_DEVICES='[{"kind":"mpu6050","address":104,"az":1,"temp_c":26.53}]' \
  node run.mjs ../build/mpu6050_read/mpu6050_read.ino.hex 400

# ADXL345 at 0x53 with 0.5/-0.25/1 g -> DEVID 0xE5, counts at the scale the sketch writes
CF_DEVICES='[{"kind":"adxl345","address":83,"ax":0.5,"ay":-0.25,"az":1}]' \
  node run.mjs ../build/adxl345_read/adxl345_read.ino.hex 400

# SSD1306 OLED at 0x3C -> the decoded 128x64 frame (top half lit)
CF_DEVICES='[{"kind":"ssd1306","address":60,"cols":128,"pages":8}]' \
  node run.mjs ../build/oled_fill/oled_fill.ino.hex 600

# The same panel on the SPI peripheral, DC = D9, CS = D10 -> the frame (left half lit)
CF_DEVICES='[{"kind":"ssd1306_spi","dc":9,"cs":10,"cols":128,"pages":8}]' \
  node run.mjs ../build/oled_spi/oled_spi.ino.hex 700

# Rotary encoder on D2 (A) / D3 (B), 50 steps clockwise -> the sketch decodes 50
CF_DEVICES='[{"kind":"encoder","a":2,"b":3,"counts":50,"direction":1}]' \
  node run.mjs ../build/encoder_read/encoder_read.ino.hex 400

# DHT22 on D2 at 23 C / 48 % -> the one-wire frame reads back exactly
CF_DEVICES='[{"kind":"dht","pin":2,"model":"dht22","temp_c":23,"humidity":48}]' \
  node run.mjs ../build/dht_read/dht_read.ino.hex 200

# SHT31 at 0x44 -> the 16-bit words and both CRC-8s read back exactly
CF_DEVICES='[{"kind":"sht31","address":68,"temp_c":23,"humidity":48}]' \
  node run.mjs ../build/sht31_read/sht31_read.ino.hex 300

# Capstone: a DHT22 and a 16x2 I2C LCD in one sketch -> LCD text and serial agree
CF_DEVICES='[{"kind":"dht","pin":2,"model":"dht22","temp_c":23,"humidity":48},{"kind":"lcd1602","address":39,"cols":16,"rows":2}]' \
  node run.mjs ../build/env_logger/env_logger.ino.hex 300

# MCP3008 on the SPI peripheral (CS = D10): CH0..CH3 answer reads with 10-bit codes
CF_DEVICES='[{"kind":"mcp3008","cs":10,"vref":5,"ain":[3.3,1.25,0,5]}]' \
  node run.mjs ../build/spi_adc/spi_adc.ino.hex 900
```

Supported `kind`s: `pcf8574` (`state`, `inputs`), `eeprom` (`address`, `size`,
`init`), `pcf8591` (`address`, `ain`, `vref`), `lcd1602` (`address`, `cols`, `rows`),
`mpu6050` (`address`, `ax`..`gz`, `temp_c`), `adxl345` (`address`, `ax`, `ay`, `az`),
`ssd1306` (`address`, `cols`, `pages`) and
`sht31` (`address`, `temp_c`, `humidity`, `corrupt_crc`)
are served on the I2C bus; the EEPROM summary also returns the memory image (`mem`), the
LCD summary the decoded `lines`, the IMU summary the decoded
`accel_raw`/`gyro_raw`/`temp_c`, the OLED summary the decoded `pages_hex` and the SHT31
summary the raw 16-bit words plus both checksums (`temp_raw`/`humidity_raw`, `crc_ok`). The
ADXL345 is a register file too (`adxl345_read`), with its own map: DEVID `0xE5`, the data
registers (0x32..0x37) little-endian, and — unlike the IMU's fixed full-scale — the counts
come from the scale the firmware selected, so `DATA_FORMAT` FULL_RES gives 3.9 mg/LSB at
every range and 10-bit mode gives `256 >> range` LSB/g; the summary reports the decoded
`data_format`/`full_res`/`range_g`/`lsb_per_g` alongside `accel_raw`/`accel_g`.
Other devices live on the SPI peripheral instead of the I2C bus. `ssd1306_spi` (`dc`, `cs`,
`cols`, `pages`) decodes the MOSI byte stream, using the DC line to tell commands from data
and CS to mark the selected transaction, and returns the same frame fields as the I2C panel.
`ili9341` (`dc`, `cs`, `width`, `height`) is the same idea with an RGB565 engine: DC low is a
command and DC high its parameters and the `0x2C` pixel stream, and because a 240x320 frame
is 153600 bytes it returns a *summary* (the bytes/data counts, `pixels_written`, `colors`, an
FNV-1a `frame_hash` over the whole buffer, five `probes`, the address `window`, `madctl`,
`colmod`, `display_on`, `sleeping`) instead of the buffer. Since a TFT frame makes the raw
trace 150k+ bytes, `spi_bytes` is capped at 4096 (`CF_SPI_LIMIT`) with the true length in
`spi_byte_count`. `mcp3008` (`cs`, `vref`, `ain`) is the first SPI device that firmware can
*read*: it answers on MISO (each selected device returns the byte MISO carries; the two panels
never do), and the CS high → low edge, not the byte values, frames a conversion. It serves the
datasheet's three transfers (`0x01`, then `0x80 | channel << 4`, then a don't-care) and clocks
out a leading zero bit plus the 10-bit code, so a driver's `((hi & 0x03) << 8) | lo` gets the
value; every conversion is recorded (`reads[]` with channel/code/volts, `conversions`) and a
differential request is answered with the channel's single-ended code and counted.
Three *pin* devices drive MCU inputs instead, reported under `pin_devices`: `hc_sr04`
(`trig`, `echo`, `distance_cm`) watches TRIG and pulses ECHO; `encoder` (`a`, `b`,
`counts`, `direction`, `step_us`) steps a quadrature A/B pair through a Gray cycle; and
`dht` (`pin`, `model`, `temp_c`, `humidity`) answers a one-wire start signal with a
datasheet-timed bit train. The app does this automatically:
`run_firmware(..., attach_devices=true)` builds the specs from the circuit's `pcf8574`,
`eeprom_i2c`, `pcf8591`, `i2c_lcd1602`, `oled_ssd1306`, `mpu6050`, `adxl345`, `sht31` and `mcp3008`
components (a `pcf8591`'s `ain` values come from the solved node voltages, and so do the
MCP3008's eight channels, scaled to codes by its `vref` parameter), and `pin_map` resolves an
`hcsr04`'s TRIG/ECHO, a `rotary_encoder`'s A/B, a `dht11`/`dht22`'s DATA or an
`oled_ssd1306_spi`'s DC/CS from the
netlist (the SPI panel has no address, so those two lines are how the app knows which pin
tags a byte and which selects the panel); the `tft_ili9341` TFT resolves DC/CS the same way,
and the `mcp3008` resolves its CS the same way (without it a conversion cannot be framed, so
the part is skipped).
A mapped `servo_sg90`/`servo_mg996r` needs no harness device at all — it is an
*output*, so the app decodes the commanded angle from the pulse widths the sketch drove
(`run_firmware`'s `servos`, or `apply_firmware_servo` to write it onto the part's `angle`;
either tool takes the servo's own id or, like `run_firmware`, the component wired to its
PWM net — usually the circuit's virtual `mcu_pin`).
A STEP/DIR stepper is the same: `pin_map` maps the firmware pins driving the driver's
STEP/DIR nets to the components on those nets, and the net `steps` + shaft `angle` come
back in `steppers` (`apply_firmware_stepper` writes them onto the motor). A four-phase
driver (`uln2003_driver`) works through the same tool: map the IN1..IN4 pins and the phase
sequence is measured instead of pulses (one unit is a half step).

## Analog inputs (circuit → firmware)

`run.mjs` also reads `CF_ADC`, a JSON map of ADC channel → volts, and feeds it to
the AVR's ADC so `analogRead()` reads a real voltage:

```sh
# analogRead(A0) reads 2.5 V -> code 512
CF_ADC='{"0":2.5}' node run.mjs ../build/analog_read/analog_read.ino.hex 1600
```

The app does this automatically: `run_firmware(..., analog_map={"A0": "AIN1"})`
solves the circuit and feeds each `mcu_analog_in` node's voltage to the channel.

## Analog outputs (firmware → circuit)

The run output also carries a `pwm` summary: for every digital pin that toggled
rapidly enough (≥ 4 edges) it reports the average `duty` cycle, approximate
`freq_hz` and the edge count.

```sh
# analogWrite(9,128) -> ~50.2% duty at ~490 Hz
node run.mjs ../build/pwm_out/pwm_out.ino.hex 2000
```

The app consumes it: `apply_firmware_pwm(hex_path, pin_map={"9": "PWM1"})` sets the
matching `mcu_pwm_out` component's `voltage` to `duty * vlogic` (the DC average), so
firmware's `analogWrite()` drives the circuit. `verify_pwm.mjs` asserts the duty for
`analogWrite(9,128)`.

These steps are **not** part of `tests/run_tests.gd`: the Godot suite must stay
runnable with only Godot installed. They are run manually / in a separate job.
