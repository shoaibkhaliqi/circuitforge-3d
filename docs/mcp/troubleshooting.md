# Troubleshooting

## `ENGINE_UNAVAILABLE: Godot was not found.`

`CIRCUITFORGE_GODOT` is unset and no `godot`/`godot4` is on `PATH`.

- Set `CIRCUITFORGE_GODOT` to the **full path** of the Godot 4.7 executable.
- On Windows use the **console** build (`..._console.exe`).

## `ENGINE_UNAVAILABLE: The CircuitForge project folder was not found.`

Set `CIRCUITFORGE_PROJECT` to the folder containing `project.godot`.

## `ENGINE_TIMEOUT` / engine exits before ready

The headless engine failed to start. Diagnose by running it manually:

```powershell
& $env:CIRCUITFORGE_GODOT --headless --path $env:CIRCUITFORGE_PROJECT `
    --script res://scripts/api/api_server.gd -- --port 0 --disconnect-grace 3
```

You should see one `CIRCUITFORGE-API-READY {...}` line on stdout and
`[engine] CircuitForge local API listening on 127.0.0.1:<port>` on stderr.
Common causes:

- Wrong Godot version (needs **4.7.x**, standard not .NET).
- The project has import errors — open it once in the Godot editor, or add a
  first-run import step.
- A firewall blocking loopback (rare).

## Adapter starts but OpenCode shows no tools

- Confirm `command` is an **array** in `opencode.json`, and `type` is `"local"`.
- Set `PYTHONPATH` to the `mcp_server` folder (or run the adapter with
  `cwd=mcp_server`) so `-m circuitforge_mcp` resolves.
- **Restart OpenCode** — config is not hot-reloaded.
- Check the server's stderr (OpenCode exposes MCP logs); look for the
  `[circuitforge-3d]` banner.

## `No module named circuitforge_mcp`

`PYTHONPATH` does not include `mcp_server`. Add it, or install the venv and run
from inside `mcp_server`:

```powershell
mcp_server\.venv\Scripts\python -m circuitforge_mcp --selftest
```
(working directory `mcp_server`.)

## `ModuleNotFoundError: No module named 'mcp'` / `mcp.server.fastmcp`

The environment has the wrong SDK. This project targets **`mcp==2.3.0`**, where
`FastMCP` was renamed to `MCPServer`. Reinstall:

```powershell
mcp_server\.venv\Scripts\python -m pip install -r mcp_server\requirements.txt
```

## `InvalidSignature: return type ... is not serializable for structured output`

An adapter development error: a tool declared `structured_output=True` returned a
bare `dict`. Tool return types must be `dict[str, Any]`.

## Simulation returns `SINGULAR_OR_NONCONVERGENT`

- Ensure a **ground** component exists (a reference node `"0"`).
- Look for conflicting ideal sources across the same net (`CONFLICTING_SOURCES`).
- Check for floating subnets (`get_diagnostics`).

## `NO_SIMULATION_RESULT` when reading a voltage/current

Run `run_dc_simulation` (or a transient) first; measurements reflect the last
successful run.

## `OPERATION_CONFLICT`

Your `expected_revision` is stale (something changed the project). Re-read
`get_project_summary`, then retry with the new revision.

## `PERMISSION_DENIED` on save/load

The path left the sandbox. Use a filename relative to `user://projects` (for
save) or a bundled example (for load). No absolute paths, no `..`.

## Zombie engine processes

The engine exits on `shutdown` or after `--disconnect-grace` seconds with no
clients (default 5). If one lingers, check for a crashed adapter:

```powershell
Get-Process Godot* | Select-Object Id, ProcessName
Stop-Process -Name "Godot_v4.7.2-stable_win64_console"
```

## Windows: stderr diagnostics missing

The **windowed** Godot build detaches stdio, so `[engine]` lines are lost. Use
the console build for `CIRCUITFORGE_GODOT`.

## Still stuck?

Run the selftest and the protocol suite; both print precise failures:

```powershell
mcp_server\.venv\Scripts\python -m circuitforge_mcp --selftest
mcp_server\.venv\Scripts\python mcp_server\tests\test_mcp_integration.py
```
