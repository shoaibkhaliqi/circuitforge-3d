# Registering CircuitForge 3D in OpenCode

OpenCode discovers MCP servers from its config file. Add a `local` MCP server
entry that launches the adapter.

## Project config

Create `opencode.json` in the repository root (or add to an existing one):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "circuitforge": {
      "type": "local",
      "enabled": true,
      "command": [
        "D:\\circutsimilator\\mcp_server\\.venv\\Scripts\\python.exe",
        "-m",
        "circuitforge_mcp"
      ],
      "environment": {
        "CIRCUITFORGE_GODOT": "D:\\tools\\Godot_v4.7.2-stable_win64_console.exe",
        "CIRCUITFORGE_PROJECT": "D:\\circutsimilator",
        "PYTHONPATH": "D:\\circutsimilator\\mcp_server"
      }
    }
  }
}
```

On Linux/macOS use forward slashes and the venv interpreter path:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "circuitforge": {
      "type": "local",
      "enabled": true,
      "command": ["/home/me/circutsimilator/mcp_server/.venv/bin/python", "-m", "circuitforge_mcp"],
      "environment": {
        "CIRCUITFORGE_GODOT": "/opt/godot/godot4",
        "CIRCUITFORGE_PROJECT": "/home/me/circutsimilator",
        "PYTHONPATH": "/home/me/circutsimilator/mcp_server"
      }
    }
  }
}
```

Key points:

- `command` is an **array** of strings, not a single string.
- `type` is **required** (`"local"`).
- `PYTHONPATH` must point at the `mcp_server` folder so `-m circuitforge_mcp`
  resolves, because `command` is run with OpenCode's own working directory.
- `CIRCUITFORGE_GODOT` should be the **console** build on Windows so the
  adapter can capture engine stderr for diagnostics.

A ready-to-edit copy is provided at [`mcp_server/opencode.example.json`](../../mcp_server/opencode.example.json).

## Restart

opencode loads config once at startup and does not hot-reload it. **Quit and
restart OpenCode** after adding the server.

## Verify

In OpenCode, list MCP tools (e.g. `/mcp` or the tools panel). You should see the
`circuitforge` server with 36 tools such as `get_simulator_info`,
`get_component_catalog`, `get_catalog_facets`, `get_board_pinout`, `get_pin_states`,
`set_pin_levels`, `add_component`,
`run_dc_simulation`.

Ask the agent:

> Using the circuitforge server: build a 5 V source, a 1 kΩ resistor to ground,
> run a DC simulation and report the measured current.

Expected: `5.0 mA`.

## Recommended permissions

The integration is designed to be safe by default, but you can scope it further.
CircuitForge tools are MCP tools; OpenCode's `permission` rules for MCP tools are
keyed as `<server>_<tool>`. A conservative example that lets the agent read and
simulate but asks before destructive edits:

```json
{
  "permission": {
    "circuitforge_remove_component": "ask",
    "circuitforge_clear_circuit": "ask",
    "circuitforge_save_project": "ask"
  }
}
```

See [`security.md`](security.md) for the threat model.

## Alternative: global config

To make the server available in every project, put the same `mcp` block in
`~/.config/opencode/opencode.json` (global config, not `~/.opencode/`).
