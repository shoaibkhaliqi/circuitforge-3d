# Visual / performance measurement — CircuitForge 3D workbench

Measured on the development machine (Windows 11, Godot 4.7.2 Forward+, 1280x720
window, vsync on), using the app's built-in measurement flag:

```
godot --path . --resolution 1280x720 -- --fps-report=3 res://data/examples/01_led_resistor.cf3d
godot --path . --resolution 1280x720 -- --fps-report=3 --stress=200
```

`--fps-report` builds the scene (optionally with a synthetic stress circuit:
resistors at every second row of all ten columns plus one cross-board wire per
row), times one full 3D rebuild, then averages real rendered FPS over the
requested window and dumps CPU/GPU frame statistics, then quits. It refuses to
give meaning to headless runs — it must be run windowed.

## Results (October 2026)

| Scene                        | Parts           | FPS avg (min) | Rebuild 3D | Primitives/frame | Draw calls |
|------------------------------|-----------------|---------------|------------|------------------|------------|
| `01_led_resistor.cf3d`       | 4 comp + 1 wire | 60.4 (59.8)   | 21 ms      | 424,872          | 380        |
| Stress circuit               | 150 + 30 wires  | 58.5 (56.1)   | 117 ms     | 2,392,082        | 8,989      |

## Interpretation

- Both sizes hold vsync rate (~60 FPS). A full breadboard full of resistors is
  comfortably interactive with SSAO/Filmic/MSAA-2x enabled.
- The one-time 3D rebuild cost grows with part count (~0.7 ms/part here). It is
  a single hiccup per edit/simulation refresh, not per frame; visible as a
  short stutter on huge circuits only.
- CPU frame budget (`process_ms_per_frame`) stays around 18-25 ms in the stress
  scene — the target if an optimization round is ever needed is lowering
  draw calls (currently ~60 per component due to per-part primitives +
  materials); sharing materials or MultiMesh-ing leads would roughly halve it.
- Rendering quality flags in place: MSAA 2x, SSAO (radius 0.12), Filmic tonemap;
  all measured within budget at these scales.

## Reproducing

Run the app windowed (never `--headless`, which skips rendering), any of:

```
--fps-report=3 <project.cf3d>       # measure a saved circuit
--fps-report=3 --stress=200        # synthetic full-breadboard stress circuit
--fps-report=1 --stress=200 --screenshot=out.png   # also capture the scene
```

The report line is printed as `fps-report result: {...}` JSON to stdout.
