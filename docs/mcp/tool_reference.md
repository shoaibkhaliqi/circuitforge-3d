# MCP Tool, Resource and Prompt Reference

All inputs and outputs use **SI base units** (ohm, F, H, V, A, s, Hz). Prefer
plain numbers in calls (e.g. `4700`, `100e-9`); the human-facing text fields also
accept engineering notation such as `4.7k`.

Every tool returns a structured result. On success `is_error=false` and the
payload has `success: true`; on failure `is_error=true` and the payload has
`error: { code, message, suggested_action }`.

Component endpoints (`a`/`b` in `connect_terminals`) are one of:

```json
{"kind": "pin",  "component": "R1", "pin": 0}
{"kind": "hole", "id": "a1"}
```

Component ids are stable strings (`V1`, `R1`, `GND1`, …). Pin indices start at 0.

---

## A. Discovery

| Tool | Parameters | Returns |
| --- | --- | --- |
| `get_simulator_info` | — | Application name/version, API protocol, schema version, categories, instruments, limitations, current project id/name, revision, simulation state. |
| `get_capabilities` | — | Supported operations grouped by `read` / `simulate` / `edit_reversible` / `edit_destructive` / `persistence`, plus `limits`, `concurrency`, `idempotency`. |
| `get_component_catalog` | `category:str=""`, `search:str=""`, `subcategory`, `status`, `protocol`, `interface`, `manufacturer`, `mounting`, `arduino_compatible`, `simulatable_only`, `limit`, `offset` | Every component definition: type id, name, category, pins, parameters with units/ranges, status, protocols, simulation models. |
| `get_catalog_facets` | — | Catalog facets (categories, subcategories, packages, mountings, manufacturers, statuses, protocols, interfaces), total count, status labels and validation errors. |
| `get_board_pinout` | `type:str` | A development board's documented pin map (Arduino/ESP/Pico/Pi/STM32/Teensy/...): pins with name/type/header position, digital/analog/power/ground groups, counts, notes and provenance references. Descriptive only; does not imply simulation. |
| `get_pin_states` | — | State of every virtual MCU pin (`mcu_pin`): level, high/low/high-Z state, logic voltage, output resistance, the node it drives and its solved voltage when available. Stage A — ideal pins, no firmware. |
| `get_firmware_capabilities` | — | Whether optional firmware execution is available: engine (`avr8js`, MIT), boards covered (AVR/Arduino), Node path, and reasons when unavailable. Nothing GPL is bundled. |
| `run_firmware` | `hex_path:str`, `ms:int=2000` | Runs a compiled Arduino HEX (open loop, Stage B) and returns its digital pin transitions (time in ms, level), the pins it touched, and the bytes the sketch printed to Serial (USART0) as `serial` / `serial_lines`. |
| `get_solver_info` | — | Solver method (MNA), modes, nonlinear settings, device models, reference node, last convergence info. |

## B. Inspection

| Tool | Parameters | Returns |
| --- | --- | --- |
| `get_project_summary` | — | Project id/name, component/wire counts, validation status, simulation state, **revision**. |
| `list_components` | `type_filter:str=""`, `limit:int=500`, `offset:int=0` | Component list with ids, types, parameters, positions and terminals. |
| `get_component` | `component_id:str` | One component including its `node_ids`. |
| `get_connections` | — | All wires/connections, the `pin→node` map and net names. |
| `get_node_voltage` | `node:str` | Latest simulated voltage (V). |
| `get_branch_current` | `branch:str` | Latest branch current (A) for a component id, with direction. |
| `get_simulation_results` | `filter:""|"nodes"|"branches"`, `limit:int=500`, `offset:int=0` | Last result summary, node voltages, branch currents. |
| `get_circuit_text` | — | Short natural-language description of the circuit. |

## C. Editing

| Tool | Parameters | Notes |
| --- | --- | --- |
| `create_project` | `name="Untitled"`, `operation_id=""` | Replaces the current project with an empty one. |
| `add_component` | `component_type`, `name=""`, `holes:list[str]=[]`, `orientation=0.0`, `parameters={}`, `operation_id=""` | Returns the new `component_id`. Omitted holes can be wired later. |
| `update_component_parameters` | `component_id`, `parameters`, `expected_revision:null` | Validates the **whole** set first; rejects invalid values atomically. |
| `set_pin_levels` | `levels:dict[str,float]`, `simulate=false`, `expected_revision:null` | Drive virtual MCU pins (`mcu_pin`): `1` high, `0` low, `-1` high-Z; optionally re-runs the DC solve. Non-pin ids are reported as skipped. |
| `apply_firmware_pins` | `hex_path:str`, `pin_map:dict[str,str]`, `ms=2000`, `at_ms=-1`, `simulate=false`, `expected_revision:null` | Run firmware and drive mapped `mcu_pin`s from its output at one instant (`at_ms`, default end of run); open loop (no analog feedback). |
| `move_component` | `component_id`, `holes:list[str]=[]`, `orientation:null`, `expected_revision:null` | Repositions without silently breaking connectivity. |
| `remove_component` | `component_id`, `confirm=false`, `expected_revision:null`, `operation_id=""` | **Destructive.** Call with `confirm=false` to preview affected connections, then `confirm=true`. |
| `connect_terminals` | `a`, `b`, `expected_revision:null` | Returns the connection id and affected nodes. |
| `disconnect_connection` | `connection_id`, `expected_revision:null` | Removes exactly one wire. **Destructive.** |
| `clear_circuit` | `confirm=false`, `expected_revision:null` | **Destructive.** Removes every component and wire; needs `confirm=true`. |
| `validate_circuit` | — | Structured errors/warnings/info (missing ground, floating nets, conflicting sources, over-current). |
| `get_edit_preview` | `operation:str`, `arguments:dict` | Structural preview of a proposed change (no electrical prediction). |

