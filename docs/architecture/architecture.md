# CircuitForge 3D — Architecture

## 1. Purpose
An independent, offline-first 3D breadboard circuit simulator. It computes real
electrical results from a modified-nodal-analysis (MNA) solver and never substitutes
hardcoded or fabricated values for a failed solve.

## 2. Technology stack (pinned)
| Component | Version | Notes |
|---|---|---|
| Godot Engine | **4.7.2 stable (official)** | Pinned. Do not upgrade casually. `4.7.2.stable.official.ed1daf0bf` |
| GDScript | bundled with the engine | Primary language |
| JSON | engine built-in | Project interchange format |
| Git | 2.49.x | Source control |

No paid API, subscription, cloud backend or external numerical dependency is used.
The installed application performs no network access.

## 3. Layer boundaries
```
+--------------------------------------------------------------+
| Graphics layer        scripts/camera, scenes/workbench, ui   |
|   camera, selection, placement, panels, labels               |
+---------------------------|----------------------------------+
                            | uses read-only results
+---------------------------v----------------------------------+
| Measurement layer     scripts/instruments                    |
|   multimeter, oscilloscope (consume SolverResult samples)    |
+---------------------------|----------------------------------+
                            | reads
+---------------------------v----------------------------------+
| Simulation layer      scripts/simulation                     |
|   MNA, solver, device models. NO scene-tree dependency.       |
+---------------------------^----------------------------------+
                            | built from
+---------------------------|----------------------------------+
| Connectivity layer    scripts/breadboard, connectivity       |
|   nets, terminal groups, wires. Pure data graph.             |
+---------------------------^----------------------------------+
                            | built from
+---------------------------|----------------------------------+
| Component model layer  scripts/components, data/components   |
|   identity, pins, parameters, units, model reference         |
+---------------------------|----------------------------------+
                            | serialised by
+---------------------------v----------------------------------+
| Persistence layer     scripts/persistence                    |
|   JSON schema version, validation, migration, save/load      |
+--------------------------------------------------------------+
```

**Hard rule:** the electrical network is keyed on stable string IDs and net names.
It must never depend on scene-node names, screen coordinates or visual proximity.

## 4. Data flow
```
placed components + wires
        |  NetlistBuilder
        v
   Circuit (nets, SimElement list)          <-- pure data, serialisable
        |  CircuitSolver
        v
   SolverResult (node voltages, branch currents, waveform samples)
        |  read-only
        +--> 3D labels / wire colouring
        +--> Multimeter probe
        +--> Oscilloscope traces
        +--> Diagnostics panel
```

## 5. Breadboard topology model
The virtual solderless breadboard is an explicit electrical graph:

- Columns `a..e` (top half) and `f..j` (bottom half), rows `1..30`.
- In each half-row, the **5 holes of one row** (`a-e`, `f-j`) form one **terminal group**
  (one net). This is the standard solderless-breadboard continuity.
- The **centre channel** (gap between `e` and `f`) separates the two halves: `a-e` and
  `f-j` of the same row are **never** connected.
- Two **power rails** run along each edge: a positive rail (`+`) and a negative rail (`-`)
  on both the top and the bottom. Rails are continuous along their full length by default;
  a `rail_split` option can split each rail at the midpoint row to model boards with a
  split power bus.
- **No two adjacent rows are connected.** No two rail holes are connected to terminal
  groups unless a wire is placed.

Any simplification is limited to: rails are ideal zero-resistance continuities (real copper
has a small resistance), and there is no minimum wire length.

## 6. Solver
- **DC:** Modified Nodal Analysis. Unknowns are node voltages (reference node excluded) plus
  one branch current per independent voltage source / inductor. Solved with Gaussian
  elimination and partial pivoting. Singular systems are detected via a pivot threshold and
  reported (not silently zeroed).
- **Transient:** Backward-Euler companion models. Capacitor `G=C/dt`, inductor reduces to a
  branch with `L/dt` term. Simulation time is decoupled from wall-clock time.
- **Nonlinear:** Newton–Raphson with damping and iteration limits; diodes/LEDs use the Shockley
  equation `I = Is(e^{V/(n·Vt)} − 1)`.
- Tolerances: pivot threshold `1e-12`; Newton voltage tolerance `1e-6 V`; max 100 iterations.
  Thermal voltage `Vt = 0.025852 V` (≈ 300 K).

## 7. Directory structure
```
res://
  project.godot
  scenes/    main, workbench, components, panels, instruments
  scripts/   app, camera, interaction, components, breadboard,
             connectivity, simulation, instruments, persistence, ui, diagnostics
             api/  (app_service.gd, api_server.gd — UI-free service layer + headless host)
  data/      components, examples, schemas
  assets/    models, materials, textures, icons
  tests/     unit, connectivity, solver, integration, persistence, run_tests.gd
  docs/      research, architecture, user_guide, testing, releases, mcp
  tools/
mcp_server/  circuitforge_mcp/ (Python MCP adapter), tests/, requirements.txt
```

## 8. Application service layer and MCP

All circuit logic is reachable through a UI-free application service layer
(`scripts/api/app_service.gd`). The GUI, the automated tests and the MCP
integration all use it, so behaviour is identical across them. A headless host
(`scripts/api/api_server.gd`) exposes the layer over a token-authenticated
loopback socket, which the Python MCP adapter (`mcp_server/`) translates to the
Model Context Protocol over stdio. See `docs/mcp/` for details.

## 9. Platform strategy
Developed and verified on the machine present in this environment
(Windows 10, x86-64). All file handling, paths and process calls are platform independent
(`res://`, `user://`, `OS.get_name()` guards). Linux export templates are documented;
Windows export is verified. See `docs/releases/platform_checklist.md`.
