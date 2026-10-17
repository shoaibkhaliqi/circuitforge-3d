extends RefCounted
## Optional, external firmware backend (M7 Stage B).
##
## Runs a *compiled* Arduino Intel-HEX on avr8js (MIT) through Node and returns
## the digital pin transitions, UART output and I2C/SPI bus activity. Firmware can
## also *read* bus devices and the solved ADC node voltages. It never raises an
## optional failure into the solver, and it is entirely optional: if Node or the
## harness is missing, `capabilities()` says so and every call fails clearly
## instead of pretending firmware works.
##
## Design constraints (see docs/plan/m7_firmware_backend.md):
## - The engine is MIT; nothing GPL is vendored. Node is an external tool.
## - AVR / Arduino only for now. Digital pins, UART, I2C/SPI; ADC inputs can be fed
##   from the solved circuit, but firmware output does not drive the analog circuit.
## - The Godot test suite must stay runnable without Node, so the node-backed path
##   is only exercised on demand.

const HARNESS_REL := "res://firmware/harness/run.mjs"
const ENGINE := "avr8js"
const ENGINE_LICENSE := "MIT"
const BOARDS := ["arduino:avr:uno", "arduino:avr:nano"]
const MIN_MS := 1
const MAX_MS := 10000
const MAX_SERIAL_CHARS := 20000
const MAX_BUS_EVENTS := 2000

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
		"stage": "Stage B: firmware drives digital pins and bus devices, and reads solved ADC inputs; no analog output feedback",
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
## `devices` is an optional list of bus devices the firmware can talk to, e.g.
## [{"kind": "pcf8574", "address": 39, "state": 0, "inputs": 15}], passed to the
## harness so the firmware can *read* them (device -> firmware feedback).
## `adc` maps ADC channel -> volts (e.g. {0: 2.5}) so analogRead() sees a voltage
## (circuit -> firmware analog feedback).
static func run_hex(hex_path: String, ms: int = 2000, devices: Array = [], adc: Dictionary = {}) -> Dictionary:
	var cap := capabilities()
	if not bool(cap["available"]):
		return {"ok": false, "error": "firmware backend unavailable",
			"reasons": cap["unavailable_reasons"]}
	if not FileAccess.file_exists(hex_path):
		return {"ok": false, "error": "firmware file not found: " + hex_path}
	var dur := clampi(ms, MIN_MS, MAX_MS)
	var env_dev := _with_env("CF_DEVICES", JSON.stringify(devices) if not devices.is_empty() else "")
	var env_adc := _with_env("CF_ADC", JSON.stringify(adc) if not adc.is_empty() else "")
	var out := []
	var code := OS.execute(String(cap["node"]), [String(cap["harness"]), hex_path, str(dur)], out, false)
	_restore_env("CF_DEVICES", env_dev)
	_restore_env("CF_ADC", env_adc)
	if code != 0:
		return {"ok": false, "error": "firmware harness exited with code %d" % code}
	var text := "" if out.is_empty() else String(out[0])
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "firmware harness produced unparseable output"}
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "error": String(parsed.get("error", "firmware harness error"))}
	return parsed


## Set an environment variable for a child process; returns the previous state so
## it can be restored. Passing "" unsets it for the child.
static func _with_env(key: String, value: String) -> Dictionary:
	var had := OS.has_environment(key)
	var prev := OS.get_environment(key) if had else ""
	if value == "":
		OS.unset_environment(key)
	else:
		OS.set_environment(key, value)
	return {"had": had, "prev": prev}


static func _restore_env(key: String, state: Dictionary) -> void:
	if bool(state.get("had", false)):
		OS.set_environment(key, String(state.get("prev", "")))
	else:
		OS.unset_environment(key)


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


## Sorted unique I2C slave addresses ("0x27") seen in a TWI trace.
static func i2c_addresses(events: Array) -> Array:
	var seen := {}
	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var a = e.get("address", null)
		if a == null:
			continue
		seen[int(a)] = true
	var out := []
	for a in seen.keys():
		out.append("0x%02X" % int(a))
	out.sort()
	return out


## The first byte firmware read from `address` (or -1 if none). For a device that
## serves data on read (e.g. a PCF8574 whose port bits are externally held low),
## this is what the firmware saw.
static func last_i2c_read_byte(events: Array, address: int) -> int:
	var byte := -1
	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if int(e.get("address", -1)) != address:
			continue
		if bool(e.get("write", false)):
			continue
		var bytes: Array = e.get("bytes", [])
		if bytes.is_empty():
			continue
		byte = int(bytes[0])
	return byte


## The last data byte the firmware wrote to `address` (or -1 if none). For a
## PCF8574-style write this is the final port byte.
static func last_i2c_write_byte(events: Array, address: int) -> int:
	var byte := -1
	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if int(e.get("address", -1)) != address:
			continue
		if not bool(e.get("write", false)):
			continue
		var bytes: Array = e.get("bytes", [])
		if bytes.is_empty():
			continue
		byte = int(bytes[bytes.size() - 1])
	return byte


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
