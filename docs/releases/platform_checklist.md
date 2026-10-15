# Platform Capability Checklist

Legend: **[V]** verified by execution in this environment · **[D]** documented/intended, not executed.

Environment actually used for verification: **Windows 10 (10.0.26300, x86-64)**, Intel i7-9750H,
15.9 GB RAM, NVIDIA GTX 1660 Ti, Godot 4.7.2 stable.

| Capability | Windows | Linux Mint | Evidence |
|---|---|---|---|
| Engine launches project | **[V]** | **[D]** | `godot --headless --path . --quit` exit 0 |
| Headless automated tests | **[V]** | **[D]** | `tests/run_tests.gd` output |
| Applications uses `res://`/`user://` only | **[V]** | **[D]** | code review + run |
| No hardcoded OS paths | **[V]** | **[D]** | grep for `C:\` / `/home` in scripts |
| No runtime network access | **[V]** | **[D]** | no HTTP client used in app code |
| Export build produced | **[D]** | **[D]** | see `docs/releases/build_linux.md`, `build_windows.md` |

> Windows compatibility is **executed and verified** here.
> Linux Mint compatibility is **documented only** and is **not** claimed as tested, because no
> Linux host is available in this environment. The build procedure is provided and the code
> avoids platform-specific paths and shell calls.
