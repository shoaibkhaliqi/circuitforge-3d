# CircuitForge 3D — Upgrade Plan (Audit → Milestones)

This document records the audit of the existing project and the incremental plan
for the "beautiful, realistic 3D electronics simulator" upgrade. It is kept up to
date as milestones land.

## 1. Audit (current state before this upgrade)

| Area | Current implementation | Assessment |
| --- | --- | --- |
| Engine | Godot **4.7.2**, Forward+ renderer | Keep. Add a low-end graphics path. |
| Entry | `scenes/main/main.tscn` → `scripts/app/main.gd` (Node3D) | Scene is a stub; **all UI is built in code** in `main.gd` (~1000 lines). |
| Simulation | `scripts/simulation/*` — MNA, DC, backward-Euler transient, Newton–Raphson | Real and tested. Keep as the authoritative solver. |
| Connectivity | `scripts/connectivity/netlist_builder.gd` + `scripts/breadboard/breadboard.gd` | Correct topology; wire/proximity is safe. |
| Components | `scripts/components/component_db.gd` (18 types, data-driven) + `component_factory.gd` (procedural boxes) | Definitions good; **visuals are placeholder boxes/cylinders**. |
| Breadboard view | `scripts/breadboard/breadboard_view.gd` — flat box, cylinder "holes" | Needs realism: recessed holes, printing, rails, bevels, labels. |
| Persistence | `scripts/persistence/persistence.gd` — versioned `.cf3d` JSON | Keep; extend schema for new component metadata. |
| MCP | `mcp_server/` adapter + `scripts/api/app_service.gd` | Working (32 tools). Must be extended, not replaced. |
| UI/Theme | Default Godot theme, fixed-pixel overlays | **No design system.** Right panel pushed off-screen; labels dominate the view. |
| Tests | `tests/` — 248 passing | Keep green; extend for new features. |
| Platform | Windows verified; Linux ELF-validated (runtime unverified) | Keep documented; verify again at the end. |

### Baseline evidence (before changes)

- Tests: **248 / 248 passing** (`godot --headless --script res://tests/run_tests.gd`).
- App launches and solves the LED example (DC, 12 iterations, 9.733 mA).
- Screenshot baseline: `docs/plan/baseline_ui.png` (default theme, oversized labels,
  right panel clipped, toolbar overflow).

### Key reusable assets

- The MNA/Newton solver, netlist builder, breadboard topology, persistence and
  MCP service layer are **solid and authoritative** — reused unchanged.
- `ComponentDB` is already data-driven; it is the natural place to grow the
  catalog (pins, categories, metadata, simulation status).

### Architectural limitations found

1. UI is imperative and untokenised (no theme, no reusable widgets).
2. Component visuals are generic and unrelated to the component type.
3. No SubViewport; panels overlay a full-screen 3D view, so layout must be
   anchor-based and collision-aware.
4. No notion of "simulation status per component" (full / partial / visual-only).
5. No microcontroller concept at all; component model is fixed 2–3 pin devices.
6. New components cannot express >2-terminal packages with named pins.

## 2. Guiding decisions

- **Reuse, don't rewrite.** The solver, connectivity, persistence and MCP layers
  stay authoritative. All new features feed through them.
- **Honesty over polish.** Every component carries a `simulation_status` of
  `full`, `partial`, or `visual`. The UI and MCP surface it; nothing is claimed
  simulated unless the solver (or a real backend) produced the numbers.
- **Data-driven catalog.** New components are definition dictionaries, not code.
- **No fake hardware data.** Pin maps come from datasheets and are documented in
  `data/boards/*.json` with sources.
- **Incremental + verified.** After each milestone: run the full test suite,
  launch the app, capture a screenshot, and commit.

## 3. Milestones

