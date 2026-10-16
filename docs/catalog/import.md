# Adding components to the catalog

The catalog is data-driven. To add a component you add a JSON entry — you do not
touch the engine.

## 1. Pick the file

Files live in `data/components/` and are grouped by rough domain:

| file                  | contents |
|-----------------------|----------|
| `passive.json`        | resistors, capacitors, inductors, pots, switches |
| `sources.json`        | voltage/current sources, ground, batteries, solar, AC |
| `semiconductor.json`  | LEDs, diodes, transistors, regulators, optos |
| `logic.json`          | logic gates and planned sequential logic |
| `analog_ic.json`      | op-amps, comparators, timers, ADCs/DACs, references |
| `displays.json`       | LCD/OLED/TFT/e-paper/7-segment/matrix |
| `sensors.json`        | environmental, motion, distance, gas, industrial |
| `communication.json`  | radio, Bluetooth, WiFi, cellular, LoRa, RS-485, CAN, USB-UART |
| `power.json`          | regulators, DC-DC, chargers, protection, relays |
| `motors.json`         | DC/stepper/servo motors, drivers, ESCs, solenoids |
| `connectors.json`     | headers, jacks, terminals, USB/audio/RJ45/DB9, sockets |
| `instruments.json`    | multimeters, scopes, logic analyzer, bench PSU, generator |
| `boards.json`         | Arduino/ESP/Pico/Pi/STM32/Teensy development boards |
| `android.json`        | Android TV boxes, USB/OTG/debug adapters |
| `mobile_devices.json` | Android phones, tablets, USB-host accessories |

If you create a new file, add its name to `ComponentCatalog.MANIFEST` so exports
and directory-listing-less platforms still find it.

## 2. Write the entry

Minimum viable entry:

```json
{
  "id": "my_part",
  "name": "My Part",
  "category": "Passive",
  "pins": ["1", "2"],
  "params": {"r": {"default": 1000.0, "unit": "Ohm", "label": "Resistance"}}
}
```

See `docs/catalog/schema.md` for every field. Two things are mandatory:

- an honest `simulation_status` (`full`/`partial`/`visual`/`external`/`planned`)
- `notes` explaining any approximation or wiring caveat

## 3. Wire it to the model layer (only if it can be simulated)

- If the solver already handles the electrical type, reuse it: e.g. a module
  that behaves as a resistor + source can be marked `partial` and mapped in the
  factory. Purely new *electrical* behaviour must be added to
  `scripts/simulation/` and its dispatch in the solver — and only then may the
  status be `full`.
- The 3D appearance is chosen by `model.shape` in
  `scripts/components/component_factory.gd`. Unknown shapes fall back to the
  generic procedural box; add a `_body_*` builder if you want a nicer form.

## 4. Verify

```
godot --headless --path <project> --script res://tools/catalog_report.gd
godot --headless --path <project> --script res://tests/run_tests.gd
```

`catalog_report.gd` prints the status/category breakdown and any validation
errors; the unit tests assert the whole catalog validates and that core types
stay `full`.

## 5. Export

Raw JSON is not a Godot resource, so it is added to the export `include_filter`
in `export_presets.cfg` (`data/components/*.json`). Keep that in sync if you move
files.
