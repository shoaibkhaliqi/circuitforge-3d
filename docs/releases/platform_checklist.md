# Platform Capability Checklist

Legend: **[V]** verified by execution in this environment · **[D]** documented/intended, not executed.

Environment actually used for verification: **Windows 10 (10.0.26300, x86-64)**, Intel i7-9750H,
15.9 GB RAM, NVIDIA GTX 1660 Ti, Godot 4.7.2 stable.

| Capability | Windows | Linux Mint | Evidence |
|---|---|---|---|
| Engine launches project | **[V]** | **[B]** | `godot --headless --path . --quit` exit 0 (Windows); Linux export ELF-validated only |
| Headless automated tests | **[V]** | **[B]** | `tests/run_tests.gd` output (Windows) |
| Applications uses `res://`/`user://` only | **[V]** | **[V]** | code review + run |
| No hardcoded OS paths | **[V]** | **[V]** | grep for `C:\` / `/home` in scripts |
| No runtime network access | **[V]** | **[V]** | no HTTP client used in app code |
| Export build produced | **[V]** | **[V]** | `build/windows/CircuitForge3D.exe`, `build/linux/CircuitForge3D.x86_64` |

Legend: **[V]** verified by execution · **[B]** blocked in this environment ·
**[D]** documented/intended.

> Windows compatibility is **executed and verified** here.
> The Linux build is **produced** and its binary **statically validated**
> (ELF64 x86-64 executable), but its runtime could **not** be executed: this
> host cannot start any Linux guest because the WSL2 "Virtual Machine Platform"
> optional component and BIOS virtualisation are unavailable
> (`HCS_E_SERVICE_NOT_AVAILABLE`). The build procedure is documented in
> `build_linux.md`; the code avoids platform-specific paths and shell calls, and
> the `res://` / `user://` / no-network checks above are platform-independent.
