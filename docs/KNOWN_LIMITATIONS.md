# Known Limitations

1. **Linux runtime unverified** — binary is ELF-validated only; no Linux/WSL available for runtime testing.
2. **No macOS/Android/Web export** in this release.
3. **Sequential logic is level/state-based** — D flip-flops, shift registers, and counters are modeled as simplified stateful MNA elements (no setup/hold timing or propagation delay).
4. **Op-amps are ideal VCVS** — saturation to supply rails is modeled; no frequency response, slew rate, or offset.
5. **Transistors are simplified** — BJT uses an Ebers-Moll-like model; MOSFET/switch parts are on/off resistors; no capacitance or detailed active-region modeling.
6. **Firmware requires Node.js** — optional external dependency; Godot suite runs without it.
7. **Firmware is AVR-only** — ESP32, STM32, RP2040 not supported.
8. **No real-time simulation** — DC/transient only, no real-time clock.
9. **Development boards are pinout/external-terminal models** — 20 boards are implemented as documented pinouts, documented identity (`board_info`: MCU, logic level, USB, programming, fixed interface mappings) and external terminals; only ATmega328P-based boards (Uno R3, Nano, Pro Mini) are firmware-capable via the optional AVR backend, and no board CPU/OS is simulated.
10. **Connectors, parallel LCD, and external sensors/actuators** are visual/backend-driven rather than electrically simulated.
11. **Performance on minimum hardware** not yet measured (see `docs/plan/visual_performance.md` for one developer-machine baseline: ~60 FPS at a 150-part stress circuit; rebuild ~117 ms once per edit on that size).
12. **WS2812B and PMS5003** are decoded from firmware pin transitions / UART bytes; they have no breadboard electrical model.
13. **3D visuals are procedural approximations** — recognisable packages at real proportions (5 mm LED, 1/4 W resistor, electrolytic cans, DIP with pin-1 dot), but no textures/photo-realism, no animated IC marking, and board silkscreens/labels are simplified. See `docs/plan/screenshots/`.
14. **Wire routing bends over holes** — arcs span terminal to terminal with a fixed lift; no collision-aware routing, junction dots, or per-wire bend editing.
15. **Net highlight is pointer-driven** — no keyboard-only navigation of the 3D board, and highlight colours are fixed (no optional voltage-scale colouring yet).
16. **Library icons are text + status dot** — no rendered component thumbnails.
17. **Placement validation is occupancy-only** — the ghost turns red on occupied/invalid holes and the netlist warns on accidental shorts, but leads are not collision-checked against other components' bodies.
