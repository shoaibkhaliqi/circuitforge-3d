# Demo — Agent Drives the Simulator End to End

This walkthrough shows an AI agent using the CircuitForge MCP server to build,
simulate and measure a real circuit. Nothing is simulated twice: the numbers come
from the same MNA solver the GUI uses.

## Goal

Build a 5 V supply feeding a 1 kΩ resistor to ground. Measure the current.
Then change the resistor to 2 kΩ and confirm the current halves.

## Tool trace

The agent performs these calls (in order):

| Step | Tool | Arguments |
| --- | --- | --- |
| 1 | `get_simulator_info` | — |
| 2 | `get_component_catalog` | `{"search":"resistor"}` |
| 3 | `create_project` | `{"name":"Demo"}` |
| 4 | `add_component` | `{"component_type":"vsource","parameters":{"v":5.0}}` → `V1` |
| 5 | `add_component` | `{"component_type":"resistor","parameters":{"r":1000.0}}` → `R1` |
| 6 | `add_component` | `{"component_type":"ground"}` → `GND1` |
| 7 | `connect_terminals` | `V1.0 ↔ R1.0` |
| 8 | `connect_terminals` | `V1.1 ↔ GND1.0` |
| 9 | `connect_terminals` | `R1.1 ↔ GND1.0` |
| 10 | `validate_circuit` | — |
| 11 | `run_dc_simulation` | — |
| 12 | `get_node_voltage` | `{"node":"P:R1:0"}` |
| 13 | `get_branch_current` | `{"branch":"R1"}` |
| 14 | `update_component_parameters` | `{"component_id":"R1","parameters":{"r":2000.0}}` |
| 15 | `run_dc_simulation` | — |

> Node names: a net with no hole-based name (pure pin-to-pin wiring) is named
> after its smallest member, e.g. `P:R1:0`. The ground net is `"0"`.

## Expected results

- Step 11: `V(P:R1:0) = 5.0 V`, `I(R1) = 5.0 mA`.
- Step 12: `5.0`.
- Step 13: `0.005`.
- Step 15: `I(R1) = 2.5 mA` (halved).

## Sample agent prompt

> Using the `circuitforge` MCP server, build a 5 V source with a 1 kΩ resistor to
> ground, run a DC simulation, and tell me the node voltage and resistor current.
> Then change the resistor to 2 kΩ, re-simulate, and confirm the current halved.
> Use `expected_revision` when editing and show the structured numbers.

## Natural-language output (example)

> **Circuit:** a 5.0 V DC source (`V1`) in series with a 1 kΩ resistor (`R1`) to
> ground (`GND1`).
> **DC results:** node `P:R1:0` = **5.0 V**; current through `R1` = **5.0 mA**
> (direction `V1 → R1 → GND`).
> **After changing `R1` to 2 kΩ:** current = **2.5 mA** — exactly half, as
> expected for a fixed voltage across a doubled resistance (Ohm's law).

## Running it yourself

```powershell
# Terminal: run the protocol suite which performs the same flow
$env:CIRCUITFORGE_GODOT   = "D:\tools\Godot_v4.7.2-stable_win64_console.exe"
$env:CIRCUITFORGE_PROJECT = "D:\circutsimilator"
mcp_server\.venv\Scripts\python mcp_server\tests\test_mcp_integration.py
```

Test D and Test E assert exactly the 5.0 mA → 2.5 mA result.
