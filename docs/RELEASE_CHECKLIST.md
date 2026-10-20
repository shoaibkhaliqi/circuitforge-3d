# Release Checklist (Updated)

## Verification Performed This Session

### Build & Launch
- [x] Reproducible build from documented instructions (Godot 4.7.2)
- [x] Application launches and closes successfully (headless exit 0)
- [x] Windows export successful → build/windows/CircuitForge3D.exe (109 MB)
- [x] MCP server starts and stops cleanly

### Tests
- [x] Complete test suite: 1392/1392 passed
- [x] MCP integration tests (real protocol, real engine): 29/29 passed
- [x] Component catalog validation: 0 errors
- [x] Development boards: all 20 boards verified (documented pinouts, `board_info`
      identity, per-board electrical terminal + save/load tests, honest firmware
      capability split) - see `docs/boards_status.md`
- [x] No TODO/FIXME/HACK in codebase
- [x] No secrets/credentials committed

### Security (Offline)
- [x] Project paths sandboxed to approved roots
- [x] MCP inputs validated with stable error codes
- [x] Optimistic concurrency via revision checks
- [x] External processes run with timeouts
- [x] No arbitrary shell execution through MCP
- [x] Local API binds to loopback by default
- [ ] Network-based vulnerability scan (BLOCKED — no network)

### Platform
- [x] Windows: Built, launched, functionally tested, packaged
- [ ] Linux Mint: ELF-validated only (BLOCKED — no Linux/WSL environment)

### Performance
- [ ] NOT TESTED on minimum hardware (no target hardware available)

### Documentation
- [x] Known limitations published
- [x] Security review published
- [x] Production readiness plan/report published
- [x] Release checklist published

## Release Gates: 15/17 PASS, 1 BLOCKED, 1 NOT TESTED
Status: CONDITIONALLY READY

### Remaining Blockers
1. Linux runtime verification (BLOCKED — no Linux environment)
2. Security vulnerability scan (BLOCKED — no network)
3. Performance on minimum hardware (NOT TESTED — no target hardware)
