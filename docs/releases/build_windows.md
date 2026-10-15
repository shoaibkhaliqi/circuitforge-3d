# Building CircuitForge 3D for Windows

## Prerequisites

- **Godot 4.7** (standard build, not .NET) — for example
  `Godot_v4.7.2-stable_win64_console.exe`.
- **Export templates** for the same version
  (`4.7.2.stable`), installed via the editor's
  *Editor ▸ Manage Export Templates…* or placed in
  `%APPDATA%\Godot\export_templates\4.7.2.stable\`.

## Export

From the project root:

```powershell
New-Item -ItemType Directory -Force -Path build\windows | Out-Null

& "<godot_console.exe>" --headless --path . `
    --export-debug "Windows Desktop" "build\windows\CircuitForge3D.exe"
```

For a release build, use `--export-release` (requires the release template).

The `Windows Desktop` preset is defined in `export_presets.cfg` with
architecture `x86_64` and `embed_pck = false`, producing:

```
build/windows/CircuitForge3D.exe          # executable
build/windows/CircuitForge3D.pck          # game data (must sit next to the exe)
build/windows/CircuitForge3D.console.exe  # console wrapper (debug only)
```

## Verify

```powershell
& "build\windows\CircuitForge3D.exe" --headless --quit-after 90
```

Exit code `0` and no error output means the packaged game boots. You can also
pass a project file to confirm the command-line loader:

```powershell
& "build\windows\CircuitForge3D.exe" --headless --quit-after 90 `
    -- "res://data/examples/04_voltage_divider.cf3d"
```

## Distribute

Zip the contents of `build/windows/` (the `.exe` and the `.pck` must stay
together). No installer or runtime dependencies are required; Godot statically
links what it needs.

## Verified

The Windows build was produced and booted on Windows 10 (10.0.26300) during
development of 0.1.0 — see `test_report.md`.
