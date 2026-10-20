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
const BOARDS := ["arduino:avr:uno", "arduino:avr:nano", "arduino:avr:pro"]
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
		"stage": "Stage B: firmware drives digital pins and bus devices, reads solved ADC inputs, and pin sensors drive MCU inputs; no analog output feedback",
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
	if hex_path.begins_with("res://") or hex_path.begins_with("user://"):
		hex_path = ProjectSettings.globalize_path(hex_path)
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


## Duty cycle (0..1) the firmware drove on digital `pin`, or -1 if that pin was not
## toggling fast enough to be PWM. `pwm` is the harness `pwm` summary.
static func pwm_duty(pwm: Dictionary, pin: int) -> float:
	if typeof(pwm) != TYPE_DICTIONARY:
		return -1.0
	var e = pwm.get(str(pin), pwm.get(pin, null))
	if typeof(e) != TYPE_DICTIONARY:
		return -1.0
	if not e.has("duty"):
		return -1.0
	return clampf(float(e.get("duty", 0.0)), 0.0, 1.0)


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


## High-pulse widths (microseconds) the firmware drove on digital `pin`, in order, from
## a transition list. A pulse starts on a rising edge and is the time until the next
## falling edge; widths below `min_us` are dropped as glitches and above `max_us` are
## ignored (a stuck-high pin is not a pulse). This is a hobby servo's control signal.
static func pulse_widths(transitions: Array, pin: int, min_us := 50.0, max_us := 30000.0) -> Array:
	var widths := []
	var rise := -1.0
	for tr in transitions:
		if typeof(tr) != TYPE_DICTIONARY:
			continue
		if int(tr.get("digital_pin", -1)) != pin:
			continue
		var t := float(tr.get("t_ms", 0.0))
		if int(tr.get("level", 0)) == 1:
			rise = t
			continue
		if rise < 0.0:
			continue
		var us := (t - rise) * 1000.0
		rise = -1.0
		if us >= min_us and us <= max_us:
			widths.append(us)
	return widths


## Angle (degrees) a servo pulse of `width_us` commands: the pulse band
## [min_us, max_us] maps onto [0, range_deg], clamped (a servo given an out-of-band
## pulse drives to its end stop).
static func servo_angle(width_us: float, min_us := 544.0, max_us := 2400.0, range_deg := 180.0) -> float:
	if max_us <= min_us:
		return 0.0
	return clampf((width_us - min_us) / (max_us - min_us) * range_deg, 0.0, range_deg)


## Servo position the firmware commanded on `pin`: the pulse count, the last (and
## widest/narrowest) widths in microseconds, and the angle the last pulse encodes.
## `pulses` is 0 when the firmware never drove a pulse, and then `angle_deg` is -1.
static func servo_position(transitions: Array, pin: int, min_us := 544.0, max_us := 2400.0,
		range_deg := 180.0) -> Dictionary:
	var widths := pulse_widths(transitions, pin)
	if widths.is_empty():
		return {"pulses": 0, "last_us": 0.0, "min_us_seen": 0.0, "max_us_seen": 0.0, "angle_deg": -1.0}
	var lo := float(widths[0])
	var hi := float(widths[0])
	for w in widths:
		lo = minf(lo, float(w))
		hi = maxf(hi, float(w))
	var last := float(widths[widths.size() - 1])
	return {
		"pulses": widths.size(),
		"last_us": last,
		"min_us_seen": lo,
		"max_us_seen": hi,
		"angle_deg": servo_angle(last, min_us, max_us, range_deg),
	}


