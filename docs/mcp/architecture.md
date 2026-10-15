# MCP Integration Architecture

## Overview

The MCP integration adds an AI-native control surface **without duplicating any
circuit logic**. Every capability is implemented once, in a shared application
service layer, and reused by three consumers:

```
        ┌───────────────────────────────────────────────┐
        │        scripts/api/app_service.gd             │
        │  (shared application service layer)           │
        │  components · wires · solver · persistence    │
        │  validation · diagnostics · revisions         │
        └───────────────▲───────────────▲───────────────┘
                        │               │
        ┌───────────────┴──┐   ┌────────┴─────────────────┐
        │ GUI (main.gd)    │   │ tests/run_tests.gd        │
        └──────────────────┘   └───────────────────────────┘
                        ▲
                        │ in-process calls
        ┌───────────────┴───────────────────────────────┐
        │ scripts/api/api_server.gd  (headless host)    │
        │ line-JSON over loopback TCP, token auth       │
        └───────────────▲───────────────────────────────┘
                        │ circuitforge-local-api/1
        ┌───────────────┴───────────────────────────────┐
        │ mcp_server/circuitforge_mcp/  (Python adapter) │
        │ engine_client.py + server.py                  │
        │ MCP tools · resources · prompts               │
        └───────────────▲───────────────────────────────┘
                        │ MCP (JSON-RPC over stdio)
        ┌───────────────┴───────────────────────────────┐
        │            AI agent / OpenCode                 │
        └────────────────────────────────────────────────┘
```

## Components

### 1. Application service layer — `scripts/api/app_service.gd`

A plain `RefCounted` that owns a `Session` and exposes every operation as a
`Dictionary`-in / `Dictionary`-out method. It is **UI-free and scene-free**, so
it runs headless. Responsibilities:

- **Discovery**: `get_simulator_info`, `get_capabilities`, `get_component_catalog`,
  `get_solver_info`.
- **Inspection**: project summary, component list/get, connections, node voltage,
  branch current, simulation results, circuit text, diagnostics.
- **Editing**: create/add/update/move/remove component, connect/disconnect,
  clear, edit preview.
- **Simulation**: `run_dc_simulation`, `run_transient_simulation`,
  `stop_simulation`, status, waveform data.
- **Persistence**: sandboxed save/load plus bundled examples.
- **Safety**: revision counter + `expected_revision` optimistic locking,
  `operation_id` idempotency, parameter validation before any mutation,
  structured error codes, hard limits.

All edit operations go through a single mutation path, so the revision counter
and undo/redo behaviour are identical to the GUI's.

### 2. Headless host — `scripts/api/api_server.gd`

A `SceneTree` script run by Godot in `--headless` mode:

```
godot --headless --path <project> --script res://scripts/api/api_server.gd \
      -- --port 0 --disconnect-grace 3
```

- Binds a **loopback-only** TCP socket (`--port 0` = ephemeral port).
- Generates a random **token** per run.
- Prints exactly one stdout line when ready:

  ```
  CIRCUITFORGE-API-READY {"protocol":"circuitforge-local-api/1",
                          "app_version":"0.1.0","port":51353,"token":"<32 hex>"}
  ```

  Everything else it prints goes to stderr, keeping stdout clean for framing.
- Serves **one request per line**, one response per line (JSON). Max line size
  1 MB. Each request must carry `"auth":"<token>"`.
- Exits when it receives a `shutdown` request, or when there have been no
  connected clients for `--disconnect-grace` seconds (default 5).

> **Why TCP and not stdin?** Godot has no non-blocking stdin read on the
> `SceneTree` main loop, which makes a stdio transport inside the engine
> unreliable. A loopback TCP socket is deterministic, testable, and still
> local-only. See `docs/research/dossier.md` for the evaluation.

### 3. Python adapter — `mcp_server/circuitforge_mcp/`

- `engine_client.py` — spawns or attaches to the engine, parses the READY
  banner, and provides a lock-guarded `call(method, params)` that speaks
  `circuitforge-local-api/1`. It never runs shell commands from tool arguments.
  Long-lived stdin/stdout pump threads forward engine stderr to the adapter's
  stderr.
- `server.py` — an `MCPServer` (official `mcp==2.3.0` SDK) that:
  - manages the engine via an async **lifespan** (start on boot, close on exit),
  - exposes all tools with descriptions, JSON input schemas and
    `ToolAnnotations` (`read_only_hint`, `destructive_hint`, `idempotent_hint`,
    `open_world_hint`),
  - returns `CallToolResult` with both human-readable text and
    `structured_content`,
  - exposes **resources** (`circuit://…`) and **prompts**.

## Two connection modes

| Mode | Trigger | Use when |
| --- | --- | --- |
| **spawn** (default) | no `CIRCUITFORGE_API_PORT` | normal use; the adapter owns the engine |
| **attach** | `CIRCUITFORGE_API_PORT` + `CIRCUITFORGE_API_TOKEN` set | you already run an engine (e.g. shared across sessions) |

## Request lifecycle

```
agent → tool call → server.py → engine_client.call()
      → TCP line request → api_server.gd dispatch → app_service.gd
      → {"success":true,"result…"} or structured error
      ← TCP line response ← CallToolResult(content, structured_content, is_error)
```

## Error model

Every engine response is either `{"success": true, ...}` or
`{"success": false, "error": {"code", "message", "suggested_action"}}`. The
adapter faithfully maps these to MCP `CallToolResult`s with `is_error=true`, so
the agent receives both a machine-readable `code` and a human-readable message.
Codes are listed in [`tool_reference.md`](tool_reference.md#error-codes).

## Concurrency and consistency

- A single engine thread serialises all calls; the adapter additionally guards
  each socket with a lock.
- Every project carries a monotonically increasing **revision**. Editing tools
  accept an optional `expected_revision`; a mismatch returns
  `OPERATION_CONFLICT` and changes nothing (optimistic locking).
- Creating/removing operations accept an `operation_id`; replaying the same id
  is a no-op (idempotent retries).

## Offline guarantees

- No network egress is performed by the adapter or the engine; IPC is
  `127.0.0.1` only.
- The only listener is the engine socket, bound to loopback with a random token.
- Simulations run entirely in-process on the local machine.
