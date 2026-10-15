# Dependency & Asset License Inventory

CircuitForge 3D is an independent implementation. It contains **no** third-party
proprietary source code, no extracted protected assets and no CRUMB branding.

| Dependency / asset | Version | License | Use |
|---|---|---|---|
| Godot Engine | 4.7.2 stable | MIT | Runtime + editor |
| GDScript standard library | bundled | MIT (Godot) | Language/runtime |
| `icon.svg` (project icon) | — | Original, MIT (this project) | Application icon |
| All `scripts/`, `scenes/`, `data/`, `assets/` | — | Original, MIT (this project) | Application |
| JSON | RFC 8259 | — | Data format only |

No textures shipped: all materials use flat `StandardMaterial3D` colours and generated
primitives. No external font files: the default Godot font is used.

If a microcontroller toolchain is added in a future phase, its licence and version must be
recorded here before it is made a dependency. The base simulator must keep working when
any such toolchain is absent.
