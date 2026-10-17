# CircuitForge 3D — Test Report (0.1.0)

## Environment

| Item        | Value                                                         |
|-------------|---------------------------------------------------------------|
| Host        | Windows 10 (10.0.26300), x86-64                              |
| CPU / RAM   | Intel Core i7-9750H / 15.9 GB                                |
| GPU         | NVIDIA GTX 1660 Ti                                           |
| Engine      | Godot 4.7.2.stable.official (`ed1daf0bf`)                    |
| Date        | 2026-10-16                                                    |

## How to reproduce

```powershell
& "<godot_console.exe>" --headless --path <project> `
    --script res://tests/run_tests.gd
```

Exit code `0` = success. The runner records each file and fails the file if it
does not reach `t.done()` (guards against silently skipped tests).

## Result

```
RESULT: 663 / 663 passed
STATUS: ALL TESTS PASSED
```

## Coverage by suite

| Suite / section                                            | Area                |
|------------------------------------------------------------|---------------------|
| LinAlg — linear solve                                      | numeric core        |
| Schema — normalise, validate, status vocabulary            | catalog schema      |
| Catalog — load, validate all 241, search, facets, status   | catalog             |
| DC 1–7 — Ohm, divider, parallel, KCL, KVL, sensitivity     | DC solver           |
| Transient — RC charging, RL step, sine source              | transient solver    |
| Nonlinear — LED forward/reverse, silicon diode             | Newton–Raphson      |
| Logic — full truth tables for AND/OR/NOT/NAND/NOR/XOR/BUF  | logic gates         |
| Invalid 8a–8g — no ref, floating, conflict, empty, …       | error handling      |
| Breadboard — groups, rails, split, wires, move, rotate     | connectivity graph  |
| Placement — default hole sets do not short a part          | breadboard layout   |
| Factory — package shapes + terminal alignment              | 3D visuals          |
| Boards — discovery, pin-map consistency, groups, provenance | board metadata      |
| Netlist — gpio driver, aliases, sensors/motors, PCF8574 port, analog-input probe, analog-output source, status↔solver honesty | simulation mapping  |
| Firmware — pin-key normalisation, sampling, serial/I2C decode, device + analog-input reads, PWM duty, capability honesty | firmware backend    |
| Persistence — validate, save/reload, corruption, migration | file format         |
| Units — engineering notation parse/format                  | input handling      |
| Camera — orbit / pan / zoom                                | view control        |
| End-to-end — build, solve, edit, save, reload              | integration         |
| Examples — load/validate/simulate all 11, documented values| integration         |

## Numerical validation (physical sanity)

| Case                                  | Expected              | Measured (`0.1.0`)    |
|---------------------------------------|-----------------------|-----------------------|
| 5 V, 1 kΩ (Ohm's law)                 | 5 mA                  | 5 mA                  |
| 10 V, two 1 kΩ divider               | 5 V midpoint          | 5 V midpoint          |
| 12 V, two 1 kΩ parallel              | 24 mA total           | 24 mA total           |
| LED example (5 V, 330 Ω, red LED)     | Vf≈1.8 V, I≈9–10 mA   | 1.788 V, 9.733 mA     |
| RC charge (1 kΩ, 100 µF, 5 V) at 0.5 s| 4.966 V               | 4.9658 V              |
| Silicon diode forward drop            | ≈0.6–0.7 V            | within range (test)   |
| DC motor (5 V, 10 Ω, 2 V back-EMF)    | 0.3 A                 | 0.3 A                 |

## Interactive (GUI) verification

Performed manually on Windows with screenshot evidence:

1. **Launch & render** — the 3D breadboard, holes, centre channel, coloured
   rails and all panels render correctly.
2. **Load example** — `res://data/examples/01_led_resistor.cf3d` loaded from the
   command line and via the **Examples** dropdown.
3. **DC solve** — the example auto-ran: *"DC simulation complete (12
   iteration(s))"*; component labels showed `V1=5 V`, `R1` 330 Ω / 3.212 V /
   9.733 mA, `D1` 1.788 V / 9.733 mA (matches the automated result).
