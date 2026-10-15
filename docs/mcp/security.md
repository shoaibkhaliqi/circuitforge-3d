# Security and Permissions

The MCP integration is designed so an AI agent can drive the simulator **without**
gaining code execution, arbitrary filesystem access, or network reach.

## Threat model

| Concern | Mitigation |
| --- | --- |
| Arbitrary code execution | Tools only accept data (ids, numbers, enums, endpoint specs). No tool takes a shell command, expression, script or code path. The adapter never builds a shell from tool input. |
| Arbitrary file read/write | Persistence is confined to two sandbox roots: `user://projects` (writable) and `res://data/examples` (read-only). Attempts to escape return `PERMISSION_DENIED`. |
| Network exposure | The adapter opens **no** listener. It speaks MCP on stdio (stdout=protocol, stderr=diagnostics). The only socket is the engine's, bound to **127.0.0.1** with a random per-run token. |
| Data exfiltration | No network egress; simulations are local. Nothing is uploaded. |
| Unintended destructive edits | Destructive tools (`remove_component`, `clear_circuit`) require explicit `confirm=true`; edit tools support `expected_revision` optimistic locking; the GUI's undo/redo still applies. |
| Resource exhaustion | Hard limits on components, wires, transient steps and returned samples; bounded call timeouts. |
| Output/argument injection into the agent | Tool outputs are data, not instructions. The engine returns structured errors; the adapter wraps them as `CallToolResult`s without executing anything. |

## Sandbox roots

| Root | Access | Resolves to |
| --- | --- | --- |
| `user://projects` | write + read | `%APPDATA%\Godot\app_userdata\CircuitForge 3D\projects` (Windows) |
| `res://data/examples` | read only | bundled examples inside the project |

`save_project` / `load_project` normalise and reject `..` traversal and absolute
paths outside these roots.

## Transport and token

- The engine prints a **one-line** READY banner on stdout:
  `CIRCUITFORGE-API-READY {"port":N,"token":"<32 hex>",…}`.
- Every request must carry `"auth":"<token>"`. Requests without a valid token
  are rejected. The token is regenerated on every engine start and never
  persisted.
- Because the socket is loopback-only, no remote host can reach it.

## Recommended OpenCode permission scoping

CircuitForge tools are exposed to OpenCode as `<server>_<tool>`. If the agent
has broad autonomy, you can still require confirmation for mutations:

```json
{
  "permission": {
    "circuitforge_remove_component": "ask",
    "circuitforge_clear_circuit": "ask",
    "circuitforge_save_project": "ask",
    "circuitforge_disconnect_connection": "ask"
  }
}
```

`disconnect_connection` is marked destructive because it changes the circuit
topology; scope it if you want review.

## What is intentionally **not** exposed

- No filesystem tools, no shell, no `eval`.
- No ability to load external Python/GDScript or add-ons.
- No ability to write outside the sandbox.
- No raw socket or network access.

## Dependency supply chain

The adapter depends only on the official MCP SDK. See
`docs/releases/dependency_licenses.md` for licences.
