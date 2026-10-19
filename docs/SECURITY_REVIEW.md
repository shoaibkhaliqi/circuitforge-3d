# Security Review

## Scope
- Project file loading (JSON schema validation, path sandboxing)
- MCP server (stdio transport, input validation, revision checks)
- External process execution (Node.js for firmware, arduino-cli)
- File system access

## Findings
- Project paths are sandboxed to approved roots.
- MCP inputs validated with stable error codes.
- Optimistic concurrency via revision checks.
- External processes run with timeouts.
- No arbitrary shell execution through MCP.
- Local API binds to loopback by default.

## Not Tested
- Network-based vulnerability scan (no network access available).
- Penetration testing of MCP transport.
- Fuzzing of project file parser.

## Residual Risks
- Firmware backend executes user-compiled HEX via Node.js; user is responsible for sketch content.
- No authentication on local API (loopback-only by design).
- Project files are JSON; malformed input handled with error messages but not fuzz-tested.
