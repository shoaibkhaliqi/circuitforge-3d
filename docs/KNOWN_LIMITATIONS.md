# Known Limitations

1. **Linux runtime unverified** — binary is ELF-validated only; no Linux/WSL available for runtime testing.
2. **No macOS/Android/Web export** in this release.
3. **Sequential logic is level/state-based** — D flip-flops, shift registers, and counters are modeled as simplified stateful MNA elements (no setup/hold timing or propagation delay).
4. **Op-amps are ideal VCVS** — saturation to supply rails is modeled; no frequency response, slew rate, or offset.
5. **Transistors are simplified** — BJT uses an Ebers-Moll-like model; MOSFET/switch parts are on/off resistors; no capacitance or detailed active-region modeling.
6. **Firmware requires Node.js** — optional external dependency; Godot suite runs without it.
7. **Firmware is AVR-only** — ESP32, STM32, RP2040 not supported.
8. **No real-time simulation** — DC/transient only, no real-time clock.
9. **Development boards are pinout/external-terminal models** — 20 boards are implemented as documented pinouts and external terminals; only ATmega328P-based boards (Uno R3, Nano, Pro Mini) are firmware-capable via the optional AVR backend, and no board CPU/OS is simulated.
10. **Connectors, parallel LCD, and external sensors/actuators** are visual/backend-driven rather than electrically simulated.
11. **Performance on minimum hardware** not yet measured.
12. **WS2812B and PMS5003** are decoded from firmware pin transitions / UART bytes; they have no breadboard electrical model.