## Steps a STEP/DIR stepper driver was pulsed: every rising edge on `step_pin` counts one
## step, taken in the direction the `dir_pin` level named at that instant (starting from
## the reset state, all pins low). `dir_pin` may be -1 when the board only drives STEP,
## and then every step counts forward. `forward`/`reverse` split the total.
static func stepper_steps(transitions: Array, step_pin: int, dir_pin := -1,
		dir_high_forward := true) -> Dictionary:
	var steps := 0
	var forward := 0
	var reverse := 0
	var level := 0
	var dir_level := 0
	if step_pin < 0:
		return {"steps": 0, "forward": 0, "reverse": 0, "last_dir": 0}
	for tr in transitions:
		if typeof(tr) != TYPE_DICTIONARY:
			continue
		var pin := int(tr.get("digital_pin", -1))
		var lvl := int(tr.get("level", 0))
		if pin == dir_pin:
			dir_level = lvl
			continue
		if pin != step_pin:
			continue
		if lvl == 1 and level == 0:
			var fwd: bool = true if dir_pin < 0 else (dir_level == 1 if dir_high_forward else dir_level == 0)
			steps += 1 if fwd else -1
			if fwd:
				forward += 1
			else:
				reverse += 1
		level = lvl
	return {"steps": steps, "forward": forward, "reverse": reverse, "last_dir": dir_level}


## Shaft angle (degrees, 0..360) a signed step count leaves a motor at. One full turn is
## `steps_per_rev * microsteps` steps, so a multi-turn move wraps — the *net* travel is
## the `steps` count itself.
static func stepper_angle(steps: float, steps_per_rev := 200.0, microsteps := 1.0) -> float:
	var full := steps_per_rev * maxf(1.0, microsteps)
	if full <= 0.0:
		return 0.0
	var frac := steps / full
	return (frac - floorf(frac)) * 360.0


## The eight drive patterns of a four-phase (ULN2003) stepper, in order, in units of a
## half step: bit 0 = phase 1. It contains the four one-coil "wave" patterns (indices
## 0,2,4,6) and the four two-coil full-step patterns (1,3,5,7), so one table decodes wave,
## full and half-step driving alike — each valid pattern change moves the rotor by the
## shortest number of half steps between the two entries (1 for half-step, 2 for wave and
## full-step driving), and a pattern change of 4 is a 180-degree jump with no defined
## direction.
const STEPPER_PHASE_CYCLE := [0b0001, 0b0011, 0b0010, 0b0110, 0b0100, 0b1100, 0b1000, 0b1001]


## Half steps a four-phase driver moved: `pins` are the four phase pins (IN1..IN4, -1 when
## unwired) and every valid pattern change is measured against `STEPPER_PHASE_CYCLE`.
## The harness reports one transition per changed bit, so transitions sharing a timestamp
## belong to a single port write and are grouped — otherwise a two-coil change (wave drive)
## would be seen as passing through an invalid pattern. A real all-coils-off pattern breaks
## the sequence (the next valid pattern simply restarts it, so nothing is counted across
## it), and a 180-degree jump is counted in `skipped` rather than guessed.
static func stepper_phases(transitions: Array, pins: Array) -> Dictionary:
	var idx_of := {}
	for i in 4:
		if i < pins.size() and int(pins[i]) >= 0:
			idx_of[int(pins[i])] = i
	var out := {"steps": 0, "changes": 0, "forward": 0, "reverse": 0, "skipped": 0, "last_pattern": 0}
	if idx_of.size() < 2:
		return out
	var events := []
	var pattern := 0
	var group_t := 0.0
	var have_group := false
	for tr in transitions:
		if typeof(tr) != TYPE_DICTIONARY:
			continue
		var pin := int(tr.get("digital_pin", -1))
		if not idx_of.has(pin):
			continue
		var t := float(tr.get("t_ms", 0.0))
		if have_group and not is_equal_approx(t, group_t):
			events.append(pattern)
		group_t = t
		have_group = true
		if int(tr.get("level", 0)) != 0:
			pattern |= 1 << int(idx_of[pin])
		else:
			pattern &= ~(1 << int(idx_of[pin]))
	if have_group:
		events.append(pattern)
	var last_idx := -1
	for pat in events:
		var idx := STEPPER_PHASE_CYCLE.find(int(pat))
		if idx < 0:
			last_idx = -1      # invalid pattern (e.g. all coils off): the sequence restarts
			out["skipped"] = int(out["skipped"]) + 1
			continue
		out["last_pattern"] = int(pat)
		if last_idx < 0:
			last_idx = idx
			continue
		var delta := idx - last_idx
		if delta > 4:
			delta -= 8
		elif delta < -4:
			delta += 8
		last_idx = idx
		if delta == 0:
			continue
		if absi(delta) == 4:
			out["skipped"] = int(out["skipped"]) + 1
			continue
		out["steps"] = int(out["steps"]) + delta
		out["changes"] = int(out["changes"]) + 1
		if delta > 0:
			out["forward"] = int(out["forward"]) + delta
		else:
			out["reverse"] = int(out["reverse"]) - delta
	return out


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


