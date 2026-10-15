# CircuitForge 3D — MCP Integration

CircuitForge 3D ships a **Model Context Protocol (MCP)** server so AI agents
(such as OpenCode) can inspect, edit, validate and simulate real breadboard
circuits against the actual MNA solver — not a mock.

```
┌──────────┐   MCP (stdio)   ┌────────────────────┐   local API   ┌──────────────┐
│ AI agent │ ◀────────────▶  │ circuitforge-3d    │ ◀───────────▶ │ headless     │
│ (client) │   JSON-RPC      │ MCP adapter (Py)   │  loopback TCP │ Godot engine │
└──────────┘                 └────────────────────┘  token auth   │ (app_service)│
                                                                  └──────────────┘
```

- **Transport**: MCP over **stdio**. Protocol messages go to stdout; every
  diagnostic goes to stderr. The adapter opens **no network listener**.
- **Engine**: the same application service layer (`scripts/api/app_service.gd`)
  used by the GUI and by the automated tests, hosted by a headless Godot process
  over a token-authenticated loopback socket.
- **SDK**: the official Python MCP SDK (`mcp==2.3.0`).

## Documentation index

| Document | Contents |
| --- | --- |
| [`architecture.md`](architecture.md) | Components, processes, lifecycle, local API protocol |
| [`setup.md`](setup.md) | Windows and Linux install and launch |
| [`opencode.md`](opencode.md) | Register the server in OpenCode |
| [`tool_reference.md`](tool_reference.md) | Every tool, resource and prompt |
| [`security.md`](security.md) | Sandbox, permissions, threat model |
| [`demo.md`](demo.md) | Copy-paste end-to-end walkthrough |
| [`troubleshooting.md`](troubleshooting.md) | Common failures and fixes |
| [`limitations.md`](limitations.md) | Honest scope and known limits |

## 60-second quick start (Windows)

```powershell
# 1. Create the venv and install the SDK
py -3 -m venv mcp_server\.venv
mcp_server\.venv\Scripts\python -m pip install -r mcp_server\requirements.txt

# 2. Point the adapter at Godot and the project
$env:CIRCUITFORGE_GODOT   = "D:\path\to\Godot_v4.7.2-stable_win64_console.exe"
$env:CIRCUITFORGE_PROJECT = "D:\circutsimilator"

# 3. Smoke-test the adapter (prints the tool list, then exits)
mcp_server\.venv\Scripts\python -m circuitforge_mcp --selftest
```

Then register it with OpenCode — see [`opencode.md`](opencode.md).

## Requirements

- Godot **4.7.x** (standard build; the console build is recommended on Windows
  so stderr diagnostics are captured).
- Python **3.10+** for the adapter.
- No internet connection is needed at runtime.

## Verification

The MCP integration is covered by an end-to-end protocol test suite
(Tests A–J) that drives the adapter through the real MCP SDK client:
initialization, discovery, build, simulate, measure, error handling,
persistence, concurrency, transport framing and offline operation.

```powershell
$env:CIRCUITFORGE_GODOT   = "...Godot_v4.7.2-stable_win64_console.exe"
$env:CIRCUITFORGE_PROJECT = "D:\circutsimilator"
mcp_server\.venv\Scripts\python mcp_server\tests\test_mcp_integration.py
```

See `docs/releases/test_report.md` for recorded results.
