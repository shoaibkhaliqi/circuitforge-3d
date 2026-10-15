# Feature Matrix

Evidence labels: **confirmed** / **inferred** / **unknown** (see `dossier.md`).

| Feature | Evidence | Planned implementation | Test method |
|---|---|---|---|
| 3D workbench | Confirmed (official site: "Fully realised in 3D", workbench metaphor) | Independent Godot 4 3D scene, orbit/pan/zoom camera, placement grid | Interaction tests (camera orbit/pan/zoom, place/move/rotate) |
| Breadboard | Inferred (workbench metaphor implies solderless board) | Explicit electrical graph: 5-hole terminal groups, centre channel, configurable power rails | Connectivity tests over the graph (not the visuals) |
| DC simulation | Confirmed (real-time circuit simulator) | Modified Nodal Analysis, Gaussian elimination with partial pivoting | Analytical calculations (Ohm, divider, parallel, KCL, KVL) |
| Transient simulation | Confirmed (real-time simulation) / inferred (method unknown) | Backward-Euler companion models for C and L | Known RC waveform `5(1-e^{-t/0.1})`; RL curve |
| Oscilloscope | Confirmed (scope, up to 4 traces) | Simulation-backed 2+ channel scope with real recorded samples | Waveform data tests against solver output |
| Multimeter | Inferred (instruments implied; not explicitly listed) | DC V / I meters with documented 1 MΩ input impedance | Compare meter reading vs solver node/branch values |
| Digital logic | Confirmed (logic, timers, counters, memory) | Boolean gates + flip-flops/counters with defined logic-level voltages | Truth-table tests |
| Microcontroller | Confirmed (programmable MCU, code editor) | Advanced phase; no compatibility claimed without real execution | Documented as future work until a real core exists |
| Project persistence | Confirmed (examples) / unknown (format) | Versioned JSON schema with validation + migration | Save → reload → re-simulate equality tests |
| Component catalogue | Confirmed (long public list) | Data-driven definitions, implemented in order of simulation importance | Unit tests per model |
| Visualisation (V/I in wires) | Confirmed | Node-voltage labels, branch-current labels, direction arrows | Displayed values compared to solver |
| Dark mode / lighting | Confirmed | Adjustable environment lighting toggle | Manual graphical check |
| Localization | Confirmed (English interface) | English first-run | Manual |
| Offline operation | Inferred (no cloud in minimum spec) | All features work with no network | Firewall/offline launch test |
