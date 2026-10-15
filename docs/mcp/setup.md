# MCP Integration — Setup

The adapter is a small Python package that launches a headless copy of the
Godot engine. You need both Godot and Python present.

## 1. Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| Python | 3.10+ | 3.10 and 3.12 are both verified |
| Godot | 4.7.x (standard) | not the .NET build |
| CircuitForge project | this repository | must contain `project.godot` |

## 2. Install the Python SDK

From the repository root:

**Windows (PowerShell)**
```powershell
py -3 -m venv mcp_server\.venv
mcp_server\.venv\Scripts\python -m pip install --upgrade pip
mcp_server\.venv\Scripts\python -m pip install -r mcp_server\requirements.txt
```

**Linux / macOS**
```bash
python3 -m venv mcp_server/.venv
mcp_server/.venv/bin/python -m pip install --upgrade pip
mcp_server/.venv/bin/python -m pip install -r mcp_server/requirements.txt
```

`requirements.txt` pins `mcp==2.3.0` (the official Model Context Protocol SDK).

## 3. Environment variables

| Variable | Required | Meaning |
| --- | --- | --- |
| `CIRCUITFORGE_GODOT` | recommended | Full path to the Godot 4.7 executable. On Windows prefer the **console** build so engine stderr is visible. If unset, the adapter searches `PATH` for `godot`/`godot4`. |
| `CIRCUITFORGE_PROJECT` | recommended | Folder containing `project.godot`. Defaults to the repository root inferred from the package location. |
| `CIRCUITFORGE_API_PORT` | optional | Attach to an already-running engine instead of spawning one. |
| `CIRCUITFORGE_API_TOKEN` | optional | Token for the attach mode above. |

**Windows (console build — recommended)**
```powershell
$env:CIRCUITFORGE_GODOT   = "D:\tools\Godot_v4.7.2-stable_win64_console.exe"
$env:CIRCUITFORGE_PROJECT = "D:\circutsimilator"
```

**Linux**
```bash
export CIRCUITFORGE_GODOT=/opt/godot/godot4
export CIRCUITFORGE_PROJECT=/home/me/circutsimilator
```

## 4. Verify

Run the built-in selftest — it starts the engine, prints versions, tool counts
and exits:

```powershell
mcp_server\.venv\Scripts\python -m circuitforge_mcp --selftest
```

Expected output:
```
CircuitForge 3D MCP adapter — selftest
  godot   = D:\tools\Godot_v4.7.2-stable_win64_console.exe
  project = D:\circutsimilator
  engine  = ok  app=CircuitForge 3D v=0.1.0 proto=circuitforge-local-api/1 port=127.0.0.1:51353
  tools     = 32
  resources = 7
  prompts   = 8
selftest OK
```

Run the end-to-end protocol suite (Tests A–J):
```powershell
mcp_server\.venv\Scripts\python mcp_server\tests\test_mcp_integration.py
```

## 5. Run the server manually

The adapter speaks MCP over stdio, so running it directly just waits for a
client:

```powershell
mcp_server\.venv\Scripts\python -m circuitforge_mcp
```

All diagnostics appear on **stderr** (prefixed `[circuitforge-3d]` /
`[engine]`); stdout carries protocol frames only.

## Attach mode (optional)

Start an engine yourself and share it between adapters:

```powershell
# Terminal 1 — start the engine (it prints the READY line with port + token)
& $env:CIRCUITFORGE_GODOT --headless --path $env:CIRCUITFORGE_PROJECT `
    --script res://scripts/api/api_server.gd -- --port 51353 --disconnect-grace 30

# Terminal 2 — point the adapter at it
$env:CIRCUITFORGE_API_PORT  = "51353"
$env:CIRCUITFORGE_API_TOKEN = "<token from the READY line>"
mcp_server\.venv\Scripts\python -m circuitforge_mcp --selftest
```
