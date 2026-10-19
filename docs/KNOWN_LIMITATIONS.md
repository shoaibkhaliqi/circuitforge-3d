# Known Limitations

1. **Linux runtime unverified** — binary is ELF-validated only; no Linux/WSL available for runtime testing.
2. **No macOS/Android/Web export** in this release.
3. **Logic is combinational only** — no sequential logic (flip-flops, counters, shift registers) in the MNA solver; modeled as partial with state.
4. **Op-amps are ideal VCVS** — no frequency response, slew rate, or offset.
5. **Transistors are switch models** — no active-region, gain, or capacitance modeling.
6. **Firmware requires Node.js** — optional external dependency; Godot suite runs without it.
7. **Firmware is AVR-only** — ESP32, STM32, RP2040 not supported.
8. **No real-time simulation** — DC/transient only, no real-time clock.
9. **20 development boards** are metadata-only (pinouts, no simulation).
10. **Connectors and parallel LCD** are visual-only.
11. **Performance on minimum hardware** not yet measured.
