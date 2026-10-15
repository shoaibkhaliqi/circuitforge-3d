# Research Dossier — CRUMB Circuit Simulator (public information only)

> Scope: this dossier records only publicly observable information gathered from the
> official website (`https://www.crumbsim.com/`) and the Steam product page
> (`https://store.steampowered.com/app/2198800/`), plus widely known electronics
> engineering practice. It is used to *understand the class of product*, not to copy
> code or assets. CircuitForge 3D is an independent implementation with original
> design, artwork and code.

Evidence labels: **confirmed** (stated on an official public source),
**inferred** (reasonable reading of public material), **unknown** (not publicly documented).

## 1. Main interface and workflow
- Multi-platform desktop application (Windows, macOS) and mobile (iOS, Android). **confirmed**
- "Fully realised in 3D"; the user constructs circuits "as you would at the workbench",
  i.e. a 3D scene with a breadboard-like work surface. **confirmed**
- Ships with several built-in example circuits. **confirmed**
- A built-in Code Editor and Hex Editor exist for the programmable microcontroller. **confirmed**

## 2. Component categories (from the public component list)
- Passives: resistors, capacitors, inductors. **confirmed**
- Switches: tactile, slide, DIP. **confirmed**
- Semiconductors: diodes, BJT transistors, MOSFETs, SCRs. **confirmed**
- LEDs, transducers, seven-segment displays. **confirmed**
- LCD and TFT displays. **confirmed**
- DC power and signal generators. **confirmed**
- Integrated circuits: basic/complex logic, timers, counters, memory, EEPROM, op-amps. **confirmed**
- Fully programmable microcontroller. **confirmed**

## 3. 3D placement and manipulation
- Components are placed into a 3D scene and connected. **inferred** (standard for the genre
  and implied by "construct prototype circuits as you would at the workbench").
- Exact camera controls, snapping behaviour, and placement rules are **unknown**.

## 4. Breadboard and wire behaviour
- A physical-workbench metaphor implies a solderless breadboard with a central channel and
  power rails. **inferred**
- Exact hole-to-hole continuity rules, rail splits and wire mechanics are **unknown**.
- CircuitForge therefore implements the *standard*, documented solderless-breadboard topology
  (see `docs/architecture/architecture.md`) rather than guessing at CRUMB internals.

## 5. Circuit simulation features
- Real-time simulation is claimed ("Powerful Realtime 3D Electronic Circuit Simulator"). **confirmed**
- The numerical method is not publicly documented. **unknown**
- CircuitForge independently implements Modified Nodal Analysis (MNA): DC operating point,
  transient (backward Euler) and nonlinear (Newton–Raphson) analysis.

## 6. Instruments and waveform visualisation
- Built-in scope supporting up to 4 components/traces. **confirmed**
- Visualisation tools: view current and voltage in wires, logic output at pins, highlight pin
  labels and anodes of polarised components, and a dark/lit scene toggle. **confirmed**
- Multimeter presence is **inferred** from the generic "instruments" claim but not explicitly
  listed; CircuitForge includes one regardless.

## 7. Digital logic and programmable devices
- Large IC catalogue with basic and complex logic, timers, counters, memory, EEPROM. **confirmed**
- A fully programmable microcontroller with an editable code editor. **confirmed**
- The specific MCU, its instruction set, toolchain and licensing are **unknown**.
- CircuitForge treats MCU support as an advanced phase and does not claim AVR/Arduino
  compatibility unless real firmware execution is implemented (see architecture doc).

## 8. Project management
- Built-in examples exist. **confirmed**
- Save/load file format, versioning and cloud features are **unknown**.
- CircuitForge defines its own documented, versioned JSON project format.

## 9. Performance and UX
- Minimum spec: 64-bit OS, Intel Core i3, 4 GB RAM, integrated graphics, 1 GB storage. **confirmed**
- This confirms the design goal: run acceptably on modest hardware.

## 10. Uncertain / not publicly documented
- Exact solver algorithm, internal file format, breadboard wiring model, MCU architecture,
  save-system details, and full instrument feature set are all **unknown**.
  CircuitForge does not attempt to mirror these; it implements correct, well-documented
  engineering equivalents.
