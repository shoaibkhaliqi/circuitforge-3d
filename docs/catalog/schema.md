# Component catalog schema (v2)

CircuitForge 3D keeps **one** component definition format, shared by the renderer,
the connectivity layer, the solver, the persistence layer, the UI and the MCP
server. Definitions live as JSON files under `data/components/` and are loaded,
normalised and validated by `scripts/components/component_catalog.gd` against the
rules in `scripts/components/component_schema.gd`.

Nothing in the engine hardcodes a component: adding a part is adding data.

## Status vocabulary

Every definition declares an honest `simulation_status`:

| status     | meaning                                                        |
|------------|----------------------------------------------------------------|
| `full`     | A working solver model exists and is exercised by tests.       |
| `partial`  | A real but approximate electrical model exists.                |
| `visual`   | Rendered for looks only; no electrical behaviour.              |
| `external` | Behaviour belongs to a host/backend (USB, ADB, firmware, ...). |
| `planned`  | Catalogued and placeable, but not simulated yet.               |

`is_simulatable(status)` is true for `full` and `partial`. Only those parts are
offered when filtering to "Simulatable" or when checking whether an example is
runnable. Placing a non-simulatable part is always allowed — it just will not be
solved, and the UI says so.

> A 3D model is never a simulation. A part marked `planned` looks right and can
> be wired, but produces no numbers until a backend exists.

## Definition fields

Only `id`, `name`, `category` and `pins` are required; everything else is
optional and defaulted by `normalize()`.

| field                | type      | notes |
|----------------------|-----------|-------|
| `id`                 | string    | unique key (e.g. `resistor`, `arduino_uno_r3`) |
| `name`               | string    | human name |
| `category`           | string    | grouping (see facets) |
| `subcategory`        | string    | finer grouping |
| `manufacturer`       | string    | vendor, if known |
| `part_number`        | string    | datasheet part number, if known |
| `description`        | string    | one-line description |
| `keywords`           | string[]  | search aids |
| `aliases`            | string[]  | alternative names |
| `package`            | string    | e.g. `DIP-8`, `TO-220` |
| `mounting`           | string    | `tht` / `smd` / `module` / `board` / `device` / `virtual` |
| `pins`               | array     | strings or `{id,name,type,number}` objects |
| `params`             | object    | `{key: {default,unit,label[,min,max,options]}}` |
| `logic_fn`           | string    | gate function for logic parts |
| `simulation_status`  | string    | one of the vocabulary above (default `full`) |
| `simulation_models`  | string[]  | model ids (documentation) |
| `simulation_backend` | string    | required backend, if any |
| `firmware_required`  | bool      | needs user firmware to do anything |
| `recommended_voltage`| number/obj| nominal supply |
| `max_ratings`        | object    | absolute ratings (documentation) |
| `protocols`          | string[]  | e.g. `I2C`, `SPI`, `UART` |
| `interfaces`         | string[]  | e.g. `USB`, `HDMI` |
| `arduino_compatible` | bool      | works with Arduino-class boards |
| `model`              | object    | renderer hint, e.g. `{"shape":"uno"}` |
| `notes`              | string    | honest caveats / wiring warnings |
| `references`         | string[]  | datasheet / documentation links |
| `example_circuits`   | string[]  | example names that use it |
| `provenance`         | string    | default `original` |

Pin `type` is one of `passive, power, ground, input, output, bidirectional,
analog, digital, clock, open, nc`. `open` marks a port/interface that has no
solver meaning (HDMI, USB shell, microSD, ...).

## Honesty rules

- Never invent a datasheet value, a pinout, or a specification.
- Never label a third-party board as an official Arduino.
- Android phones and TV boxes are **host** devices: they have no breadboard GPIO.
  Model only their real ports and mark them `external`.
- When a real but approximate model exists (ideal source + series resistance,
  regulated output, coils as resistors) use `partial` and say what is missing in
  `notes`.

## Validation

`Schema.validate()` checks, per definition: non-empty `id`/`name`/`category`,
at least one pin, unique pin ids, known pin types, a valid `simulation_status`,
and that every parameter has a `default`. `validate_catalog()` additionally
reports duplicate ids and key/id mismatches. `tools/catalog_report.gd` and the
`get_catalog_facets` API operation both surface the current error list.