## Decode a WS2812B/NeoPixel single-wire bitstream from a transition list into
## per-LED GRB bytes. `pin` is the firmware digital pin driving DIN. A short high
## pulse (~0.4 us) is a 0, a long high pulse (~0.8 us) is a 1, and a low gap
## above 50 us is a reset/latch. 24 bits (GRB) make one LED.
##
## Returns the bits of the strip's CURRENT frame: a reset gap latches (and
## discards) the frame before it, so only the bits after the last reset are
## reported - the same semantics the AVR harness uses. Sub-us pulse widths need
## the cycle-precise `t_us` stamp; older capture files beware the 1 us grid of
## `t_ms` (it still decodes, just coarser).
static func ws2812_bits(transitions: Array, pin: int) -> Array:
	var trs := []
	for tr in transitions:
		if typeof(tr) != TYPE_DICTIONARY:
			continue
		if int(tr.get("digital_pin", -1)) != pin:
			continue
		trs.append(tr)
	trs.sort_custom(func(a, b): return _ws_time(a) < _ws_time(b))
	var latched := []   # completed frames (>= 24 bits), oldest first
	var seg := []       # bits of the frame currently being driven
	for i in range(1, trs.size()):
		var prev: Dictionary = trs[i - 1]
		var cur: Dictionary = trs[i]
		var prev_level := int(prev.get("level", 0))
		var cur_level := int(cur.get("level", 0))
		var width_us: float = _ws_time(cur) - _ws_time(prev)
		if cur_level == 1 and prev_level == 0:
			if width_us > 50.0:      # reset gap: latch and discard
				if seg.size() >= 24:
					latched.append(seg)
				seg = []
		elif cur_level == 0 and prev_level == 1:
			seg.append(1 if width_us >= 0.5 else 0)
	if latched.size() > 0:
		return latched[latched.size() - 1]
	return seg


static func _ws_time(tr: Dictionary) -> float:
	if tr.has("t_us"):
		return float(tr.get("t_us"))
	return float(tr.get("t_ms", 0.0)) * 1000.0


static func _ws2812_leds_from_bits(bits: Array) -> Array:
	var leds := []
	var off := 0
	while off + 24 <= bits.size():
		var v := 0
		for b in 24:
			v = (v << 1) | int(bits[off + b])
		leds.append({"g": (v >> 16) & 0xff, "r": (v >> 8) & 0xff, "b": v & 0xff})
		off += 24
	return leds


static func ws2812_leds(transitions: Array, pin: int) -> Array:
	return _ws2812_leds_from_bits(ws2812_bits(transitions, pin))


static func ws2812_decode(transitions: Array, pin: int) -> Dictionary:
	var bits := ws2812_bits(transitions, pin)
	return {"pin": pin, "bits": bits.size(), "leds": _ws2812_leds_from_bits(bits)}


static func ws2812_rgb(transitions: Array, pin: int) -> Array:
	return ws2812_leds(transitions, pin)


static func ws2812b_decode(transitions: Array, pin: int) -> Dictionary:
	return ws2812_decode(transitions, pin)


static func ws2812b_leds(transitions: Array, pin: int) -> Array:
	return ws2812_leds(transitions, pin)


static func decode_ws2812(transitions: Array, pin: int) -> Dictionary:
	return ws2812_decode(transitions, pin)