## D. Simulation

| Tool | Parameters | Notes |
| --- | --- | --- |
| `run_dc_simulation` | — | DC operating point; returns node voltages and branch currents. |
| `run_transient_simulation` | `t_start=0.0`, `t_stop=0.5`, `dt=0.001`, `probes:list[dict]=[]` | Backward-Euler. Probes: `{"kind":"node","target":"0"}`, `{"kind":"current","target":"R1"}`. |
| `get_simulation_status` | — | `idle` / `running` / `completed` / `failed` plus last result id. |
| `stop_simulation` | — | Safe stop request. |
| `get_waveform_data` | `target:str`, `kind:"node"|"current"="node"`, `max_samples:int=2000` | Bounded, downsampled samples from the last transient. |

## E. Persistence

| Tool | Parameters | Notes |
| --- | --- | --- |
| `save_project` | `path:str=""`, `expected_revision:null` | Atomic write inside `user://projects`. Empty path = auto-name. |
| `load_project` | `path:str`, `expected_revision:null` | Load from an approved path or a bundled example. |
| `list_example_projects` | — | Bundled examples with descriptions and component counts. |
| `load_example_project` | `name:str` | Load a bundled example by name. |

## F. Diagnostics

| Tool | Parameters | Returns |
| --- | --- | --- |
| `get_diagnostics` | — | Structured diagnostics with codes, severity and suggested actions. |
| `get_solver_info` | — | (see Discovery) |

---

## Resources

Read-only, live views:

| URI | MIME | Contents |
| --- | --- | --- |
| `circuit://current/summary` | JSON | Project summary |
| `circuit://current/components` | JSON | Component list |
| `circuit://current/connections` | JSON | Connections and pin→node map |
| `circuit://current/diagnostics` | JSON | Live diagnostics |
| `circuit://catalog/components` | JSON | Component catalog |
| `circuit://documentation/units` | text | Unit and notation reference |
| `circuit://documentation/simulation-models` | text | Per-type device models |

## Prompts

Reusable workflow templates (they never replace simulation):

| Prompt | Purpose |
| --- | --- |
| `explain_circuit` | Explain the current circuit for a beginner |
| `find_disconnected_pins` | Find pins with no electrical connection |
| `diagnose_simulation_failure` | Diagnose a failing simulation |
| `calculate_expected_values` | Compute expected values analytically |
| `compare_with_analysis` | Compare simulation against analysis |
| `suggest_simpler_circuit` | Suggest a simpler/safer equivalent |
| `explain_component` | Explain one component type (arg: `component_type`) |
| `generate_test_plan` | Produce a test plan for the circuit |

---

## Error codes

| Code | Meaning |
| --- | --- |
| `UNKNOWN_COMPONENT_TYPE` | `add_component` given a type not in the catalog |
| `UNKNOWN_COMPONENT` | Component id not found |
| `UNKNOWN_NODE` | Node id not found |
| `INVALID_PARAMETER` | A parameter value is outside its allowed range/type |
| `INVALID_CONNECTION` | Endpoint invalid or connection not permitted |
| `INVALID_PROJECT` | Project state is inconsistent |
| `INVALID_PROJECT_FILE` | File is not a valid/supported `.cf3d` |
| `LIMIT_EXCEEDED` | Would exceed a hard limit (e.g. `MAX_COMPONENTS`) |
| `CONFIRMATION_REQUIRED` | A destructive tool needs `confirm=true` |
| `OPERATION_CONFLICT` | `expected_revision` does not match the current revision |
| `NO_REFERENCE` | No ground / reference node |
| `NO_SIMULATION_RESULT` | Result requested before any successful run |
| `CONFLICTING_SOURCES` | Conflicting ideal sources across a net |
| `SINGULAR_OR_NONCONVERGENT` | Matrix singular or Newton–Raphson failed |
| `SIMULATION_FAILURE` | Solver reported a failure |
| `UNCONNECTED_PIN` | (diagnostic) a pin has no connection |
| `PERMISSION_DENIED` | A path escaped the sandbox |
| `UNSUPPORTED_CAPABILITY` | Requested capability is not available |
| `ENGINE_UNAVAILABLE` | Adapter could not reach the engine |
| `ENGINE_TIMEOUT` | Engine did not become ready in time |
| `SIMULATION_TIMEOUT` | A call exceeded the timeout |

## Limits

| Limit | Value |
| --- | --- |
| `max_components` | 2000 |
| `max_wires` | 4000 |
| `max_transient_steps` | 200000 |
| `min_dt` | 1e-9 s |
| `max_returned_samples` | 4000 |
