# CircuitForge 3D — Release Notes

## 0.1.0

First functional release. An independent, offline-first 3D breadboard circuit
simulator built with Godot 4.7 and GDScript.

### Highlights

- **3D workbench** — interactive breadboard (30 rows, five-hole terminal
  groups, centre channel, four power rails with optional split-rail mode).
- **Real simulation engine** — modified nodal analysis with:
  - DC operating point,
  - backward-Euler transient analysis for resistors, capacitors and inductors,
  - Newton–Raphson for nonlinear devices with SPICE-style junction limiting.
- **Components** — resistor, capacitor, inductor, potentiometer, switch,
  ground, DC voltage source (DC / sine / square / pulse / triangle),
  DC current source, diode, LED, zener diode.
- **Logic gates** — AND, OR, NOT, NAND, NOR, XOR and buffer (5 V levels),
  solved by the same Newton–Raphson engine as the analog devices.
- **Connectivity graph** — union-find over hole adjacency plus explicit wires.
- **Instruments** — auto-scaling oscilloscope plotting real transient samples,
  a multimeter for net-voltage / branch-current probes, and node-voltage and
  branch-current readouts with diagnostics.
- **Projects** — versioned, validated `.cf3d` JSON files with safe migration,
  plus undo/redo, Save As and an unsaved-changes guard.
- **Adjustable workbench lighting** (studio / bright / night).
- **11 bundled examples**, loadable from the toolbar or the command line.
- **248 automated tests** (solver, connectivity, persistence, units, camera,
  logic, placement, end-to-end integration, examples).

### Packaging

- `export_presets.cfg` defines **Windows Desktop** and **Linux/X11** presets;
  tests, tools and docs are excluded from release builds.
- Windows build produced and booted during this release.
- Linux build produced and ELF-validated (binary only; runtime not verified —
  see `build_linux.md`).
- A GitHub Actions workflow (`.github/workflows/tests.yml`) runs the suite on
  Linux and Windows.

### Known limitations

- Linux runtime not verified (exported and ELF-validated only; see
  `platform_checklist.md`).
- No export for macOS / Android / Web in this release.
- Logic gates are combinational only (no flip-flops / counters / MCU).
- The oscilloscope plots one shared vertical scale for all probes.

### Fixed during development

- Clicking the breadboard placed all pins in a single five-hole net, shorting
  the component; default placement now walks across rows.
- An invalid "invalid placement" indicator used `Node3D.modulate` (no such
  property) and could crash; the value label is now tinted instead.
- MNA branch rows could overlap node rows (branch offset corrected).
- Newton–Raphson convergence check now also requires junction-limiting state to
  settle.
- Persistence now serialises with full precision, so very small values
  (e.g. `2e-19`) survive a save/load round-trip, and no longer writes internal
  `_warnings` into project files.
- JSON parse errors during load are now reported with a line number instead of
  silently producing an empty project.
- Non-finite solver output is detected and reported instead of shown as a result.
- Oscilloscope now auto-scales and defaults to node-voltage probes instead of
  silently clipping.
- Default window size reduced to 1280×720 so the full UI fits ordinary screens,
  and the toolbar now wraps to a second row.
