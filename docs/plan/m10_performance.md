# M10 performance / component-count pass

Measured, not asserted. Reproduce with:

```
godot --headless --path . --script res://tools/bench.gd
```

The guard that fails a build if this ever blows up lives in
`tests/solver/test_scale.gd` (budget 5 s, deliberately generous for a slow machine);
this file records what the numbers actually look like so a change can be judged
against them rather than against a feeling.

Measured on Windows, Godot 4.7.2 (headless), one run each. Treat them as orders of
magnitude, not as a benchmark to hold to the millisecond.

## Solver only — resistor ladder (nodes are the variable)

A source, `n` series 100 Ω resistors and a 100 Ω load; 10 V.

| nodes `n` | elements | DC solve |
| --- | --- | --- |
| 200 | 202 | 15.7 ms |
| 400 | 402 | 62.5 ms |
| 800 | 802 | 241.7 ms |

Cost roughly quadruples per doubling of the node count, i.e. it tracks O(n²) for this
banded ladder (dense LU is O(n³) in the worst case; the fill-in stays small here). No
blow-up, and the existing 200-node case is unchanged from the ~14 ms recorded when the
test was added.

## Whole pipeline — dense breadboard project (component count is the variable)

The point of this pass: the ladder above stresses the *matrix*, not the app. A dense
project is wired through the real path (component catalogue → breadboard nets → netlist
builder → DC solve). Each of the `k` branches is a 220 Ω resistor from the supply rail
to its own column and a LED from that column to ground — 2k + 2 components, k + 2 nets,
a *nonlinear* solve because of the LEDs, exactly as a real board is.

| branches `k` | components | netlist build | DC solve |
| --- | --- | --- | --- |
| 25 | 52 | 6.8 ms | 8.5 ms |
| 50 | 102 | 11.1 ms | 22.3 ms |
| 100 | 202 | 21.6 ms | 73.3 ms |
| 200 | 402 | 43.2 ms | 257.0 ms |

Netlist build is linear in the component count (≈0.1 ms per component, dominated by
breadboard net resolution). The solve grows faster, as an MNA solve must, but 400
components with 100 LEDs still lands at a quarter of a second — interactive for a
build-and-run loop, and two orders of magnitude inside the suite's 5 s guard.

## What this pass established

- The app's own pipeline, not just the solver, is measured at component scale.
- Nothing here is quadratic in the *component* count beyond the matrix itself: wiring
  a big board is cheap, and the solver is the cost, which is where it belongs.
- The scale test now covers both variables (nodes and components) and fails loudly if
  either regresses past a budget a slow machine can still meet.