4. **Transient + oscilloscope** — `05_rc_charging.cf3d` ran *"Transient
   complete: 501 samples over 0.5 s"*; the scope drew the classic RC charging
   curve with auto-scaled axes; Measurements reported `net TP1 = 5 V`,
   `net a10 = 4.9658 V`.
5. **Logic gates** — `11_logic_and.cf3d` loaded from the command line; the
   window title showed `CircuitForge 3D - Logic AND Gate (DEBUG)`; the **Logic**
   category appeared in the component library; the AND output `a15` read
   `4.9903 V` and the LED lit.
6. **Multimeter** — the **Meter** window read `a15 → 4.9903 V`, matching the
   solved value.
7. **Lighting toggle** — the **Lighting** control cycled studio → bright → night
   and the workbench relit accordingly.

## Packaging verification

| Artifact                                   | Produced | Verified |
|--------------------------------------------|----------|----------|
| `build/windows/CircuitForge3D.exe` (+pck)  | yes      | boots `--headless --quit-after`, exit 0, incl. CLI example load |
| `build/linux/CircuitForge3D.x86_64` (+pck) | yes      | ELF64 little-endian `e_machine=0x3E` (x86-64), `ET_EXEC`; **not runtime-executed** (host WSL2 unavailable) |

## MCP integration (protocol acceptance tests)

Run with the official MCP Python SDK client (`mcp==2.3.0`) against the real
adapter process (`python -m circuitforge_mcp`), which in turn drives the real
headless Godot engine:

```powershell
mcp_server\.venv\Scripts\python mcp_server\tests\test_mcp_integration.py
```

```
RESULTS: 18 / 18 passed
```

| Test | Checks | Result |
|------|--------|--------|
| A. Server initialization | name `circuitforge-3d`, 41 tools present, valid input schemas | pass |
| A2. Resources & prompts | 7 resources, 8 prompts discovered | pass |
| B. Read-only discovery | simulator info, capabilities, ≥10 catalog entries, summary | pass |
| B2. Catalog discovery | 241 entries, status facets/filters, I2C filter, 0 errors | pass |
| B3. Board pinout | Uno R3 29 pins, groups/counts, provenance references | pass |
| B4. Virtual pin control | mcu_pin high/low/high-Z via set_pin_levels + get_pin_states | pass |
| B5. Firmware backend | optional/honest capabilities; missing-HEX is a clean error | pass |
| B6. Firmware device | create `pcf8574`; missing-HEX `apply_firmware_device` is a clean error | pass |
| B7. Firmware analog inputs | `mcu_analog_in` + missing-HEX `run_firmware(analog_map)` is a clean error | pass |
| B8. Firmware PWM output | `mcu_pwm_out` + missing-HEX `apply_firmware_pwm` is a clean error | pass |
| C. Create & inspect | build V/R/GND, 3 wires, node ids resolved | pass |
| D. Simulate & measure | node `5.0000 V`, `I(R1)=5.0000 mA` | pass |
| E. Parameter change | `1 kΩ→2 kΩ` gives `2.5000 mA` | pass |
| F. Invalid input safety | 4 error codes, project unchanged | pass |
| G. Persistence | save → new → load → re-simulate `2.5000 mA` | pass |
| H. Concurrency | stale `expected_revision` → `OPERATION_CONFLICT` | pass |
| I. Transport correctness | stdout is clean JSON-RPC, diagnostics on stderr | pass |
| J. Offline loopback | full flow under unroutable proxy; IPC loopback only | pass |

## Limitations

- Only Windows runtime was executed. The Linux build was produced and its ELF
  header validated, but it could not be run: the host's WSL2 "Virtual Machine
  Platform" feature and BIOS virtualisation are unavailable, so no Linux guest
  can start (`HCS_E_SERVICE_NOT_AVAILABLE`).
- Automated tests exercise the simulation core and the session/netlist layer
  headlessly; GUI interaction is covered by the manual checks above, not by an
  automated UI harness.
- The MCP integration (adapter + engine + protocol suite) was verified on
  Windows only. It is platform-neutral Python/GDScript and is expected to work
  on Linux but was not executed there.