| # | Milestone | Status |
| --- | --- | --- |
| 1 | Audit + **visual design system** (theme, palette, typography, reusable widgets) | done |
| 2 | Professional layout: toolbar, resizable/collapsible panels, status bar, component browser | done |
| 3 | Breadboard realism, camera controls, wire rendering, placement preview/highlight | in progress |
| 4 | High-quality reusable 3D models for basic components | done (first pass) |
| 5 | Arduino Uno R3 + Nano: accurate 3D boards + pin metadata | planned |
| 6 | Arduino pin-level simulation (Stage A) + basic peripherals | planned |
| 7 | Arduino code execution backend (Stage B/C) — feasibility-gated | planned |
| 8 | Sensors, displays, motors, advanced analog/digital parts | planned |
| 9 | Extend MCP tools/metadata for boards, pinouts, pin states, firmware | planned |
| 10 | Performance pass, examples, tests, Windows/Linux verification, docs | planned |

## 3a. Progress log

### Milestone 1 — design system (done)
- Added `scripts/ui/design.gd`: central palette (void/panel/input/sunken/border, text
  tiers, accent, ok/warn/err/select), font sizes, `theme()` builder (Button,
  LineEdit, ItemList, Tree, ScrollBar, SplitContainer, PopupMenu, TabContainer,
  Tooltip, separators) and helpers `section()`, `heading()`, `hint()`,
  `status_dot()`, `status_color()`.

### Milestone 2 — layout (done)
- `main.gd` rebuilt: `VBoxContainer` → toolbar (`HFlowContainer`, wraps) +
  `HSplitContainer` (library / centre / inspector) + status bar.
- Collapsible panels (`_toggle_panel`), component browser with search + category
  filter + hints, `View ▾` camera presets / Frame All / Reset.
- Status bar shows state dot, message, project name, tool, zoom, warning count.
- Evidence: `docs/plan/m2_layout.png`.

### Milestone 3 — breadboard realism (in progress)
- Done: 3D world moved into a `SubViewport` (MSAA 2×) inside a
  `SubViewportContainer`, so the workspace no longer sits behind the panels;
  picking uses `_work_pos()` (window → workspace-local).
- Done: holes read as recessed dark insets; red/blue rails are printed strips;
  centre trench is a recessed channel.
- Remaining: chamfered board edges, printed row/column and rail labels, curved
  coloured wires, placement preview + valid/invalid highlight, camera close-up
  preset.

### Milestone 4 — component models (done, first pass)
- Rewrote `scripts/components/component_factory.gd`: models are built in a local
  frame (origin at the pin mid-point, local +Z along pin 0 → pin N) so they always
  align with the real terminals.
- Models: resistor (with real 4-band colour code computed from the value),
  ceramic capacitor, inductor (coil rings), potentiometer, battery/current source,
  ground symbol, switch (lever reflects open/closed state), **LED (emissive dome
  that lights with forward current)**, diode/zener (cathode band), logic gates
  (DIP body + function marking), silver pin pads, and a selection highlight.
- Live data (params, current, voltage, switch state) flows in via the `info`
  argument from `_rebuild_3d()`.
- Evidence: `docs/plan/m4_components.png`, `docs/plan/m4_led_on.png` (LED lit at
  9.73 mA; resistor shows orange-orange-brown = 330 Ω).
- Regression: **248 / 248 tests pass**, headless load exits 0.

### Verification habit (per milestone)
1. `godot --headless --script res://tests/run_tests.gd` → must stay 248/248.
2. `godot --headless --quit-after 90` → exit 0 (no parse/runtime errors).
3. Launch windowed, load an example, screenshot into `docs/plan/`.

## 4. Component implementation status vocabulary

Every catalog entry gains:

```json
"simulation_status": "full" | "partial" | "visual",
"simulation_models": ["ohmic", "nonlinear-diode", ...],
"simulation_backend": "" | "mna" | "gpio" | "mcu-avr",
"notes": "free text shown in the inspector and returned over MCP"
```

- **full** — the solver produces real voltages/currents for it.
- **partial** — simulated with documented simplifications (e.g. ideal switch,
  fixed-threshold logic).
- **visual** — appears in 3D and can be wired, but has no electrical model yet;
  clearly labelled and never reported as working.

## 5. Baseline preservation

Git history is the recovery mechanism. The pre-upgrade state is commit `5333270`
("M10: AI-native MCP integration"). A visual baseline screenshot is stored at
`docs/plan/baseline_ui.png`.
