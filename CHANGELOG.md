# Changelog

All notable changes to CircuitForge 3D are documented here. This project aims to
follow [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-16

First functional, production-oriented release.

### Added
- 3D breadboard workbench (30 rows, five-hole terminal groups, centre channel,
  four power rails with optional split-rail mode) with an orbit/pan/zoom camera.
- Modified Nodal Analysis engine: DC operating point, backward-Euler transient
  analysis (R/C/L) and Newton–Raphson nonlinear solving with junction limiting.
- Components: resistor, capacitor, inductor, potentiometer, switch, ground,
  DC voltage source (DC / sine / pulse / square), DC current source, diode, LED,
  zener diode.
- Combinational logic gates: AND, OR, NOT, NAND, NOR, XOR, buffer (5 V levels).
- Instruments: auto-scaling oscilloscope and a multimeter (net/component probe).
- Adjustable workbench lighting (studio / bright / night).
- Versioned, validated `.cf3d` JSON projects with migration, undo/redo and an
  unsaved-changes guard.
- 11 bundled example circuits, loadable from the toolbar or the command line.
- Full command-line file opening.
- 260+ automated tests (solver, connectivity, persistence, units, camera,
  placement, logic, end-to-end, examples).
- Windows and Linux export presets; GitHub Actions test workflow; MIT license.

### Fixed
- Clicking the breadboard placed all pins in one five-hole net (shorting the
  component); default placement now walks rows.
- `Node3D.modulate` was used for invalid placements (invalid property / crash);
  the value label is now tinted instead.
- MNA branch rows could overlap node rows.
- Newton–Raphson convergence now also requires junction-limiting state to settle.
- Persistence serialises with full precision so tiny values survive round-trips.
- Silent JSON parse errors during load are now reported with a line number.
- Non-finite solver output is detected and reported instead of shown as a result.
- Oscilloscope auto-scales and defaults to node-voltage probes.
- Default window size reduced to 1280×720 to fit ordinary screens.
- `_warnings` was being persisted into project files.

### Known limitations
- Linux build is verified to boot headlessly under WSL2; full GPU runtime on a
  native Linux desktop was not exercised.
- Logic gates are combinational only; sequential logic (flip-flops, counters)
  and a programmable MCU are future work.
- No macOS / Android / Web export in this release.
