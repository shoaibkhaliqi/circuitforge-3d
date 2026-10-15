# Risk Register

| ID | Risk | Likelihood | Impact | Mitigation | Status |
|---|---|---|---|---|---|
| R1 | No Godot binary present | Med | High | Found Godot 4.7.2 at `D:\tmpsoft\gadot`; pin version | Closed |
| R2 | Dev host is Windows, spec asks for Linux Mint | High | Med | Build cross-platform; verify Windows; document Linux export + steps; do not claim untested Linux support | Open (documented) |
| R3 | C: drive nearly full (1.7 GB) | Med | Med | Keep project + export output on `D:` (169 GB free) | Mitigated |
| R4 | Solver numerically unstable | Med | High | Analytical unit tests, pivot threshold, partial pivoting, Newton damping | Mitigated |
| R5 | GUI untestable headlessly | Med | Med | Keep solver/instrument logic in pure scripts; headless unit tests + manual GUI checks | Mitigated |
| R6 | Scope creep (MCU, displays) | High | Med | Deliver working subsets; document remaining work | Managed |
| R7 | Fabricated "passing" claims | Med | High | Only mark tests passed when executed; capture real output | Controlled |
| R8 | Export templates not installed | Med | Med | Attempt export; if missing, document exact install step | Open |
