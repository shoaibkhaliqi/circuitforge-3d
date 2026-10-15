# MCP Integration — Scope and Limitations

This page states honestly what the integration does and does not do, so an agent
(or a reviewer) does not over-trust it.

## What works

- Full read/inspect/edit/simulate/persist workflow over MCP, backed by the real
  MNA solver.
- DC and transient (backward-Euler) analysis, including nonlinear devices
  (diodes, LEDs, zeners, logic gates) via Newton–Raphson with junction limiting.
- Structured, machine-readable results and errors on every call.
- Optimistic concurrency (`expected_revision`) and idempotent operations
  (`operation_id`).
- Sandboxed persistence and bundled examples.
- Offline operation; loopback-only IPC.

## Electrical / solver limits

- **Combinational logic only.** Gates are ideal 5 V functions; there is no
  sequential logic, no clocking, no MCU, no state.
- **Fixed-step transient.** Integration is backward-Euler with the step you
  provide; there is no adaptive stepping or stiff solver.
- **Ideal sources.** No source resistance, no noise, no temperature dependence.
- **No parasitics** (no wire resistance/inductance/capacitance) and no AC
  small-signal analysis.
- Nonlinear nodes use `node_tolerance = 1e-6` and up to 200 Newton iterations;
  pathological circuits can fail to converge (`SINGULAR_OR_NONCONVERGENT`).
- Hard limits: 2000 components, 4000 wires, 200000 transient steps, min `dt`
  1e-9 s, 4000 returned samples.

## Integration / protocol limits

- **Single-engine session.** The adapter owns one engine; concurrent agents
  share that state. Revision checks protect against lost updates but not against
  interleaved intent.
- **stdio transport only.** There is no remote/HTTP MCP transport in this
  release; it is meant to run locally next to the agent.
- **Tool coverage is a curated surface**, not a 1:1 mirror of every GUI action.
  Some GUI-only affordances (board rail split UI, lighting presets) are not
  exposed as tools.
- **`get_edit_preview` is structural only** — it does not predict electrical
  results.
- **No arbitrary filesystem or code execution**, by design. If your workflow
  needs custom analysis, do it in the agent on top of the returned structured
  data.

## Platform limits

- **Windows:** verified end-to-end (adapter, engine, protocol suite, GUI).
- **Linux:** the adapter and engine are platform-neutral Python/GDScript; the
  Linux **GUI** build was produced and ELF-validated but its runtime was not
  executed on the build host (no Linux/WSL guest available). Treat Linux MCP
  runtime as **expected to work but unverified** until run on a real Linux host.
- **macOS:** not built or tested.

## Versioning

- Adapter version: `0.1.0` (`ADAPTER_VERSION`).
- Local API protocol: `circuitforge-local-api/1`.
- MCP SDK: `mcp==2.3.0` (protocol version negotiated at runtime, e.g.
  `2025-11-25`).

Breaking changes to the local API will bump the `LOCAL_API_PROTOCOL` string.

See also [`security.md`](security.md) and the project's
`docs/releases/risk_register.md`.
