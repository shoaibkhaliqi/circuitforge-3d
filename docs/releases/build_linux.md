# Building CircuitForge 3D for Linux

> **Verification status:** the Linux export was produced successfully from a
> Windows host using the official Godot 4.7.2 Linux templates. The resulting
> binary was **statically validated** (ELF64, little-endian, `e_machine = 0x3E`
> i.e. x86-64, `ET_EXEC`) but its **runtime was not executed**: this build host
> cannot start any Linux guest, because the WSL2 "Virtual Machine Platform"
> optional component and BIOS virtualisation are unavailable
> (`HCS_E_SERVICE_NOT_AVAILABLE`). Treat Linux as *exported and ELF-validated*,
> not *runtime-verified*. To complete the check, run the build on a real Linux
> host (or a host with working WSL2/Hyper-V) using the commands below.

## Prerequisites

- **Godot 4.7** (standard build).
- Linux export templates `4.7.2.stable`
  (`linux_debug.x86_64` / `linux_release.x86_64`) installed under
  `~/.local/share/godot/export_templates/4.7.2.stable/` (Linux) or
  `%APPDATA%\Godot\export_templates\4.7.2.stable\` (Windows).

## Export

```bash
mkdir -p build/linux
godot --headless --path . \
    --export-release "Linux/X11" "build/linux/CircuitForge3D.x86_64"
```

The `Linux/X11` preset is defined in `export_presets.cfg` (architecture
`x86_64`, `embed_pck = false`). Output:

```
build/linux/CircuitForge3D.x86_64   # executable
build/linux/CircuitForge3D.pck      # game data
build/linux/CircuitForge3D.sh       # launcher script
```

## Run

```bash
chmod +x build/linux/CircuitForge3D.x86_64
./build/linux/CircuitForge3D.x86_64
```

To confirm the command-line loader:

```bash
./build/linux/CircuitForge3D.x86_64 --headless --quit-after 90 \
    -- res://data/examples/04_voltage_divider.cf3d
```

## Notes

- Requires a working OpenGL/Vulkan driver. Godot 4.7 uses the Forward+ renderer
  by default; on software-only or old GPUs consider re-exporting with the
  Mobile or Compatibility renderer
  (`rendering/renderer/rendering_method` in `project.godot`).
- Keep the `.x86_64` binary and the `.pck` together, or set
  `embed_pck = true` for a single self-contained file.
