# CircuitForge 3D

An independent, offline-first **3D breadboard circuit simulator** written in
GDScript for **Godot 4.7**. You drop real components onto a virtual breadboard,
wire the holes together, and solve the circuit with a genuine
**modified nodal analysis (MNA)** engine — DC operating point, transient
(backward-Euler) and nonlinear (Newton–Raphson) analysis.

Nothing in the results is faked. Every number shown on a component label or on
the oscilloscope comes from the solver.

> Status: **0.1.0** — Windows build verified end-to-end. Linux build produced
> and ELF-validated; its runtime was not executed (no Linux/WSL guest available
> on the build host). See `docs/releases/platform_checklist.md`.

## Features

- **3D workbench** with an interactive breadboard: 30-row board, five-hole
  terminal groups, centre channel, and four continuous power rails
  (with an optional split-rail mode), plus adjustable lighting
  (studio / bright / night).
- **Real solver**: MNA with DC, backward-Euler transient (R/C/L), and
  Newton–Raphson nonlinear elements with SPICE-style junction limiting.
- **Components** (data-driven definitions):
  Resistor, Capacitor, Inductor, Potentiometer, Switch, Ground,
  DC Voltage Source (with sine/square/pulse/triangle waveform support),
  DC Current Source, Diode, LED, Zener Diode.
- **Logic gates**: AND, OR, NOT, NAND, NOR, XOR and buffer (5 V levels).
- **Connectivity graph** built from physical hole adjacency plus explicit wires,
  with union-find net extraction.
- **Instruments**: an auto-scaling oscilloscope that plots real recorded
  transient samples, a multimeter for net-voltage / branch-current probes, and
  node-voltage and branch-current readouts.
- **Persistence**: versioned, validated JSON (`.cf3d`) projects with safe
  migration, undo/redo, **Save As** and an unsaved-changes guard.
- **11 bundled example circuits** (LED, divider, RC/RL, rectifier, zener, logic…)
  loadable from the toolbar or the command line.
- **248 automated tests** covering the solver, connectivity, persistence,
  units, camera, logic, placement and full end-to-end workflows.

## Quick start

1. Open the project in Godot 4.7, or run a build (see below).
2. Pick a component in the **left library** and click the breadboard to place it.
3. Use **Wire** mode (click two holes) to connect nets.
4. Drop a **Ground** component on the net you want as 0 V.
5. Press **Run DC** or **Run Transient**.
6. Select a component to edit its value in **Properties**.

Control the camera with **right-drag = orbit**, **middle-drag = pan**,
**wheel = zoom**. Shortcuts: `W` wire, `R` rotate, `Delete` delete,
`Space` run DC, `F1` help. Project shortcuts: `Ctrl+N` new, `Ctrl+O` open,
`Ctrl+S` save, `Ctrl+Shift+S` save as, `Ctrl+Z` / `Ctrl+Y` undo / redo.

### Run an example from the command line

```
godot --path <project> -- res://data/examples/05_rc_charging.cf3d
```

The project loads and immediately runs its default analysis.

## Running from source

Requires **Godot 4.7** (standard, not .NET).

```
godot --path .
```

## Tests

```
godot --headless --path . --script res://tests/run_tests.gd
```

Exit code `0` means all tests passed. See `docs/releases/test_report.md`.

## Documentation

- `docs/user_guide.md` — how to use the app.
- `docs/architecture/architecture.md` — engine internals.
- `docs/research/dossier.md` and `feature_matrix.md` — background.
- `docs/releases/build_windows.md`, `build_linux.md` — packaging.
- `docs/releases/test_report.md` — verification evidence.
- `docs/releases/risk_register.md`, `platform_checklist.md`,
  `dependency_licenses.md`.

## License

Released under the **MIT License** (see `LICENSE`). Third-party components and
their licenses are listed in `docs/releases/dependency_licenses.md`.
