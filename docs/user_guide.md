# CircuitForge 3D — User Guide

## 1. Overview

CircuitForge 3D is a virtual electronics workbench. You place components on a
3D breadboard, connect them through the holes (and explicit jumper wires), then
run a real circuit simulation to see voltages, currents and waveforms.

## 2. The window

```
+--------------------------------------------------------------+
| Toolbar (wraps to 2 rows):                                   |
|   New Open Save SaveAs [Examples]                            |
|   Wire Rotate Dup Delete                                      |
|   Run DC Run Transient Stop                                   |
|   Undo Redo Scope Meter Lighting Help                         |
+-----------+----------------------------------+---------------+
| Component |            3D WORKBENCH          |  Properties   |
|  Library  |      (breadboard + parts)        |  (selected)   |
|           |                                  |               |
+-----------+----------------------------------+---------------+
| Status bar | Measurements / Diagnostics                      |
+--------------------------------------------------------------+
```

- **Component Library** (left): browse by category or type to search.
- **3D workbench** (centre): the breadboard and your circuit.
- **Properties** (right): edit the selected component's value.
- **Measurements / Diagnostics** (bottom): solved node voltages, branch
  currents, solver iterations and warnings.
- **Oscilloscope** (floating window): transient waveforms.
- **Meter** (floating window): a single net-voltage / branch-current probe.

## 3. Placing components

1. Click a component in the **Component Library**. It becomes "armed".
2. Click a breadboard hole. The component is placed with its first pin on that
   hole and its remaining pins on adjacent holes.
3. Press `Esc` to disarm placement.

Each component gets an automatic id: `R1`, `C1`, `V1`, `D1` (LEDs/diodes),
`DZ1` (zener), `SW1`, `RV1`, `GND1`, etc.

## 4. Wiring

- Click **Wire** to toggle wire-drawing mode (button stays highlighted).
- Click two holes to draw a jumper wire between them.
- Click **Wire** again (or press `W`) to leave the mode.

Holes are connected electrically as follows:

- The five holes in each half-row of the terminal strip are one net.
- The centre channel separates the two halves (they are isolated).
- The four power rails are continuous down the whole board unless the project
  enables **split rail** mode, which breaks each rail in the middle.

A **wire** simply unifies the nets of its two endpoints. Placing two component
pins on the same net connects them.

## 5. Ground and reference

The solver needs a reference node. Place a **Ground** component on the net you
want to define as 0 V; that net is renamed `0` and becomes the reference.

## 6. Editing values

Select any component (click it on the board). The **Properties** panel shows
its editable parameters:

| Component        | Parameters                                   |
|------------------|----------------------------------------------|
| Resistor         | Resistance (Ohm)                             |
| Capacitor        | Capacitance (F)                              |
| Inductor         | Inductance (H)                               |
| Potentiometer    | Total resistance, wiper position (0–1)       |
| Switch           | Closed (true/false)                          |
| DC Voltage Source| Voltage (V)                                  |
| DC Current Source| Current (A)                                  |
| Diode / LED      | Saturation current, ideality factor          |
| Zener Diode      | + breakdown voltage                          |
| Logic gates      | Supply voltage, input threshold, output R    |

Values accept engineering notation such as `4.7k`, `100n`, `10m`, `2M`
(see `docs/architecture/architecture.md` for the units parser).

## 7. Simulation

- **Run DC** — solves the DC operating point (nonlinear parts are linearised by
  Newton–Raphson). Results appear in Measurements and on the component labels.
- **Run Transient** — time-domain analysis using backward-Euler companion
  models. Defaults: `t_stop = 0.5 s`, `dt = 1 ms` (per project).
- **Stop** — clears results.

Waveform sources: a voltage source's `waveform` parameter may be `sine`,
`square`, `pulse`, `triangle` or omitted (DC).

### 7.1 Multimeter

Click **Meter** to open a small probe window. Enter a net name or component id
and press Enter; it shows the current voltage (or branch current) at that probe,
updating after each solve. Use it for a quick single reading without opening the
scope.

### 7.2 Oscilloscope

Enter one to four probes (comma-separated net names and/or component ids, e.g.
`TP1, a10, C1`). The scope auto-scales vertically to the selected traces.

### 7.3 Logic gates

The **Logic** category provides AND, OR, NOT, NAND, NOR, XOR and buffer gates.
Each gate has two inputs and one output by default (NOT and buffer use the first
input). An input is logic-high when its net voltage exceeds the gate's threshold
(default 2.5 V, half of the 5 V supply); the output is driven to the supply
voltage or 0 V through the gate's output resistance, so it can drive LEDs and
resistors like any other source. Gates are combinational and are solved by the
same Newton–Raphson engine as the analog parts.

### 7.4 Lighting

Click **Lighting** to cycle the workbench lighting through **studio**, **bright**
and **night**. This only changes the 3D scene appearance; it never affects the
simulation.

## 8. Files

- Projects are saved as **`.cf3d`** — a versioned, validated JSON document.
- **New / Open / Save** are in the toolbar. Opening a corrupted or older file
  fails safely or migrates it.
- **Undo / Redo** cover component and wire edits.

### Bundled examples

