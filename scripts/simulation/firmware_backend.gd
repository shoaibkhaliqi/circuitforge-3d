extends RefCounted
## Optional, external firmware backend (M7 Stage B, open loop).
##
## Runs a *compiled* Arduino Intel-HEX on avr8js (MIT) through Node and returns
## the digital pin transitions. It never touches the solver, and it is entirely
## optional: if Node or the harness is missing, `capabilities()` says so and every
## call fails clearly instead of pretending firmware works.
##
## Design constraints (see docs/plan/m7_firmware_backend.md):
## - The engine is MIT; nothing GPL is vendored. Node is an external tool.
## - AVR / Arduino only for now. Digital pins only; no analog or ADC feedback.
## - The Godot test suite must stay runnable without Node, so the node-backed path
##   is only exercised on demand.

const HARNESS_REL := "res://firmware/harness/run.mjs"
const ENGINE := "avr8js"
const ENGINE_LICENSE := "MIT"
const BOARDS := ["arduino:avr:uno", "arduino:avr:nano"]
const MIN_MS := 1
const MAX_MS := 10000
const MAX_SERIAL_CHARS := 20000

static var _probed: bool = false
static var _node: String = ""


static func harness_path() -> String:
	return ProjectSettings.globalize_path(HARNESS_REL)


static func find_node() -> String:
	if _probed:
		return _node
	_probed = true
	var override := OS.get_environment("CIRCUITFORGE_NODE")
	if not override.is_empty():
		var out_env := []
		if OS.execute(override, ["--version"], out_env, false) == 0:
			_node = override
			return _node
	var out := []
	if OS.execute("node", ["--version"], out, false) == 0:
		_node = "node"
	return _node


static func capabilities() -> Dictionary:
	var node := find_node()
	var harness := harness_path()
	var harness_ok := FileAccess.file_exists(harness)
	var reasons := []
	if node.is_empty():
		reasons.append("Node.js not found on PATH (set CIRCUITFORGE_NODE to point at it)")
	if not harness_ok:
		reasons.append("harness missing: " + HARNESS_REL)
	return {
		"available": node != "" and harness_ok,
		"engine": ENGINE,
		"engine_license": ENGINE_LICENSE,
		"node": node,
		"harness": harness,
		"boards": BOARDS,
		"stage": "open-loop (B): firmware drives digital pins; no analog/ADC feedback",
		"max_ms": MAX_MS,
		"unavailable_reasons": reasons,
	}


## Normalise a firmware pin key ("13", "D13", "A0") to the Arduino digital number,
## or -1 if it is not a recognised pin.
static func pin_number(key) -> int:
	var s := String(key).strip_edges().to_upper()
	if s.begins_with("D"):
		s = s.substr(1)
	elif s.begins_with("A"):
		var a := int(s.substr(1))
		if a >= 0 and a <= 7:
			return 14 + a
	if s.is_valid_int():
		return int(s)
	return -1


static func label(pin: int) -> String:
	if pin >= 14 and pin <= 21:
		return "A%d" % (pin - 14)
	return "D%d" % pin


## Run a compiled HEX for `ms` of emulated time. Returns the harness JSON:
## { ok, mcu, f_cpu, ms, cycles, transitions: [{t_ms, port, bit, digital_pin, level}] }.
static func run_hex(hex_path: String, ms: int = 2000) -> Dictionary:
	var cap := capabilities()
	if not bool(cap["available"]):
		return {"ok": false, "error": "firmware backend unavailable",
			"reasons": cap["unavailable_reasons"]}
	if not FileAccess.file_exists(hex_path):
		return {"ok": false, "error": "firmware file not found: " + hex_path}
	var dur := clampi(ms, MIN_MS, MAX_MS)
	var out := []
	var code := OS.execute(String(cap["node"]), [String(cap["harness"]), hex_path, str(dur)], out, false)
	if code != 0:
		return {"ok": false, "error": "firmware harness exited with code %d" % code}
	var text := "" if out.is_empty() else String(out[0])
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "firmware harness produced unparseable output"}
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "error": String(parsed.get("error", "firmware harness error"))}
	return parsed


## Pin -> level map at emulated time `t_ms`, from a transition list. Pins that
## only change after `t_ms` are reported LOW (the Arduino power-on default).
static func levels_at(transitions: Array, t_ms: float) -> Dictionary:
	var sorted := transitions.duplicate()
	sorted.sort_custom(func(a, b): return float(a.get("t_ms", 0.0)) < float(b.get("t_ms", 0.0)))
	var levels := {}
	for tr in sorted:
		if typeof(tr) != TYPE_DICTIONARY:
			continue
		var dp = tr.get("digital_pin", null)
		if dp == null:
			continue
		var pin := int(dp)
		if not levels.has(pin):
			levels[pin] = 0
		if float(tr.get("t_ms", 0.0)) > t_ms + 1e-9:
			break
		levels[pin] = int(tr.get("level", 0))
	return levels


## Split captured UART output into non-empty lines (handles CRLF or LF).
static func serial_lines(text: String) -> Array:
	var out := []
	for line in text.replace("\r\n", "\n").split("\n"):
		if not String(line).is_empty():
			out.append(line)
	return out


## Cap returned serial text so a chatty sketch cannot flood an API/MCP response.
static func truncate_serial(text: String) -> String:
	if text.length() <= MAX_SERIAL_CHARS:
		return text
	return text.substr(0, MAX_SERIAL_CHARS) + "\n... [serial truncated]"


static func pins_touched(transitions: Array) -> Array:
	var seen := {}
	for tr in transitions:
		if typeof(tr) != TYPE_DICTIONARY:
			continue
		var dp = tr.get("digital_pin", null)
		if dp != null:
			seen[int(dp)] = true
	var pins := seen.keys()
	pins.sort()
	return pins