static func decode_ws2812b(transitions: Array, pin: int) -> Dictionary:
	return ws2812_decode(transitions, pin)


## Decode PMS5003 particulate-matter frames from a byte stream. `data` may be an
## Array/PackedByteArray of byte values, a raw String (char codes), or a hex
## string. Returns an Array of Dictionary frames with decoded fields and a
## checksum_ok flag. Each frame is 32 bytes: header 0x42 0x4D, length 0x001C,
## 26 bytes of payload, and a 2-byte checksum (sum of the first 30 bytes).
static func _pms_bytes(data) -> PackedByteArray:
	var out := PackedByteArray()
	if data is PackedByteArray:
		return data
	if data is Array:
		for v in data:
			out.append(int(v) & 0xff)
		return out
	if data is String:
		var s := String(data)
		# Hex string (spaces allowed) when it is all hex pairs.
		var hex := s.replace(" ", "").replace("\n", "").replace("\r", "").replace("\t", "")
		if hex.length() > 0 and hex.length() % 2 == 0:
			var allhex := true
			for i in hex.length():
				var c := hex.substr(i, 1)
				if not ("0123456789abcdefABCDEF".find(c) >= 0):
					allhex = false
					break
			if allhex:
				for i in range(0, hex.length(), 2):
					out.append(hex.substr(i, 2).hex_to_int())
				return out
		for i in s.length():
			out.append(s.unicode_at(i) & 0xff)
		return out
	return out


static func pms5003_decode(data) -> Array:
	var b := _pms_bytes(data)
	var frames := []
	var i := 0
	while i + 32 <= b.size():
		if int(b[i]) == 0x42 and int(b[i + 1]) == 0x4D:
			var length := (int(b[i + 2]) << 8) | int(b[i + 3])
			if length == 28:
				var csum := 0
				for j in 30:
					csum += int(b[i + j])
				var checksum := (int(b[i + 30]) << 8) | int(b[i + 31])
				var frame := {
					"header_ok": true,
					"length": length,
					"pm1_0_std": (int(b[i + 4]) << 8) | int(b[i + 5]),
					"pm2_5_std": (int(b[i + 6]) << 8) | int(b[i + 7]),
					"pm10_std": (int(b[i + 8]) << 8) | int(b[i + 9]),
					"pm1_0_env": (int(b[i + 10]) << 8) | int(b[i + 11]),
					"pm2_5_env": (int(b[i + 12]) << 8) | int(b[i + 13]),
					"pm10_env": (int(b[i + 14]) << 8) | int(b[i + 15]),
					"particles_0_3": (int(b[i + 16]) << 8) | int(b[i + 17]),
					"particles_0_5": (int(b[i + 18]) << 8) | int(b[i + 19]),
					"particles_1_0": (int(b[i + 20]) << 8) | int(b[i + 21]),
					"particles_2_5": (int(b[i + 22]) << 8) | int(b[i + 23]),
					"particles_5_0": (int(b[i + 24]) << 8) | int(b[i + 25]),
					"particles_10": (int(b[i + 26]) << 8) | int(b[i + 27]),
					"reserved": (int(b[i + 28]) << 8) | int(b[i + 29]),
					"checksum": checksum,
					"checksum_calc": csum & 0xffff,
					"checksum_ok": (csum & 0xffff) == checksum,
				}
				# Common short aliases.
				frame["pm1_0"] = frame["pm1_0_std"]
				frame["pm2_5"] = frame["pm2_5_std"]
				frame["pm10"] = frame["pm10_std"]
				frame["valid"] = bool(frame["checksum_ok"])
				frames.append(frame)
				i += 32
				continue
		i += 1
	return frames


static func pms5003_frames(data) -> Array:
	return pms5003_decode(data)


static func pms5003_parse(data) -> Array:
	return pms5003_decode(data)


static func pms5003_data(data) -> Array:
	return pms5003_decode(data)


static func decode_pms5003(data) -> Array:
	return pms5003_decode(data)


static func parse_pms5003(data) -> Array:
	return pms5003_decode(data)