Use the **Examples** dropdown in the toolbar, or the command line:

```
godot --path <project> -- res://data/examples/04_voltage_divider.cf3d
```

| File                          | What it shows                          | Expected result                          |
|-------------------------------|----------------------------------------|------------------------------------------|
| 01_led_resistor               | LED current limiting                   | ≈1.79 V across LED, ≈9.7 mA              |
| 02_series_resistors           | Series resistors                       | 4.5 V midpoint, 4.5 mA                   |
| 03_parallel_resistors         | Parallel resistors                     | 12 mA per branch, 24 mA total            |
| 04_voltage_divider            | Equal divider                          | 5 V midpoint                             |
| 05_rc_charging                | RC charge (τ = 0.1 s)                  | ≈3.16 V at 0.1 s, ≈4.97 V at 0.5 s       |
| 06_rc_discharging             | RC discharge from 5 V initial          | exponential decay toward 0 V             |
| 07_rl_response                | RL step (τ = 0.1 ms)                   | current rises to ≈50 mA                  |
| 08_half_wave_rectifier        | Sine + diode                          | positive half-cycles only                |
| 09_led_switch                 | Switch-controlled LED                  | LED on when switch closed                |
| 10_zener_regulator            | Zener clamp                            | output clamped near breakdown            |
| 11_logic_and                  | AND gate driving an LED                | LED on (both inputs high); out ≈5 V      |
| 12_seven_segment              | 7-segment digit via virtual pins       | segments B and C lit; ≈12 mA each        |
| 13_ntc_thermistor             | NTC + 10k divider                      | 2.5 V at 25 °C; ~3.6 V at 50 °C          |
| 14_limit_switch_motor         | Limit switch switching a DC motor      | ≈1 A when actuated; ~0 when released     |
| 15_firmware_env_logger        | DHT22 + I2C LCD, driven by firmware    | LCD and serial show "T=23.0C H=48.0%"    |
| 16_firmware_motion            | Servo + STEP/DIR stepper, driven by firmware | servo `angle_deg` 90.7; stepper `steps` 150 (angle 270°) |

Example 15 is a *firmware* example: nothing about it solves electrically beyond the
supply rails, because the sensor and the display are served by the optional firmware
backend. Compile `firmware/sketches/env_logger` for `arduino:avr:uno` and run
`run_firmware(hex_path, attach_devices=true, pin_map={"2": "P1"})`; the harness answers
the DHT22 on the `P1` net and decodes the LCD's I2C stream, so the LCD text and the
serial report can both be checked. See `firmware/README.md`. Parts that *act* rather than
sense work the same way: with a `servo_sg90` wired to a virtual pin, map the firmware pin
to that pin's net — `run_firmware(hex_path, pin_map={"9": "P1"})` — and the angle the
sketch's pulse train commands comes back under `servos`, with `apply_firmware_servo`
writing it onto the part's `angle`. A stepper is read the same way through its driver: map
the firmware pins wired to the driver's STEP/DIR nets (or IN1..IN4 for a four-phase
ULN2003 board) and the move comes back under `steppers` (net `steps` and the wrapping shaft
`angle`), with `apply_firmware_stepper` writing it onto the motor. Example 16 puts both of
those in one project (and one firmware run): compile `firmware/sketches/motion_demo` and
use `pin_map={"9": "P1", "3": "P2", "2": "P3"}`. Displays work the same way on both buses:
an I2C `oled_ssd1306` needs only `attach_devices=true`, while an `oled_ssd1306_spi` also
needs its DC and CS lines wired to virtual pins and mapped (the panel has no address, so
those two lines are how the run knows which byte is a command and which panel is selected —
see `firmware/sketches/oled_spi`). The colour `tft_ili9341` works the same way as the SPI
OLED (`firmware/sketches/tft_fill`); its frame is reported as a summary (lit-pixel count,
colours, a frame hash and probe pixels) rather than the whole 240x320 buffer.

Add `--screenshot=<path>` to the command line to save a PNG of the window once
the circuit has settled (useful for automated visual evidence).

## 9. Keyboard & mouse

| Input        | Action                         |
|--------------|--------------------------------|
| Left-click   | place / select                 |
| Right-drag   | orbit camera                   |
| Middle-drag  | pan camera                     |
| Wheel        | zoom                           |
| `W`          | toggle wire mode               |
| `R`          | rotate selected component      |
| `Delete`     | delete selected component      |
| `Space`      | run DC                         |
| `F1`         | help                           |
| `Esc`        | cancel placement / wire        |
| `Ctrl+N`     | new project                    |
| `Ctrl+O`     | open project                   |
| `Ctrl+S`     | save project                   |
| `Ctrl+Shift+S` | save project as              |
| `Ctrl+Z` / `Ctrl+Y` | undo / redo             |

## 10. Troubleshooting

- **"missing reference node"** — add a Ground component.
- **"floating node"** — a net has no DC path to the rest of the circuit; add a
  component or wire that connects it.
- **Oscilloscope shows nothing** — run a transient first; DC runs produce no
  time-domain samples.
- **A part has no effect** — make sure both of its pins are on nets that are
  actually connected (check the hole groups and rails).
