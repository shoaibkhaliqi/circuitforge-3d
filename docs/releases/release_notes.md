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
- **Connectivity graph** — union-find over hole adjacency plus explicit wires.
- **Instruments** — oscilloscope plotting real transient samples with
  auto-scaling, plus node-voltage and branch-current readouts and diagnostics.
- **Projects** — versioned, validated `.cf3d` JSON files with safe migration,
  plus undo/redo.
- **10 bundled examples**, loadable from the toolbar or the command line.
- **186 automated tests** (solver, connectivity, persistence, units, camera,
  end-to-end integration, examples).

### Packaging

- `export_presets.cfg` defines **Windows Desktop** and **Linux/X11** presets.
- Windows build produced and booted during this release.
- Linux build produced (binary only; not runtime-verified — see
  `build_linux.md`).

### Known limitations

- Linux runtime not verified (exported only).
- No export for macOS / Android / Web in this release.
- Component set is limited to the linear passives, the ideal sources and the
  three two-terminal semiconductors listed above (no transistors, no logic ICs).
- The oscilloscope plots one shared vertical scale for all probes.

### Fixed during development

- MNA branch rows could overlap node rows (branch offset corrected).
- Newton–Raphson convergence check now also requires junction-limiting state to
  settle.
- Persistence now serialises with full precision, so very small values
  (e.g. `2e-19`) survive a save/load round-trip.
- Oscilloscope now auto-scales and defaults to node-voltage probes instead of
  silently clipping.
- Default window size reduced to 1280×720 so the full UI fits ordinary screens.
