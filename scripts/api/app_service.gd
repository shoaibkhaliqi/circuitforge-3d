extends RefCounted
## CircuitForge 3D - application service layer (shared by the GUI, the MCP
## adapter and automated tests).
##
## This is the single authoritative API over the circuit model. It owns a
## Session (the editable design) and exposes validated, structured operations:
## inspection, editing, simulation, persistence and diagnostics.
##
## Design rules:
##   * Pure data in / pure data out. No scene-tree dependency, so it runs
##     head-less under `--script`.
##   * Every mutating operation is validated *before* it touches the model, so a
##     rejected call never leaves a partially modified circuit.
##   * Every mutation bumps `revision`. Callers may pass `expected_revision` for
##     optimistic-concurrency checks.
##   * File access is sand-boxed to approved roots; arbitrary paths are refused.
##   * Errors use stable codes so an AI agent can act on them.

const Session = preload("res://scripts/app/session.gd")
const Persistence = preload("res://scripts/persistence/persistence.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")
const BoardPins = preload("res://scripts/components/board_pins.gd")
const Units = preload("res://scripts/simulation/units.gd")
const CircuitSolver = preload("res://scripts/simulation/solver.gd")
const FirmwareBackend = preload("res://scripts/simulation/firmware_backend.gd")

const APP_NAME := "CircuitForge 3D"
const APP_VERSION := "0.1.0"
const API_PROTOCOL := "circuitforge-local-api/1"
const CIRCUIT_SCHEMA_VERSION := Persistence.SCHEMA_VERSION

# Resource limits (defensive; also documented for the MCP layer).
const MAX_COMPONENTS := 2000
const MAX_WIRES := 4000
const MAX_TRANSIENT_STEPS := 200000
const MAX_WAVEFORM_RETURN := 4000

var session
var revision: int = 0
var simulation_state: String = "idle"

var _sim_counter: int = 0
var _last_result_id: int = 0
var _last_result_kind: String = ""
var _last_result: Dictionary = {}
var _last_samples: Array = []
var _op_cache: Dictionary = {}
var _last_error := ""


func _init() -> void:
	session = Session.new()


# ---------------------------------------------------------------------------
# Result helpers
# ---------------------------------------------------------------------------

func _ok(data: Dictionary = {}) -> Dictionary:
	var out := data.duplicate(true)
	out["success"] = true
	out["revision"] = revision
	return out


func _err(code: String, message: String, action: String = "") -> Dictionary:
	return {
		"success": false,
		"revision": revision,
		"error": {"code": code, "message": message, "suggested_action": action},
	}


func _bump() -> void:
	revision += 1


func _check_revision(expected) -> Dictionary:
	if typeof(expected) != TYPE_INT and typeof(expected) != TYPE_FLOAT:
		return _ok()
	if int(expected) != revision:
		return _err("OPERATION_CONFLICT",
			"Project revision is %d but the caller expected %d." % [revision, int(expected)],
			"Re-read the project (get_project_summary) and retry against the current revision.")
	return _ok()


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

func get_simulator_info() -> Dictionary:
	return _ok({
		"application": APP_NAME,
		"application_version": APP_VERSION,
		"api_protocol": API_PROTOCOL,
		"circuit_schema_version": CIRCUIT_SCHEMA_VERSION,
		"component_categories": ComponentDB.categories(),
		"solver_modes": ["dc", "transient"],
		"instruments": ["oscilloscope", "multimeter"],
		"project_id": _project_id(),
		"project_name": _project_name(),
		"simulation_state": simulation_state,
		"revision": revision,
		"limitations": [
			"Combinational logic gates only (no sequential logic or MCU model).",
			"Transient integration is fixed backward-Euler.",
			"Ideal sources; no source resistance or noise models.",
			"Optional firmware runs in an external, sandboxed AVR emulator (avr8js via Node); no native code execution. Availability is reported by get_firmware_capabilities.",
		],
	})


func get_capabilities() -> Dictionary:
	var caps := {
		"read": ["get_simulator_info", "get_capabilities", "get_component_catalog",
			"get_catalog_facets", "get_board_pinout", "get_pin_states",
			"get_firmware_capabilities", "run_firmware",
			"get_project_summary", "list_components", "get_component", "get_connections",
			"get_node_voltage", "get_branch_current", "get_simulation_results",
			"get_simulation_status", "get_diagnostics", "get_solver_info",
			"get_waveform_data", "get_circuit_text", "get_edit_preview"],
		"edit_reversible": ["create_project", "add_component", "update_component_parameters",
			"set_pin_levels", "apply_firmware_pins", "apply_firmware_device", "apply_firmware_pwm",
			"apply_firmware_servo", "apply_firmware_stepper", "move_component", "connect_terminals", "disconnect_connection"],
		"edit_destructive": ["remove_component", "clear_circuit"],
		"simulate": ["run_dc_simulation", "run_transient_simulation", "stop_simulation"],
		"persistence": ["save_project", "load_project", "list_example_projects",
			"load_example_project"],
	}
	return _ok({
		"operations": caps,
		"solver_modes": ["dc", "transient"],
		"transient": {"integration": "backward-euler",
			"max_steps": MAX_TRANSIENT_STEPS,
			"min_dt": 1e-9, "max_returned_samples": MAX_WAVEFORM_RETURN},
		"limits": {"max_components": MAX_COMPONENTS, "max_wires": MAX_WIRES},
		"concurrency": "revision-based optimistic locking",
		"idempotency": "operations that create/delete accept an operation_id",
	})


func _param_meta(type: String) -> Dictionary:
	var def := ComponentDB.get_def(type)
	var out := {}
	if def.is_empty():
		return out
	for k in def.params:
		var p: Dictionary = def.params[k]
		out[k] = {
			"name": "parameters",
			"default": p.get("default", 0.0),
			"unit": String(p.get("unit", "")),
			"label": String(p.get("label", k)),
		}
		var rng := _param_range(String(k))
		if rng.size() == 2:
			out[k]["min"] = rng[0]
			out[k]["max"] = rng[1]
	return out


func _param_range(key: String) -> Array:
	match key:
		"r", "c", "l", "vz", "rout":
			return [0.0, null]
		"position":
			return [0.0, 1.0]
		"is":
			return [0.0, null]
		"n":
			return [0.0, null]
		"vdd":
			return [0.0, null]
		"vth":
			return [0.0, null]
		_:
			return []


func get_component_catalog(category: String = "", search: String = "", filters: Dictionary = {}) -> Dictionary:
	var f := {}
	for key in ["subcategory", "package", "mounting", "manufacturer", "status", "protocol", "interface"]:
		if filters.has(key) and String(filters[key]) != "":
			f[key] = String(filters[key])
	if bool(filters.get("arduino_compatible", false)):
		f["arduino_compatible"] = true
	if bool(filters.get("simulatable_only", false)):
		f["simulatable_only"] = true
	if category != "":
		f["category"] = category
	var limit := int(filters.get("limit", 0))
	var offset := int(filters.get("offset", 0))
	if limit > 0:
		f["limit"] = limit
	if offset > 0:
		f["offset"] = offset
	var result := ComponentDB.search(search, f)
	var items := []
	for type in result.items:
		items.append(_catalog_entry(String(type)))
	return _ok({
		"categories": ComponentDB.categories(),
		"count": int(result.count),
		"returned": items.size(),
		"offset": offset,
		"items": items,
		"facets": ComponentDB.facets(),
		"status_labels": ComponentDB.status_labels(),
	})


func _catalog_entry(type: String) -> Dictionary:
	var def: Dictionary = ComponentDB.get_def(type)
	var pins := []
	for p in def.pins:
		pins.append(String(p.name))
	var mounting := String(def.get("mounting", ""))
	return {
		"type": type,
		"name": String(def.name),
		"category": String(def.category),
		"subcategory": String(def.get("subcategory", "")),
		"manufacturer": String(def.get("manufacturer", "")),
		"part_number": String(def.get("part_number", "")),
		"description": String(def.get("description", "")),
		"keywords": def.get("keywords", []),
		"aliases": def.get("aliases", []),
		"pin_names": pins,
		"pin_count": pins.size(),
		"default_parameters": ComponentDB.default_params(type),
		"parameters": _param_meta(type),
		"simulation_status": String(def.get("simulation_status", "full")),
		"simulation_status_label": ComponentDB.status_label(type),
		"simulatable": ComponentDB.is_simulatable(type),
		"simulation_models": _models_for(type),
		"model_limitations": _model_limits(type),
		"mounting": mounting,
		"package": String(def.get("package", "")),
		"protocols": def.get("protocols", []),
		"interfaces": def.get("interfaces", []),
		"arduino_compatible": bool(def.get("arduino_compatible", false)),
		"firmware_required": bool(def.get("firmware_required", false)),
		"placeable_on_breadboard": mounting in ["tht", "smd", "module", ""],
		"notes": String(def.get("notes", "")),
	}


## Return the documented pin map of a development board (Arduino, ESP, Pico,
## Pi, STM32, Teensy, Android ...). Describes pins only; it does not simulate.
func get_board_pinout(type: String) -> Dictionary:
	if not BoardPins.is_board(type):
		return _err("NOT_A_BOARD",
			"'%s' is not a development board." % type,
			"Use get_component_catalog with mounting=\"board\" to list boards.")
	var s := BoardPins.summary(type)
	return _ok(s)


func get_pin_states() -> Dictionary:
	var built: Dictionary = session.build_circuit()
	var pin_nets: Dictionary = built.get("pin_nets", {})
	var nodes: Dictionary = {}
	if bool(_last_result.get("ok", false)):
		nodes = _last_result.get("node_voltages", {})
	var pins := []
	for c in session.project.components:
		if String(c.get("type", "")) != "mcu_pin":
			continue
		var p: Dictionary = c.get("params", {})
		var level := float(p.get("level", 1.0))
		var nets: Array = pin_nets.get(String(c.id), [])
		var sig_node := String(nets[0]) if nets.size() > 0 else ""
		var entry := {
			"component_id": String(c.id),
			"level": level,
			"state": _pin_state_name(level),
			"vlogic": float(p.get("vlogic", 5.0)),
			"rout": float(p.get("rout", 25.0)),
			"signal_node": sig_node,
		}
		if not sig_node.is_empty() and nodes.has(sig_node):
			entry["voltage"] = float(nodes[sig_node])
		pins.append(entry)
	return _ok({"count": pins.size(), "pins": pins,
		"reference": String(_last_result.get("reference", "0"))})


func _pin_state_name(level: float) -> String:
	if level >= 0.5:
		return "high"
	if level <= -0.5:
		return "high_z"
	return "low"


func set_pin_levels(levels: Dictionary, simulate: bool = false, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	if levels.is_empty():
		return _err("INVALID_PARAMETER", "No pin levels were provided.",
			"Provide a map of component_id -> level (-1, 0 or 1).")
	var applied := []
	var skipped := []
	for id in levels.keys():
		var cid := String(id)
		var c = session.find_component(cid)
		if c == null:
			skipped.append({"component_id": cid, "reason": "unknown component"})
			continue
		if String(c.type) != "mcu_pin":
			skipped.append({"component_id": cid, "reason": "not an mcu_pin (type '%s')" % String(c.type)})
			continue
		var lv := clampf(float(levels[id]), -1.0, 1.0)
		session.set_params(cid, {"level": lv})
		applied.append({"component_id": cid, "level": lv, "state": _pin_state_name(lv)})
	if applied.is_empty():
		return _err("INVALID_PARAMETER", "None of the given ids are 'mcu_pin' components.",
			"Add a 'mcu_pin' component and use its component_id.")
	_bump()
	var out := {"applied": applied, "skipped": skipped, "revision": revision}
	if simulate:
		out["simulation"] = run_dc_simulation()
	return _ok(out)


func get_firmware_capabilities() -> Dictionary:
	return _ok(FirmwareBackend.capabilities())


func run_firmware(hex_path: String, ms: int = 2000, attach_devices: bool = false, analog_map: Dictionary = {}, pin_map: Dictionary = {}) -> Dictionary:
	var cap := FirmwareBackend.capabilities()
	if not bool(cap.get("available", false)):
		return _err("FIRMWARE_UNAVAILABLE",
			"Firmware execution is unavailable: " + ", ".join(PackedStringArray(cap.get("unavailable_reasons", []))),
			"Install Node.js (or set CIRCUITFORGE_NODE) and keep firmware/harness/run.mjs.")
	# `pin_map` also needs the netlist: it is how a firmware pin is drawn to the
	# net of a servo (the pulse train's destination) as well as to a sensor's.
	var need_netlist := not analog_map.is_empty() or attach_devices or not pin_map.is_empty()
	var need_analog := not analog_map.is_empty() or (attach_devices and (_has_type("pcf8591") or _has_type("mcp3008") or _has_type("ads1115")))
	var built := {}
	var volts_by_node := {}
	if need_netlist:
		built = session.build_circuit()
		if need_analog:
			if built.ground_net != "0":
				return _err("NO_REFERENCE", "Analog inputs need a reference (ground) node.",
					"Add a Ground component.")
			var solver = CircuitSolver.new()
			var res: Dictionary = solver.solve_dc(built.circuit)
			if not bool(res.get("ok", false)):
				return _err("SIMULATION_FAILURE", "Could not solve to read the analog inputs: " + String(res.get("error", "")),
					"Check the circuit for floating nets or conflicting sources.")
			volts_by_node = res.get("node_voltages", {})
	var devices := _firmware_devices(volts_by_node, built.get("pin_nets", {}), pin_map) if attach_devices else []
	var adc := {}
	var analog_applied := []
	var pin_applied := []
	for key in pin_map.keys():
		var cid := String(pin_map[key])
		var dnum := _digital_pin(key)
		var c = session.find_component(cid)
		if dnum < 0:
			pin_applied.append({"pin": String(key), "component_id": cid, "skipped": "not a Uno digital pin (0..19)"})
		elif c == null:
			pin_applied.append({"pin": String(key), "component_id": cid, "skipped": "component not found"})
		else:
			pin_applied.append({"pin": String(key), "digital_pin": dnum, "component_id": cid})
	for key in analog_map.keys():
		var ch := _adc_channel(key)
		var cid := String(analog_map[key])
		var c = session.find_component(cid)
		if c == null or String(c.type) != "mcu_analog_in":
			analog_applied.append({"channel": String(key), "component_id": cid, "skipped": "not an mcu_analog_in"})
			continue
		var nets: Array = (built.get("pin_nets", {}) as Dictionary).get(cid, [])
		if nets.is_empty():
			analog_applied.append({"channel": String(key), "component_id": cid, "skipped": "unplaced"})
			continue
		var volts := clampf(float(volts_by_node.get(String(nets[0]), 0.0)), 0.0, 5.0)
		adc[ch] = volts
		analog_applied.append({"channel": String(key), "component_id": cid, "voltage": volts})
	var r := FirmwareBackend.run_hex(hex_path, ms, devices, adc)
	if not bool(r.get("ok", false)):
		return _err("FIRMWARE_ERROR", String(r.get("error", "firmware run failed")),
			"Compile a sketch to Intel HEX (arduino-cli compile --fqbn arduino:avr:uno) and pass its path.")
	var transitions: Array = r.get("transitions", [])
	var pins := []
	for p in FirmwareBackend.pins_touched(transitions):
		pins.append({"digital_pin": p, "label": FirmwareBackend.label(p)})
	var serial := FirmwareBackend.truncate_serial(String(r.get("serial", "")))
	var i2c: Array = r.get("i2c", [])
	if i2c.size() > FirmwareBackend.MAX_BUS_EVENTS:
		i2c = i2c.slice(0, FirmwareBackend.MAX_BUS_EVENTS)
	var spi: Array = r.get("spi_bytes", [])
	var note := "Open-loop Stage B: firmware digital pins, UART output and I2C/SPI bus traces; no analog feedback."
	if attach_devices and not analog_map.is_empty():
		note = "Closed loop: attached bus devices can be read/written, firmware ADC channels read the solved node voltages, and firmware-driven sensors (HC-SR04) can drive MCU input pins; no analog OUTPUT to the circuit."
	elif attach_devices:
		note = "Closed bus loop: attached devices (from the circuit) can be read/written by firmware, an SPI OLED's frame is decoded from the SPI trace plus its DC/CS lines, and a mapped `mcp3008` ADC answers SPI reads with its channels' solved node voltages while an `ads1115` answers I2C conversion reads the same way; the MCU's own ADC channels still need `analog_map`."
	elif not analog_map.is_empty():
		note = "Closed analog loop: firmware ADC channels read the solved node voltages; no analog output to the circuit."
	if not pin_map.is_empty():
		note += " Pin-level devices (mapped via pin_map) drive MCU inputs: the HC-SR04 emits a distance pulse, the rotary encoder steps a quadrature pair, a DHT answers the one-wire start signal, and a DS18B20 answers real 1-Wire reset/read/write slots (its `pin_devices` entry reports the served ROM, the scratchpad and the command stream). Mapped outputs are read back the same way: a servo's commanded angle (`servos`) and a stepper driver's move (`steppers`) are decoded from the pulse trains or phase sequence the sketch drove."
	return _ok({
		"engine": FirmwareBackend.ENGINE,
		"engine_license": FirmwareBackend.ENGINE_LICENSE,
		"hex": hex_path,
		"ms": int(r.get("ms", ms)),
		"cycles": int(r.get("cycles", 0)),
		"transition_count": transitions.size(),
		"pins": pins,
		"transitions": transitions,
		"serial": serial,
		"serial_bytes": int(r.get("serial_bytes", serial.length())),
		"serial_lines": FirmwareBackend.serial_lines(serial),
		"i2c": i2c,
		"i2c_addresses": FirmwareBackend.i2c_addresses(i2c),
		"spi_bytes": spi,
		"spi_byte_count": int(r.get("spi_byte_count", spi.size())),
		"devices": r.get("devices", []),
		"attached_devices": devices.size(),
		"adc": r.get("adc", {}),
		"analog_inputs": analog_applied,
		"pin_devices": r.get("pin_devices", []),
		"pin_inputs": pin_applied,
		"servos": _firmware_servos(transitions, built.get("pin_nets", {}), pin_map),
		"steppers": _firmware_steppers(transitions, built.get("pin_nets", {}), pin_map),
		"note": note,
	})


## Firmware analog-pin key ("0".."7" or "A0".."A7") -> ADC channel number, or -1.
func _adc_channel(key) -> int:
	var s := String(key).strip_edges().to_upper()
	if s.begins_with("A"):
		s = s.substr(1)
	if s.is_valid_int():
		return int(s)
	return -1


## Firmware digital-pin key ("9", "D9", "A0") -> Uno digital pin number (0..19), or -1.
func _digital_pin(key) -> int:
	var n := FirmwareBackend.pin_number(key)
	return n if n >= 0 and n <= 19 else -1


## True if the project has at least one component of the given type.
func _has_type(t: String) -> bool:
	var comps: Array = session.project.get("components", []) if session != null else []
	for c in comps:
		if String(c.get("type", "")) == t:
			return true
	return false


## Build harness device specs from the circuit's device components so firmware can
## read (and write) them: the PCF8574 expander, the 24C02 I2C EEPROM, the PCF8591
## ADC/DAC (analog inputs from the solved node voltages), the I2C 16x2 LCD, the
## SSD1306 OLED (I2C by address, SPI by its DC/CS pins resolved from `pin_map`),
## the MPU-6050 register file, the SHT31 environmental sensor, and
## firmware-driven pin devices (the HC-SR04, whose TRIG/ECHO pins are resolved from
## `pin_map` — a firmware digital pin -> component id map like `analog_map` — the
## rotary encoder, whose A/B quadrature pair is resolved the same way, and the
## DHT11/DHT22, whose DATA pin is likewise resolved and which answers the start
## signal itself).
func _firmware_devices(node_voltages := {}, pin_nets := {}, pin_map := {}) -> Array:
	var out := []
	var comps: Array = session.project.get("components", []) if session != null else []
	for c in comps:
		var t := String(c.get("type", ""))
		var p: Dictionary = c.get("params", {})
		if t == "pcf8574":
			out.append({
				"kind": "pcf8574",
				"address": int(p.get("address", 39)) & 0x7F,
				"state": int(p.get("state", 0)) & 0xFF,
				"inputs": int(p.get("inputs", 0)) & 0xFF,
			})
		elif t == "eeprom_i2c":
			out.append({
				"kind": "eeprom",
				"address": int(p.get("address", 80)) & 0x7F,
				"size": clampi(int(p.get("size", 256)), 1, 32768),
				"init": [],
			})
		elif t == "pcf8591":
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			var ain := []
			for n in 4:
				var v := 0.0
				if n < nets.size():
					v = clampf(float(node_voltages.get(String(nets[n]), 0.0)), 0.0, 100.0)
				ain.append(v)
			out.append({
				"kind": "pcf8591",
				"address": int(p.get("address", 72)) & 0x7F,
				"vref": maxf(0.001, float(p.get("vref", 5.0))),
				"ain": ain,
			})
		elif t == "i2c_lcd1602":
			out.append({
				"kind": "lcd1602",
				"address": int(p.get("address", 39)) & 0x7F,
				"cols": clampi(int(p.get("cols", 16)), 1, 40),
				"rows": clampi(int(p.get("rows", 2)), 1, 4),
			})
		elif t == "oled_ssd1306":
			out.append({
				"kind": "ssd1306",
				"address": int(p.get("address", 60)) & 0x7F,
				"cols": clampi(int(p.get("cols", 128)), 1, 256),
				"pages": clampi(int(p.get("pages", 8)), 1, 16),
			})
		elif t == "oled_ssd1306_spi":
			# An SPI panel has no address: the command/data split comes from its DC line
			# and a transaction boundary from CS, both ordinary GPIOs resolved from
			# `pin_map` (the same net lookup the HC-SR04/encoder use). The bytes themselves
			# are whatever the sketch sent through the ATmega's SPI peripheral. Without DC
			# the stream cannot be split, so the panel is skipped rather than guessed at.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 7:
				var dc := _net_pin(String(nets[5]), pin_map, pin_nets)
				var cs := _net_pin(String(nets[6]), pin_map, pin_nets)
				if dc >= 0:
					out.append({
						"kind": "ssd1306_spi",
						"dc": dc,
						"cs": cs,
						"cols": clampi(int(p.get("cols", 128)), 1, 256),
						"pages": clampi(int(p.get("pages", 8)), 1, 16),
					})
		elif t == "epaper_213":
			# E-paper panel on SPI: DC/CS resolved from pin_map like the OLED/TFT.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 8:
				var dc := _net_pin(String(nets[5]), pin_map, pin_nets)
				var cs := _net_pin(String(nets[4]), pin_map, pin_nets)
				if dc >= 0:
					out.append({
						"kind": "epaper_spi",
						"dc": dc,
						"cs": cs,
						"width": 250,
						"height": 122,
					})
		elif t == "tof_vl53l0x":
			out.append({
				"kind": "tof_vl53l0x",
				"address": int(p.get("address", 41)) & 0x7F,
				"distance_mm": float(p.get("distance_mm", 300.0)),
			})
		elif t == "max6675_thermocouple":
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 4:
				var cs := _net_pin(String(nets[3]), pin_map, pin_nets)
				if cs >= 0:
					out.append({
						"kind": "max6675_spi",
						"cs": cs,
						"temperature": float(p.get("temperature", 25.0)),
					})
		elif t == "max7219_matrix":
			# MAX7219 LED matrix on SPI: no DC line, CS frames 16-bit words.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 4:
				var cs := _net_pin(String(nets[3]), pin_map, pin_nets)
				if cs >= 0:
					out.append({
						"kind": "max7219_spi",
						"cs": cs,
					})
		elif t == "tft_ili9341":
			# The colour TFT, resolved exactly like the SPI OLED: no address to fall back
			# on, so its DC (command/data, pin 4) and CS (selected, pin 2) lines come from
			# `pin_map`. Its frame is summarised rather than returned whole.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 9:
				var dc := _net_pin(String(nets[4]), pin_map, pin_nets)
				var cs := _net_pin(String(nets[2]), pin_map, pin_nets)
				if dc >= 0:
					out.append({
						"kind": "ili9341",
						"dc": dc,
						"cs": cs,
						"width": clampi(int(p.get("width", 240)), 1, 1024),
						"height": clampi(int(p.get("height", 320)), 1, 1024),
					})
		elif t == "mcp3008":
			# The SPI ADC has no address either: CS comes from `pin_map`, and its eight
			# channel pins are ADC probes on the solved nets (the same closed loop as the
			# PCF8591's AIN0..AIN3). `vref` is a parameter rather than the VREF net.
			# Without CS the harness cannot frame a conversion, so the part is skipped.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 16:
				var cs := _net_pin(String(nets[9]), pin_map, pin_nets)
				if cs >= 0:
					var ain := []
					for n in 8:
						ain.append(clampf(float(node_voltages.get(String(nets[n]), 0.0)), 0.0, 100.0))
					out.append({
						"kind": "mcp3008",
						"cs": cs,
						"vref": maxf(0.001, float(p.get("vref", 5.0))),
						"ain": ain,
					})
		elif t == "ads1115":
			# An addressed register file (like the MPU-6050/ADXL345) whose conversion is
			# computed from the solved channel voltages: A0..A3 are probes on their nets, so
			# firmware reads single-ended channels *and* the differential pairs at the gain
			# it selects in the config register.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 10:
				var ain := []
				for ch in 4:
					ain.append(clampf(float(node_voltages.get(String(nets[6 + ch]), 0.0)), 0.0, 100.0))
				out.append({
					"kind": "ads1115",
					"address": int(p.get("address", 72)) & 0x7F,
					"ain": ain,
				})
		elif t == "mpu6050":
			out.append({
				"kind": "mpu6050",
				"address": int(p.get("address", 104)) & 0x7F,
				"ax": float(p.get("ax", 0.0)),
				"ay": float(p.get("ay", 0.0)),
				"az": float(p.get("az", 1.0)),
				"gx": float(p.get("gx", 0.0)),
				"gy": float(p.get("gy", 0.0)),
				"gz": float(p.get("gz", 0.0)),
				"temp_c": float(p.get("temp_c", 25.0)),
			})
		elif t == "adxl345":
			# A served register file like the MPU-6050, but with the ADXL345's own map:
			# the sample accelerations come from params and their counts follow the scale
			# the firmware's DATA_FORMAT write selects.
			out.append({
				"kind": "adxl345",
				"address": int(p.get("address", 83)) & 0x7F,
				"ax": float(p.get("ax", 0.0)),
				"ay": float(p.get("ay", 0.0)),
				"az": float(p.get("az", 1.0)),
			})
		elif t == "sht31":
			out.append({
				"kind": "sht31",
				"address": int(p.get("address", 68)) & 0x7F,
				"temp_c": clampf(float(p.get("temp_c", 23.0)), -40.0, 125.0),
				"humidity": clampf(float(p.get("humidity", 48.0)), 0.0, 100.0),
				"corrupt_crc": 1 if float(p.get("corrupt_crc", 0.0)) >= 0.5 else 0,
			})
		elif t == "hcsr04":
			# TRIG and ECHO are resolved from the caller's `pin_map`: a mapped
			# component that shares the sensor's TRIG/ECHO net names the firmware pin.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 3:
				var trig := _net_pin(String(nets[1]), pin_map, pin_nets)
				var echo := _net_pin(String(nets[2]), pin_map, pin_nets)
				if trig >= 0 and echo >= 0 and trig != echo:
					out.append({
						"kind": "hc_sr04",
						"trig": trig,
						"echo": echo,
						"distance_cm": maxf(0.0, float(p.get("distance_cm", 30.0))),
					})
		elif t == "rotary_encoder":
			# The A/B quadrature pair is resolved from `pin_map` the same way: each
			# mapped component shares the encoder's A or B net, naming the firmware pin.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 4:
				var pa := _net_pin(String(nets[2]), pin_map, pin_nets)
				var pb := _net_pin(String(nets[3]), pin_map, pin_nets)
				if pa >= 0 and pb >= 0 and pa != pb:
					out.append({
						"kind": "encoder",
						"a": pa,
						"b": pb,
						"counts": clampi(int(p.get("counts", 40)), 0, 100000),
						"direction": 1 if float(p.get("direction", 1.0)) >= 0.0 else -1,
						"step_us": maxf(50.0, float(p.get("step_us", 1000.0))),
					})
		elif t == "dht11" or t == "dht22":
			# One-wire environmental sensor: its DATA pin is resolved from `pin_map`
			# and the part answers the start signal itself.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 2:
				var data := _net_pin(String(nets[1]), pin_map, pin_nets)
				if data >= 0:
					out.append({
						"kind": "dht",
						"pin": data,
						"model": t,
						"temp_c": clampf(float(p.get("temp_c", 23.0)), -40.0, 125.0),
						"humidity": clampf(float(p.get("humidity", 48.0)), 0.0, 100.0),
					})
		elif t == "ds18b20":
			# 1-Wire digital thermometer: a real bidirectional bit-slot slave, so (unlike the
			# DHT's start-pulse part) it only needs its DQ pin, resolved from `pin_map`, and
			# the harness decodes and answers every reset, read and write slot.
			var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
			if nets.size() >= 2:
				var dq := _net_pin(String(nets[1]), pin_map, pin_nets)
				if dq >= 0:
					out.append({
						"kind": "ds18b20",
						"pin": dq,
						"temp_c": clampf(float(p.get("temp_c", 23.0)), -55.0, 125.0),
					})
	return out


## Firmware digital pin wired to `net` according to the caller's `pin_map`
## ({firmware pin key: component id}), or -1 if no mapped component shares the net.
## `exclude` skips one component id (a driver cannot resolve a firmware pin through
## itself: its own nets carry no information about which pin drives them).
func _net_pin(net: String, pin_map: Dictionary, pin_nets: Dictionary, exclude := "") -> int:
	for key in pin_map.keys():
		var cid := String(pin_map[key])
		if cid == exclude and exclude != "":
			continue
		var nets: Array = (pin_nets as Dictionary).get(cid, [])
		for n in nets:
			if String(n) == net:
				return _digital_pin(key)
	return -1


## True for the catalog types a servo pulse train can be decoded for.
func _is_servo_type(t: String) -> bool:
	return t == "servo_sg90" or t == "servo_mg996r"


## True for the STEP/DIR stepper driver carriers the app can count pulses for.
func _is_stepper_driver_type(t: String) -> bool:
	return t == "a4988_driver" or t == "drv8825_driver"


## True for the four-phase (ULN2003-style) stepper drivers the app can follow a sequence on.
func _is_phase_driver_type(t: String) -> bool:
	return t == "uln2003_driver"


## True for the stepper motors a driver's coil outputs can be wired to.
func _is_stepper_motor_type(t: String) -> bool:
	return t == "stepper_nema17" or t == "stepper_28byj48"


## Index of the pin called `name` (case-insensitive) in a catalog type's pin list, or -1.
func _pin_index_of(type: String, name: String) -> int:
	var pins: Array = ComponentDB.get_def(type).get("pins", [])
	for i in pins.size():
		if String((pins[i] as Dictionary).get("name", "")).to_upper() == name.to_upper():
			return i
	return -1


## Nets on a type's *passive* pins — a stepper driver's coil outputs (1A/1B/2A/2B).
func _coil_nets(type: String, nets: Array) -> Array:
	var out := []
	var pins: Array = ComponentDB.get_def(type).get("pins", [])
	for i in pins.size():
		if i < nets.size() and String((pins[i] as Dictionary).get("type", "")) == "passive":
			out.append(String(nets[i]))
	return out


## True when a `pin_map` value names a component that is not itself of `family` ("servo" or
## "stepper"), i.e. the mapping is by net and resolving it needs the netlist.
func _pin_map_needs_netlist(pin_map: Dictionary, family: String) -> bool:
	for key in pin_map.keys():
		var c = session.find_component(String(pin_map[key]))
		if c == null:
			continue
		var direct := _is_servo_type(String(c.type)) if family == "servo" else _is_stepper_motor_type(String(c.type))
		if not direct:
			return true
	return false


## Id of the component of `family` driven through the net of component `cid`, or "" when
## there is none. For a servo only its PWM pin counts (index 2): its GND/VCC sit on the
## supply rails, which every other part shares, so matching any net would be meaningless.
func _component_on_net(pin_nets: Dictionary, cid: String, family: String) -> String:
	var mapped: Array = pin_nets.get(cid, [])
	if mapped.is_empty():
		return ""
	for c in (session.project.get("components", []) as Array):
		var d := c as Dictionary
		var t := String(d.get("type", ""))
		var other: Array = pin_nets.get(String(d.get("id", "")), [])
		if other.is_empty():
			continue
		if family == "servo":
			if _is_servo_type(t) and other.size() >= 3 and mapped.has(String(other[2])):
				return String(d.get("id", ""))
		elif _is_stepper_motor_type(t):
			for n in other:
				if mapped.has(String(n)):
					return String(d.get("id", ""))
	return ""


## Stepper moves the firmware commanded. Like a servo this is an *output*: nothing is sent
## to the harness. For each STEP/DIR driver whose STEP (and DIR) net shares a net with a
## mapped component, the rising edges on STEP are counted and the DIR level at each one
## gives the sign. A four-phase (ULN2003) driver is the same idea across four phase pins:
## each valid pattern change is measured against the drive cycle, so wave, full-step and
## half-step sketches all decode to the same half-step travel. If a stepper motor is wired
## to the driver's coil outputs, its `steps_per_rev` (and the STEP/DIR driver's
## `microsteps`) turn the count into a shaft angle.
func _firmware_steppers(transitions: Array, pin_nets := {}, pin_map := {}) -> Array:
	var out := []
	if (pin_map as Dictionary).is_empty():
		return out
	var comps: Array = session.project.get("components", []) if session != null else []
	for c in comps:
		var t := String(c.get("type", ""))
		var cid := String(c.get("id", ""))
		var nets: Array = (pin_nets as Dictionary).get(cid, [])
		if _is_stepper_driver_type(t):
			var si := _pin_index_of(t, "STEP")
			var di := _pin_index_of(t, "DIR")
			if si < 0 or si >= nets.size():
				continue
			var step_pin := _net_pin(String(nets[si]), pin_map, pin_nets, cid)
			if step_pin < 0:
				continue
			var dir_pin := -1
			if di >= 0 and di < nets.size():
				dir_pin = _net_pin(String(nets[di]), pin_map, pin_nets, cid)
			var micro := clampi(int((c.get("params", {}) as Dictionary).get("microsteps", 1)), 1, 64)
			var counts := FirmwareBackend.stepper_steps(transitions, step_pin, dir_pin)
			var target := _stepper_target(comps, t, nets, pin_nets, 200.0)
			var spr := float(target.steps_per_rev)
			var steps := int(counts.steps)
			out.append({
				"kind": "stepdir",
				"component_id": cid,
				"driver": t,
				"step_pin": step_pin,
				"step_label": FirmwareBackend.label(step_pin),
				"dir_pin": dir_pin,
				"dir_label": FirmwareBackend.label(dir_pin) if dir_pin >= 0 else "",
				"dir_wired": dir_pin >= 0,
				"microsteps": micro,
				"steps": steps,
				"forward": int(counts.forward),
				"reverse": int(counts.reverse),
				"motor_component_id": String(target.id),
				"steps_per_rev": spr,
				"angle_deg": snappedf(FirmwareBackend.stepper_angle(float(steps), spr, float(micro)), 0.01),
			})
		elif _is_phase_driver_type(t):
			var pins := []
			var labels := []
			var wired := 0
			for i in 4:
				var ni := _pin_index_of(t, "IN%d" % (i + 1))
				var pin := -1
				if ni >= 0 and ni < nets.size():
					pin = _net_pin(String(nets[ni]), pin_map, pin_nets, cid)
				pins.append(pin)
				labels.append(FirmwareBackend.label(pin) if pin >= 0 else "")
				if pin >= 0:
					wired += 1
			if wired < 2:
				continue
			var ph := FirmwareBackend.stepper_phases(transitions, pins)
			# One measured unit here is a half step, so the 28BYJ-48's 4096 (half steps per
			# output revolution) is the natural default.
			var ptarget := _stepper_target(comps, t, nets, pin_nets, 4096.0)
			var pspr := float(ptarget.steps_per_rev)
			var psteps := int(ph.steps)
			out.append({
				"kind": "4phase",
				"component_id": cid,
				"driver": t,
				"phase_pins": pins,
				"phase_labels": labels,
				"pattern_changes": int(ph.changes),
				"skipped_patterns": int(ph.skipped),
				"steps": psteps,
				"forward": int(ph.forward),
				"reverse": int(ph.reverse),
				"motor_component_id": String(ptarget.id),
				"steps_per_rev": pspr,
				"angle_deg": snappedf(FirmwareBackend.stepper_angle(float(psteps), pspr, 1.0), 0.01),
			})
	return out


## The stepper motor wired to a driver's coil outputs, with its steps-per-revolution
## (`default_spr` when the part does not declare one). `id` is empty when no motor is wired
## to those outputs, and then the move has no target to be applied to.
func _stepper_target(comps: Array, driver_type: String, driver_nets: Array, pin_nets: Dictionary, default_spr: float) -> Dictionary:
	var coil_nets := _coil_nets(driver_type, driver_nets)
	for m in comps:
		if not _is_stepper_motor_type(String(m.get("type", ""))):
			continue
		for n in (pin_nets as Dictionary).get(String(m.get("id", "")), []):
			if coil_nets.has(String(n)):
				var p: Dictionary = m.get("params", {})
				return {
					"id": String(m.get("id", "")),
					"steps_per_rev": maxf(1.0, float(p.get("steps_per_rev", default_spr))),
				}
	return {"id": "", "steps_per_rev": default_spr}


## Servo positions the firmware commanded. A servo is an *output*, so nothing is sent to
## the harness: for each servo component whose PWM net shares a net with a mapped
## component, the pulse widths the sketch drove on that pin are decoded into an angle
## (the same band the part uses — `min_us`/`max_us` at 0/`range_deg`). `pulses` is 0
## when the pin never drove a pulse, and then `angle_deg` is -1.
func _firmware_servos(transitions: Array, pin_nets := {}, pin_map := {}) -> Array:
	var out := []
	if (pin_map as Dictionary).is_empty():
		return out
	var comps: Array = session.project.get("components", []) if session != null else []
	for c in comps:
		var t := String(c.get("type", ""))
		if not _is_servo_type(t):
			continue
		var nets: Array = (pin_nets as Dictionary).get(String(c.get("id", "")), [])
		if nets.size() < 3:
			continue
		var pin := _net_pin(String(nets[2]), pin_map, pin_nets)
		if pin < 0:
			continue
		var p: Dictionary = c.get("params", {})
		var lo := clampf(float(p.get("min_us", 544.0)), 100.0, 10000.0)
		var hi := clampf(float(p.get("max_us", 2400.0)), 100.0, 10000.0)
		var rng := clampf(float(p.get("range_deg", 180.0)), 1.0, 360.0)
		var pos := FirmwareBackend.servo_position(transitions, pin, lo, hi, rng)
		out.append({
			"digital_pin": pin,
			"label": FirmwareBackend.label(pin),
			"component_id": String(c.get("id", "")),
			"min_us": lo,
			"max_us": hi,
			"range_deg": rng,
			"pulses": int(pos.pulses),
			"last_us": snappedf(float(pos.last_us), 0.01),
			"min_us_seen": snappedf(float(pos.min_us_seen), 0.01),
			"max_us_seen": snappedf(float(pos.max_us_seen), 0.01),
			"angle_deg": snappedf(float(pos.angle_deg), 0.01),
		})
	return out


func apply_firmware_pins(hex_path: String, pin_map: Dictionary, ms: int = 2000, at_ms: float = -1.0, simulate: bool = false, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	if pin_map.is_empty():
		return _err("INVALID_PARAMETER", "No pin_map was provided.",
			"Map firmware pins to mcu_pin ids, e.g. {\"13\": \"P1\"}.")
	var cap := FirmwareBackend.capabilities()
	if not bool(cap.get("available", false)):
		return _err("FIRMWARE_UNAVAILABLE",
			"Firmware execution is unavailable: " + ", ".join(PackedStringArray(cap.get("unavailable_reasons", []))),
			"Install Node.js (or set CIRCUITFORGE_NODE) and keep firmware/harness/run.mjs.")
	var r := FirmwareBackend.run_hex(hex_path, ms)
	if not bool(r.get("ok", false)):
		return _err("FIRMWARE_ERROR", String(r.get("error", "firmware run failed")),
			"Compile a sketch to Intel HEX (arduino-cli compile --fqbn arduino:avr:uno) and pass its path.")
	var t := float(r.get("ms", ms)) if at_ms < 0.0 else at_ms
	var levels := FirmwareBackend.levels_at(r.get("transitions", []), t)
	var applied := []
	var skipped := []
	for key in pin_map.keys():
		var pin := FirmwareBackend.pin_number(key)
		var cid := String(pin_map[key])
		var c = session.find_component(cid)
		if c == null:
			skipped.append({"pin": String(key), "component_id": cid, "reason": "unknown component"})
			continue
		if String(c.type) != "mcu_pin":
			skipped.append({"pin": String(key), "component_id": cid, "reason": "not an mcu_pin"})
			continue
		if pin < 0 or not levels.has(pin):
			skipped.append({"pin": String(key), "component_id": cid, "reason": "pin not driven by firmware"})
			continue
		var lv := float(levels[pin])
		session.set_params(cid, {"level": lv})
		applied.append({"pin": String(key), "component_id": cid, "level": lv, "state": _pin_state_name(lv)})
	if applied.is_empty():
		return _err("NO_PINS_APPLIED", "Firmware ran but no mapped pin could be applied.",
			"Check the pin numbers and that the sketch drives them.")
	_bump()
	var out := {"applied": applied, "skipped": skipped, "at_ms": t, "hex": hex_path, "revision": revision}
	if simulate:
		out["simulation"] = run_dc_simulation()
	return _ok(out)


func apply_firmware_device(hex_path: String, component_id: String, ms: int = 2000, simulate: bool = false, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	var c = session.find_component(component_id)
	if c == null:
		return _err("UNKNOWN_COMPONENT", "No component '%s'." % component_id,
			"Use list_components to find the id.")
	var ctype := String(c.type)
	if ctype != "pcf8574" and ctype != "pcf8591" and ctype != "mcp4725":
		return _err("UNSUPPORTED_DEVICE",
			"Component '%s' is '%s', which has no firmware device model." % [component_id, ctype],
			"Supported devices: 'pcf8574', 'pcf8591', 'mcp4725'.")
	var cap := FirmwareBackend.capabilities()
	if not bool(cap.get("available", false)):
		return _err("FIRMWARE_UNAVAILABLE",
			"Firmware execution is unavailable: " + ", ".join(PackedStringArray(cap.get("unavailable_reasons", []))),
			"Install Node.js (or set CIRCUITFORGE_NODE) and keep firmware/harness/run.mjs.")
	# Each device kind has its own default address (a PCF8574 backpack sits at 0x27, a
	# PCF8591 at 0x48, an MCP4725 at 0x60), used when the instance has no `address` param.
	var def_addr := 39 if ctype == "pcf8574" else (72 if ctype == "pcf8591" else 96)
	var addr := int(c.get("params", {}).get("address", def_addr)) & 0x7F
	# The MCP4725 is write-only, so the harness is asked to serve it (devices=...): the
	# protocol is decoded once, in run.mjs, and the app reads the device summary.
	var specs := []
	if ctype == "mcp4725":
		specs.append({"kind": "mcp4725", "address": addr,
			"vref": float(c.get("params", {}).get("vref", 5.0))})
	var r := FirmwareBackend.run_hex(hex_path, ms, specs)
	if not bool(r.get("ok", false)):
		return _err("FIRMWARE_ERROR", String(r.get("error", "firmware run failed")),
			"Compile a sketch to Intel HEX (arduino-cli compile --fqbn arduino:avr:uno) and pass its path.")
	var byte := FirmwareBackend.last_i2c_write_byte(r.get("i2c", []), addr)
	if byte < 0:
		return _err("NO_DEVICE_WRITE",
			"Firmware did not write to I2C address 0x%02X." % addr,
			"Check the sketch and the device 'address' parameter.")
	if ctype == "pcf8574":
		session.set_params(component_id, {"state": byte})
		_bump()
		var levels := []
		for n in 8:
			levels.append(1 if ((byte >> n) & 1) == 1 else 0)
		var out := {
			"component_id": component_id, "type": ctype,
			"address": "0x%02X" % addr, "state": byte, "port_levels": levels,
			"hex": hex_path, "revision": revision,
		}
		if simulate:
			out["simulation"] = run_dc_simulation()
		return _ok(out)
	if ctype == "mcp4725":
		# A write-only 12-bit DAC: the decoded code comes from the served device (the
		# protocol is implemented once, in the harness) rather than from re-parsing the
		# trace here. The output is VDD-referenced, and a non-zero power-down code is
		# carried through so the netlist stops treating VOUT as a driven source.
		var dac := {}
		for d in r.get("devices", []):
			if typeof(d) == TYPE_DICTIONARY and String(d.get("kind", "")) == "mcp4725":
				dac = d
		if dac.is_empty():
			return _err("NO_DEVICE_WRITE",
				"The DAC did not see a write it could decode (only its general write command is modelled).",
				"Write the DAC register (a 0x40/0x60 command byte) followed by two data bytes.")
		var dac_code := clampi(int(dac.get("code", 0)), 0, 4095)
		var dac_pd := clampi(int(dac.get("power_down", 0)), 0, 3)
		var dac_vref := float(c.get("params", {}).get("vref", 5.0))
		var vout := (float(dac_code) / 4096.0) * dac_vref
		session.set_params(component_id, {"vout": vout, "power_down": dac_pd})
		_bump()
		var dac_out := {
			"component_id": component_id, "type": ctype,
			"address": "0x%02X" % addr, "code": dac_code, "vout": vout, "vref": dac_vref,
			"power_down": dac_pd,
			"eeprom_writes": int(dac.get("eeprom_writes", 0)),
			"hex": hex_path, "revision": revision,
		}
		if simulate:
			dac_out["simulation"] = run_dc_simulation()
		return _ok(dac_out)
	# pcf8591: the last byte written is the DAC value (control byte then data).
	var vref := float(c.get("params", {}).get("vref", 5.0))
	var aout := (float(byte) / 255.0) * vref
	session.set_params(component_id, {"aout": aout})
	_bump()
	var dout := {
		"component_id": component_id, "type": ctype,
		"address": "0x%02X" % addr, "dac": byte, "aout": aout, "vref": vref,
		"hex": hex_path, "revision": revision,
	}
	if simulate:
		dout["simulation"] = run_dc_simulation()
	return _ok(dout)


func apply_firmware_pwm(hex_path: String, pin_map: Dictionary, ms: int = 2000, vlogic: float = 5.0, simulate: bool = false, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	if pin_map.is_empty():
		return _err("INVALID_PARAMETER", "No pin_map was provided.",
			"Map firmware pins to mcu_pwm_out ids, e.g. {\"9\": \"PWM1\"}.")
	var cap := FirmwareBackend.capabilities()
	if not bool(cap.get("available", false)):
		return _err("FIRMWARE_UNAVAILABLE",
			"Firmware execution is unavailable: " + ", ".join(PackedStringArray(cap.get("unavailable_reasons", []))),
			"Install Node.js (or set CIRCUITFORGE_NODE) and keep firmware/harness/run.mjs.")
	var r := FirmwareBackend.run_hex(hex_path, ms)
	if not bool(r.get("ok", false)):
		return _err("FIRMWARE_ERROR", String(r.get("error", "firmware run failed")),
			"Compile a sketch to Intel HEX (arduino-cli compile --fqbn arduino:avr:uno) and pass its path.")
	var pwm: Dictionary = r.get("pwm", {})
	var applied := []
	var skipped := []
	for key in pin_map.keys():
		var pin := FirmwareBackend.pin_number(key)
		var cid := String(pin_map[key])
		var c = session.find_component(cid)
		if c == null:
			skipped.append({"pin": String(key), "component_id": cid, "reason": "unknown component"})
			continue
		if String(c.type) != "mcu_pwm_out":
			skipped.append({"pin": String(key), "component_id": cid, "reason": "not an mcu_pwm_out"})
			continue
		var duty := FirmwareBackend.pwm_duty(pwm, pin)
		if duty < 0.0:
			skipped.append({"pin": String(key), "component_id": cid, "reason": "pin is not PWM-driving"})
			continue
		var volts := duty * vlogic
		session.set_params(cid, {"voltage": volts})
		applied.append({"pin": String(key), "component_id": cid, "duty": duty, "voltage": volts})
	if applied.is_empty():
		return _err("NO_PWM_APPLIED", "Firmware ran but no mapped pin was PWM-driving.",
			"Use analogWrite() on the mapped pins (PWM-capable pins 3,5,6,9,10,11 on an Uno).")
	_bump()
	var out := {"applied": applied, "skipped": skipped, "vlogic": vlogic, "hex": hex_path, "revision": revision}
	if simulate:
		out["simulation"] = run_dc_simulation()
	return _ok(out)


## Run firmware and write the servo angle it commanded onto each mapped servo. The angle
## is a *mechanical* state recovered from the pulse-width train the sketch drove (50 Hz,
## `min_us`..`max_us` at 0..`range_deg`); it adds no electrical behaviour to the circuit,
## so the solved netlist is unchanged and `simulate` is only a convenience echo.
## `pin_map` maps a firmware pin to either the servo itself or, like `run_firmware`, to a
## component on the servo's PWM net (usually the circuit's virtual `mcu_pin`).
func apply_firmware_servo(hex_path: String, pin_map: Dictionary, ms: int = 3000, simulate: bool = false, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	if pin_map.is_empty():
		return _err("INVALID_PARAMETER", "No pin_map was provided.",
			"Map a firmware pin to a servo component id, e.g. {\"9\": \"SERVO1\"}.")
	var cap := FirmwareBackend.capabilities()
	if not bool(cap.get("available", false)):
		return _err("FIRMWARE_UNAVAILABLE",
			"Firmware execution is unavailable: " + ", ".join(PackedStringArray(cap.get("unavailable_reasons", []))),
			"Install Node.js (or set CIRCUITFORGE_NODE) and keep firmware/harness/run.mjs.")
	var r := FirmwareBackend.run_hex(hex_path, ms)
	if not bool(r.get("ok", false)):
		return _err("FIRMWARE_ERROR", String(r.get("error", "firmware run failed")),
			"Compile a sketch to Intel HEX (arduino-cli compile --fqbn arduino:avr:uno) and pass its path.")
	var applied := []
	var skipped := []
	# `pin_map` follows the same convention as `run_firmware`: the value may name the servo
	# itself, or a component (usually a virtual `mcu_pin`) wired to the servo's PWM net. The
	# net form needs the netlist, so build it only when it is actually used.
	var pin_nets: Dictionary = {}
	if _pin_map_needs_netlist(pin_map, "servo"):
		var built: Dictionary = session.build_circuit()
		pin_nets = built.get("pin_nets", {})
	for key in pin_map.keys():
		var pin := FirmwareBackend.pin_number(key)
		var cid := String(pin_map[key])
		var c = session.find_component(cid)
		if c == null:
			skipped.append({"pin": String(key), "component_id": cid, "reason": "unknown component"})
			continue
		if pin < 0:
			skipped.append({"pin": String(key), "component_id": cid, "reason": "not a Uno digital pin (0..19)"})
			continue
		var servo_id := ""
		if _is_servo_type(String(c.type)):
			servo_id = cid
		elif not pin_nets.is_empty():
			servo_id = _component_on_net(pin_nets, cid, "servo")
		if servo_id == "":
			skipped.append({"pin": String(key), "component_id": cid,
				"reason": "not a servo and no servo shares its PWM net"})
			continue
		var sc = session.find_component(servo_id)
		var p: Dictionary = sc.get("params", {})
		var lo := clampf(float(p.get("min_us", 544.0)), 100.0, 10000.0)
		var hi := clampf(float(p.get("max_us", 2400.0)), 100.0, 10000.0)
		var rng := clampf(float(p.get("range_deg", 180.0)), 1.0, 360.0)
		var pos := FirmwareBackend.servo_position(r.get("transitions", []), pin, lo, hi, rng)
		if int(pos.pulses) == 0:
			skipped.append({"pin": String(key), "component_id": servo_id, "reason": "pin never drove a servo pulse"})
			continue
		var angle := snappedf(float(pos.angle_deg), 0.01)
		session.set_params(servo_id, {"angle": angle})
		applied.append({
			"pin": String(key), "component_id": servo_id, "angle_deg": angle,
			"pulse_us": snappedf(float(pos.last_us), 0.01), "pulses": int(pos.pulses),
			"min_us_seen": snappedf(float(pos.min_us_seen), 0.01),
			"max_us_seen": snappedf(float(pos.max_us_seen), 0.01),
		})
	if applied.is_empty():
		var hint := "Drive the mapped pin with a 50 Hz pulse train (see firmware/sketches/servo_sweep)."
		if not skipped.is_empty():
			hint = "Nothing was applied: " + JSON.stringify(skipped) + ". " + hint
		return _err("NO_SERVO_APPLIED", "Firmware ran but no mapped pin produced a servo pulse.", hint)
	_bump()
	var out := {"applied": applied, "skipped": skipped, "hex": hex_path, "ms": int(r.get("ms", ms)), "revision": revision}
	if simulate:
		out["simulation"] = run_dc_simulation()
	return _ok(out)


## Run firmware and write the move it commanded onto each stepper motor it drives. The
## pulses go to a STEP/DIR driver or a four-phase (ULN2003) driver wired to the motor's
## coils: the caller maps the firmware pins driving the driver's inputs (STEP/DIR, or
## IN1..IN4) to the components on those nets (usually the circuit's virtual `mcu_pin`s), the
## app counts the edges or follows the drive sequence, finds the driver and the motor on its
## coil outputs, and writes the net `steps` and the shaft `angle` onto the motor.
## `microsteps` overrides a STEP/DIR driver's own parameter (1/2/4/8/16 as strapped on
## MS1..MS3, which are not read; a four-phase move is measured in half steps instead).
## Purely mechanical: the solved circuit is unchanged.
func apply_firmware_stepper(hex_path: String, pin_map: Dictionary, ms: int = 2000, microsteps: int = 0, simulate: bool = false, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	if pin_map.is_empty():
		return _err("INVALID_PARAMETER", "No pin_map was provided.",
			"Map the firmware pins that drive a stepper driver's inputs to the components wired to those nets, e.g. {\"3\": \"P1\", \"2\": \"P2\"} for STEP/DIR or {\"8\": \"P1\", \"9\": \"P2\"} for IN1/IN2.")
	var cap := FirmwareBackend.capabilities()
	if not bool(cap.get("available", false)):
		return _err("FIRMWARE_UNAVAILABLE",
			"Firmware execution is unavailable: " + ", ".join(PackedStringArray(cap.get("unavailable_reasons", []))),
			"Install Node.js (or set CIRCUITFORGE_NODE) and keep firmware/harness/run.mjs.")
	var r := FirmwareBackend.run_hex(hex_path, ms)
	if not bool(r.get("ok", false)):
		return _err("FIRMWARE_ERROR", String(r.get("error", "firmware run failed")),
			"Compile a sketch to Intel HEX (arduino-cli compile --fqbn arduino:avr:uno) and pass its path.")
	var built: Dictionary = session.build_circuit()
	var found := _firmware_steppers(r.get("transitions", []), built.get("pin_nets", {}), pin_map)
	var applied := []
	var skipped := []
	for entry in found:
		var motor_id := String(entry.get("motor_component_id", ""))
		if motor_id == "":
			skipped.append({"driver_id": String(entry.get("component_id", "")), "reason": "no stepper motor wired to the driver's coil outputs"})
			continue
		var kind := String(entry.get("kind", "stepdir"))
		# A STEP/DIR move is measured in (micro)steps, so the driver's microstepping scales
		# it; a four-phase move is already measured in half steps, so it does not.
		var micro := 1
		if kind == "stepdir":
			micro = int(entry.get("microsteps", 1)) if microsteps <= 0 else clampi(microsteps, 1, 64)
		var spr := maxf(1.0, float(entry.get("steps_per_rev", 200.0)))
		var steps := int(entry.get("steps", 0))
		var angle := snappedf(FirmwareBackend.stepper_angle(float(steps), spr, float(micro)), 0.01)
		session.set_params(motor_id, {"steps": steps, "angle": angle})
		var rec := {
			"kind": kind,
			"driver_id": String(entry.get("component_id", "")),
			"component_id": motor_id,
			"steps": steps,
			"forward": int(entry.get("forward", 0)),
			"reverse": int(entry.get("reverse", 0)),
			"steps_per_rev": spr,
			"angle_deg": angle,
		}
		if kind == "stepdir":
			rec["microsteps"] = micro
			rec["step_pin"] = int(entry.get("step_pin", -1))
			rec["dir_pin"] = int(entry.get("dir_pin", -1))
		else:
			rec["phase_pins"] = entry.get("phase_pins", [])
			rec["pattern_changes"] = int(entry.get("pattern_changes", 0))
			rec["skipped_patterns"] = int(entry.get("skipped_patterns", 0))
		applied.append(rec)
	if found.is_empty():
		return _err("NO_STEPPER_DRIVER", "Firmware ran but no mapped stepper driver was found.",
			"Map the firmware pins wired to the driver's inputs (STEP/DIR, or IN1..IN4 for a ULN2003) to the components on those nets — the driver itself cannot be used: its nets do not say which pin drives them.")
	if applied.is_empty():
		var hint := "Wire the driver's coil outputs (1A/1B/2A/2B, or OUT1..OUT4) to a stepper motor so the move has a target."
		if not skipped.is_empty():
			hint = "Nothing was applied: " + JSON.stringify(skipped) + ". " + hint
		return _err("NO_STEPPER_TARGET", "Firmware ran but no motor was reachable from the driver.", hint)
	_bump()
	var out := {"applied": applied, "skipped": skipped, "hex": hex_path, "ms": int(r.get("ms", ms)), "revision": revision}
	if simulate:
		out["simulation"] = run_dc_simulation()
	return _ok(out)


func get_catalog_facets() -> Dictionary:
	var f := ComponentDB.facets()
	return _ok({
		"count": ComponentDB.count(),
		"categories": f.categories,
		"subcategories": f.subcategories,
		"packages": f.packages,
		"mountings": f.mountings,
		"manufacturers": f.manufacturers,
		"statuses": f.statuses,
		"protocols": f.protocols,
		"interfaces": f.interfaces,
		"status_labels": ComponentDB.status_labels(),
		"validation_errors": ComponentDB.catalog_errors(),
	})


func _models_for(type: String) -> Array:
	match type:
		"resistor", "switch", "potentiometer":
			return ["linear conductance"]
		"capacitor":
			return ["backward-euler companion (DC: open)"]
		"inductor":
			return ["backward-euler companion (DC: short)"]
		"vsource":
			return ["ideal voltage source", "dc/sine/square/pulse/triangle"]
		"isource":
			return ["ideal current source"]
		"ground":
			return ["reference node"]
		"diode", "led", "zener":
			return ["shockley diode", "newton-raphson"]
		"and", "or", "not", "nand", "nor", "xor", "buffer":
			return ["ideal logic gate", "thevenin output", "newton-raphson"]
		_:
			return []


func _model_limits(type: String) -> Array:
	match type:
		"diode", "led", "zener":
			return ["No reverse recovery or capacitance."]
		"capacitor", "inductor":
			return ["Fixed backward-Euler; no adaptive stepping."]
		"and", "or", "not", "nand", "nor", "xor", "buffer":
			return ["Combinational only; no propagation delay."]
		_:
			return []


# ---------------------------------------------------------------------------
# Inspection
# ---------------------------------------------------------------------------

func _project_id() -> String:
	if session == null or session.project.is_empty():
		return ""
	var d := _design_hash()
	return "cf3d-" + d.substr(0, 12)


func _project_name() -> String:
	if session == null:
		return "Untitled"
	return String(session.project.get("metadata", {}).get("name", "Untitled"))


func _design_hash() -> String:
	var design := {
		"components": session.project.get("components", []),
		"wires": session.project.get("wires", []),
	}
	return str(hash(JSON.stringify(design, "", true, true)))


func get_project_summary() -> Dictionary:
	var built: Dictionary = session.build_circuit()
	var net_count := 0
	var seen := {}
	for cid in built.pin_nets:
		for n in built.pin_nets[cid]:
			if not seen.has(n):
				seen[n] = true
				net_count += 1
	var v := Persistence.validate(session.project)
	return _ok({
		"project_id": _project_id(),
		"project_name": _project_name(),
		"component_count": session.project.components.size(),
		"connection_count": session.project.wires.size(),
		"node_count": net_count,
		"revision": revision,
		"validation_status": "ok" if v.ok else "invalid",
		"simulation_state": simulation_state,
		"last_result_id": _last_result_id,
		"last_result_ok": bool(_last_result.get("ok", false)),
		"has_reference": built.ground_net == "0",
		"dirty": session.is_dirty(),
	})


func list_components(type_filter: String = "", limit: int = 500, offset: int = 0) -> Dictionary:
	var items := []
	for c in session.project.components:
		if type_filter != "" and String(c.type) != type_filter:
			continue
		items.append(_component_public(c))
	var total := items.size()
	var lim: int = clampi(limit, 1, MAX_COMPONENTS)
	var off: int = maxi(0, offset)
	var page := items.slice(off, off + lim)
	return _ok({"count": total, "returned": page.size(), "offset": off, "items": page})


func _component_public(c: Dictionary) -> Dictionary:
	var def := ComponentDB.get_def(String(c.type))
	var pin_names := []
	for p in def.get("pins", []):
		pin_names.append(String(p.name))
	return {
		"component_id": String(c.id),
		"component_type": String(c.type),
		"type_name": String(def.get("name", c.type)),
		"category": String(def.get("category", "")),
		"label": String(c.get("label", "")),
		"parameters": (c.get("params", {}) as Dictionary).duplicate(true),
		"positions": (c.get("holes", []) as Array).duplicate(),
		"orientation_radians": float(c.get("rotation", 0.0)),
		"terminal_names": pin_names,
	}


func get_component(component_id: String) -> Dictionary:
	var c = session.find_component(component_id)
	if c == null:
		return _err("UNKNOWN_COMPONENT", "No component with id '%s'." % component_id,
			"List components to get a valid component_id.")
	var pub := _component_public(c)
	var built: Dictionary = session.build_circuit()
	pub["node_ids"] = (built.pin_nets.get(component_id, []) as Array).duplicate()
	pub["simulatable"] = not _models_for(String(c.type)).is_empty()
	return _ok({"component": pub})


func get_connections() -> Dictionary:
	var built: Dictionary = session.build_circuit()
	var pin_nets: Dictionary = built.pin_nets
	var wires := []
	for w in session.project.wires:
		wires.append({
			"connection_id": String(w.get("id", "")),
			"kind": "wire",
			"a": (w.get("a", {}) as Dictionary).duplicate(true),
			"b": (w.get("b", {}) as Dictionary).duplicate(true),
		})
	var pin_map := []
	for c in session.project.components:
		var cid := String(c.id)
		var nets: Array = pin_nets.get(cid, [])
		for i in nets.size():
			pin_map.append({"component_id": cid, "pin": i, "node_id": String(nets[i])})
	return _ok({
		"wires": wires,
		"wire_count": wires.size(),
		"pin_node_map": pin_map,
		"reference_node": built.ground_net,
		"net_names": (built.net_names as Array).duplicate(),
		"builder_warnings": (built.warnings as Array).duplicate(),
	})


func get_node_voltage(node: String) -> Dictionary:
	if simulation_state != "completed" or _last_result.is_empty() or not bool(_last_result.get("ok", false)):
		return _err("NO_SIMULATION_RESULT", "No valid simulation result is available.",
			"Run run_dc_simulation or run_transient_simulation first.")
	var nodes: Dictionary = _last_result.get("node_voltages", {})
	if not nodes.has(node):
		return _err("UNKNOWN_NODE", "Node '%s' does not exist in the last result." % node,
			"Call get_connections or get_simulation_results to list node ids.")
	return _ok({
		"node_id": node,
		"voltage": float(nodes[node]),
		"unit": "V",
		"time_seconds": float(_last_result.get("time", 0.0)),
		"result_id": _last_result_id,
		"valid": true,
	})


func get_branch_current(branch: String) -> Dictionary:
	if simulation_state != "completed" or _last_result.is_empty() or not bool(_last_result.get("ok", false)):
		return _err("NO_SIMULATION_RESULT", "No valid simulation result is available.",
			"Run a simulation first.")
	var cur: Dictionary = _last_result.get("element_currents", {})
	if not cur.has(branch):
		return _err("UNKNOWN_COMPONENT", "No branch current for '%s'." % branch,
			"Use a component id returned by list_components.")
	return _ok({
		"component_id": branch,
		"current": float(cur[branch]),
		"unit": "A",
		"direction": "pin[0] -> pin[1] through the component",
		"time_seconds": float(_last_result.get("time", 0.0)),
		"result_id": _last_result_id,
		"valid": true,
	})


func get_simulation_results(filter_type: String = "", limit: int = 500, offset: int = 0) -> Dictionary:
	if simulation_state != "completed" or _last_result.is_empty():
		return _err("NO_SIMULATION_RESULT", "No simulation has completed yet.",
			"Run run_dc_simulation or run_transient_simulation.")
	var node_voltages: Dictionary = _last_result.get("node_voltages", {})
	var currents: Dictionary = _last_result.get("element_currents", {})
	var voltages: Dictionary = _last_result.get("element_voltages", {})
	var lim: int = clampi(limit, 1, MAX_COMPONENTS)
	var off: int = maxi(0, offset)
	var nodes := []
	var keys: Array = node_voltages.keys()
	keys.sort()
	for i in range(min(keys.size(), lim + off)):
		if i < off:
			continue
		nodes.append({"node_id": String(keys[i]), "voltage_v": float(node_voltages[keys[i]])})
	var branches := []
	var bkeys: Array = currents.keys()
	bkeys.sort()
	for i in range(min(bkeys.size(), lim + off)):
		if i < off:
			continue
		var cid := String(bkeys[i])
		branches.append({
			"component_id": cid,
			"current_a": float(currents[cid]),
			"voltage_v": float(voltages.get(cid, 0.0)),
		})
	var res := {
		"result_id": _last_result_id,
		"kind": _last_result_kind,
		"ok": bool(_last_result.get("ok", false)),
		"iterations": int(_last_result.get("iterations", 0)),
		"reference": String(_last_result.get("reference", "0")),
		"time_seconds": float(_last_result.get("time", 0.0)),
		"node_voltages": nodes,
		"branches": branches,
		"warnings": (_last_result.get("warnings", []) as Array).duplicate(),
	}
	if filter_type == "nodes":
		res.erase("branches")
	elif filter_type == "branches":
		res.erase("node_voltages")
	return _ok(res)


func get_simulation_status() -> Dictionary:
	return _ok({
		"state": simulation_state,
		"result_id": _last_result_id,
		"kind": _last_result_kind,
		"ok": bool(_last_result.get("ok", false)),
	})


func get_diagnostics() -> Dictionary:
	return _ok(_diagnostics())


func _diagnostics() -> Dictionary:
	var diags := []
	var v := Persistence.validate(session.project)
	for e in v.errors:
		diags.append(_diag("INVALID_PROJECT", "error", String(e), true, [], []))
	for w in v.warnings:
		diags.append(_diag("PROJECT_WARNING", "warning", String(w), false, [], []))

	var built: Dictionary = session.build_circuit()
	for w in built.warnings:
		diags.append(_diag("BUILD_WARNING", "warning", String(w), false, [], []))

	if built.ground_net != "0":
		diags.append(_diag("NO_REFERENCE", "error",
			"No Ground component is placed; the circuit has no 0 V reference node.",
			true, [], []))

	for c in session.project.components:
		var cid := String(c.id)
		var def := ComponentDB.get_def(String(c.type))
		if def.is_empty():
			continue
		var holes: Array = c.get("holes", [])
		for i in def.pins.size():
			var h := String(holes[i]) if i < holes.size() else ""
			if h == "":
				diags.append(_diag("UNCONNECTED_PIN", "info",
					"%s pin %d (%s) is not placed in a hole." % [cid, i + 1, String(def.pins[i].name)],
					false, [cid], []))
		var pv := _validate_params(String(c.type), c.get("params", {}))
		for err in pv:
			diags.append(_diag("INVALID_PARAMETER", "error", "%s: %s" % [cid, String(err)],
				true, [cid], []))

	diags.append_array(_conflicting_sources())

	# Try a trial DC solve to surface singular / non-converging circuits, but
	# report it as a diagnostic, never as a definitive measurement.
	if built.ground_net == "0" and session.project.components.size() > 0:
		var trial = CircuitSolver.new().solve_dc(built.circuit)
		if not bool(trial.get("ok", false)):
			diags.append(_diag("SINGULAR_OR_NONCONVERGENT", "error",
				"Trial DC solve failed: %s" % String(trial.get("error", "")), true, [], []))

	var has_error := false
	var has_warning := false
	for d in diags:
		if d.severity == "error":
			has_error = true
		elif d.severity == "warning":
			has_warning = true
	return {
		"diagnostics": diags,
		"error_count": _count_sev(diags, "error"),
		"warning_count": _count_sev(diags, "warning"),
		"info_count": _count_sev(diags, "info"),
		"blocks_simulation": has_error,
		"status": "error" if has_error else ("warning" if has_warning else "ok"),
	}


func _count_sev(diags: Array, sev: String) -> int:
	var n := 0
	for d in diags:
		if String(d.severity) == sev:
			n += 1
	return n


func _diag(code: String, severity: String, message: String, blocks: bool, components: Array, nodes: Array) -> Dictionary:
	return {
		"code": code,
		"severity": severity,
		"message": message,
		"blocks_simulation": blocks,
		"components": components,
		"nodes": nodes,
		"suggested_action": _diag_action(code),
	}


func _diag_action(code: String) -> String:
	match code:
		"NO_REFERENCE":
			return "Add a Ground component and place it on the net you want as 0 V."
		"UNCONNECTED_PIN":
			return "Place the pin in a hole or connect it with a wire."
		"INVALID_PARAMETER":
			return "Provide a finite value inside the allowed range."
		"INVALID_PROJECT":
			return "Fix the referenced ids/holes, then re-validate."
		"SINGULAR_OR_NONCONVERGENT":
			return "Ensure every net has a DC path to ground and sources are consistent."
		"CONFLICTING_SOURCES":
			return "Do not parallel ideal voltage sources with different values."
		_:
			return ""


func _conflicting_sources() -> Array:
	var out := []
	var groups := {}
	for c in session.project.components:
		if String(c.type) != "vsource":
			continue
		var cid := String(c.id)
		var built: Dictionary = session.build_circuit()
		var nets: Array = built.pin_nets.get(cid, [])
		if nets.size() < 2:
			continue
		var key := String(nets[0]) + "|" + String(nets[1])
		var rkey := String(nets[1]) + "|" + String(nets[0])
		if groups.has(key) or groups.has(rkey):
			out.append(_diag("CONFLICTING_SOURCES", "error",
				"Ideal voltage sources %s and %s share both terminals." % [cid, String(groups.get(key, groups.get(rkey, "?")))],
				true, [cid], []))
		else:
			groups[key] = cid
	return out


func get_solver_info() -> Dictionary:
	return _ok({
		"method": "modified nodal analysis",
		"modes": ["dc", "transient"],
		"nonlinear": {"method": "newton-raphson", "junction_limiting": true,
			"max_iterations": 200, "node_tolerance": 1e-6},
		"transient": {"integration": "backward-euler", "max_steps": MAX_TRANSIENT_STEPS},
		"device_models": ["resistor", "capacitor", "inductor", "potentiometer", "switch",
			"ideal voltage source", "ideal current source", "diode", "led", "zener",
			"logic gates"],
		"reference_node": "0",
		"last_convergence": {"ok": bool(_last_result.get("ok", false)),
			"iterations": int(_last_result.get("iterations", 0)),
			"warnings": (_last_result.get("warnings", []) as Array).duplicate()},
	})


func get_circuit_text() -> Dictionary:
	return _ok({"text": _natural_language(), "revision": revision})


func _natural_language() -> String:
	var comps: Array = session.project.components
	if comps.is_empty():
		return "The circuit is empty."
	var parts := []
	for c in comps:
		parts.append(_describe_component(c))
	var text := "This circuit contains %d component(s): " % comps.size()
	text += _join_list(parts) + "."
	if session.project.wires.size() > 0:
		text += " There are %d jumper wire(s) connecting terminals." % session.project.wires.size()
	if simulation_state == "completed" and bool(_last_result.get("ok", false)):
		var nodes: Dictionary = _last_result.get("node_voltages", {})
		var bits := []
		var keys: Array = nodes.keys()
		keys.sort()
		for i in range(min(keys.size(), 6)):
			bits.append("node %s = %s" % [String(keys[i]), Units.format(float(nodes[keys[i]]), "V")])
		text += " The last simulation gives " + _join_list(bits) + "."
	else:
		text += " No simulation has been run yet."
	return text


func _describe_component(c: Dictionary) -> String:
	var type := String(c.type)
	var def := ComponentDB.get_def(type)
	var p: Dictionary = c.get("params", {})
	match type:
		"resistor":
			return "a resistor %s of %s" % [String(c.id), Units.format(float(p.get("r", 0.0)), "ohm")]
		"capacitor":
			return "a capacitor %s of %s" % [String(c.id), Units.format(float(p.get("c", 0.0)), "F")]
		"inductor":
			return "an inductor %s of %s" % [String(c.id), Units.format(float(p.get("l", 0.0)), "H")]
		"vsource":
			return "a voltage source %s of %s" % [String(c.id), Units.format(float(p.get("v", 0.0)), "V")]
		"isource":
			return "a current source %s of %s" % [String(c.id), Units.format(float(p.get("i", 0.0)), "A")]
		"ground":
			return "a ground reference %s" % String(c.id)
		"led", "diode", "zener":
			return "a %s %s" % [String(def.get("name", type)).to_lower(), String(c.id)]
		_:
			return "a %s %s" % [String(def.get("name", type)).to_lower(), String(c.id)]


func _join_list(items: Array) -> String:
	if items.size() == 0:
		return ""
	if items.size() == 1:
		return String(items[0])
	var head := []
	for i in range(items.size() - 1):
		head.append(String(items[i]))
	return ", ".join(head) + " and " + String(items[items.size() - 1])


# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

func create_project(name: String = "Untitled", operation_id: String = "") -> Dictionary:
	var idem := _idempotent(operation_id)
	if not idem.is_empty():
		return idem
	session.new_project()
	session.project.metadata["name"] = name
	session.mark_untitled()
	_bump()
	var res := _ok({"project_id": _project_id(), "project_name": name, "revision": revision})
	_remember(operation_id, res)
	return res


func add_component(component_type: String, name: String = "", holes: Array = [], orientation: float = 0.0, parameters: Dictionary = {}, operation_id: String = "") -> Dictionary:
	var idem := _idempotent(operation_id)
	if not idem.is_empty():
		return idem
	if not ComponentDB.exists(component_type):
		return _err("UNKNOWN_COMPONENT_TYPE", "Unknown component type '%s'." % component_type,
			"Call get_component_catalog to list valid types.")
	if session.project.components.size() >= MAX_COMPONENTS:
		return _err("LIMIT_EXCEEDED", "Component limit (%d) reached." % MAX_COMPONENTS,
			"Remove components or split the project.")
	var merged := ComponentDB.default_params(component_type)
	for k in parameters:
		merged[String(k)] = parameters[k]
	var pv := _validate_params(component_type, merged)
	if pv.size() > 0:
		return _err("INVALID_PARAMETER", "; ".join(pv),
			"Provide valid parameter values (see get_component_catalog).")
	var pc := ComponentDB.pin_count(component_type)
	var use_holes := holes.duplicate()
	while use_holes.size() < pc:
		use_holes.append("")
	var bb_ok := _validate_holes(use_holes)
	if not bb_ok.ok:
		return _err("INVALID_CONNECTION", String(bb_ok.error),
			"Use valid hole ids (e.g. a1, e30, TP1) or leave empty and wire pins.")
	var cid: String = session.add_component(component_type, use_holes, merged)
	if cid == "":
		return _err("OPERATION_FAILED", "Could not add the component.", "Try again.")
	var comp = session.find_component(cid)
	if comp != null:
		comp.rotation = float(orientation)
		if name != "":
			comp["label"] = name
	_bump()
	var res := _ok({"component_id": cid, "component": _component_public(session.find_component(cid))})
	_remember(operation_id, res)
	return res


func _validate_holes(holes: Array) -> Dictionary:
	var bb = session.make_breadboard()
	for h in holes:
		var hs := String(h)
		if hs == "":
			continue
		if not bb.is_valid_hole(hs):
			return {"ok": false, "error": "Invalid hole '%s'." % hs}
	return {"ok": true, "error": ""}


func update_component_parameters(component_id: String, parameters: Dictionary, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	var c = session.find_component(component_id)
	if c == null:
		return _err("UNKNOWN_COMPONENT", "No component with id '%s'." % component_id,
			"List components to get a valid component_id.")
	if parameters.is_empty():
		return _err("INVALID_PARAMETER", "No parameters were provided.", "Provide at least one parameter.")
	var pv := _validate_params(String(c.type), parameters, true)
	if pv.size() > 0:
		return _err("INVALID_PARAMETER", "; ".join(pv),
			"Provide valid parameter values (see get_component_catalog).")
	session.set_params(component_id, parameters)
	_bump()
	return _ok({"component_id": component_id, "component": _component_public(session.find_component(component_id))})


func move_component(component_id: String, holes: Array = [], orientation = null, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	var c = session.find_component(component_id)
	if c == null:
		return _err("UNKNOWN_COMPONENT", "No component with id '%s'." % component_id, "List components first.")
	var new_holes: Array = holes.duplicate() if not holes.is_empty() else (c.get("holes", []) as Array).duplicate()
	var pc := ComponentDB.pin_count(String(c.type))
	while new_holes.size() < pc:
		new_holes.append("")
	var check := _validate_holes(new_holes)
	if not check.ok:
		return _err("INVALID_CONNECTION", String(check.error), "Use valid hole ids.")
	session.move_component(component_id, new_holes)
	if orientation != null:
		var comp = session.find_component(component_id)
		if comp != null:
			comp.rotation = float(orientation)
	_bump()
	return _ok({"component_id": component_id, "component": _component_public(session.find_component(component_id))})


func remove_component(component_id: String, confirm: bool = false, expected_revision = null, operation_id: String = "") -> Dictionary:
	var idem := _idempotent(operation_id)
	if not idem.is_empty():
		return idem
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	var c = session.find_component(component_id)
	if c == null:
		return _err("UNKNOWN_COMPONENT", "No component with id '%s'." % component_id, "List components first.")
	var affected := _affected_connections(component_id)
	if not confirm:
		return _err("CONFIRMATION_REQUIRED",
			"Removing %s would also delete %d connection(s)." % [component_id, affected.size()],
			"Re-call remove_component with confirm=true to proceed.")

	session.remove_component(component_id)
	_bump()
	var res := _ok({"component_id": component_id, "removed_connections": affected})
	_remember(operation_id, res)
	return res


func _affected_connections(component_id: String) -> Array:
	var out := []
	for w in session.project.wires:
		var touches := false
		for k in ["a", "b"]:
			var ep: Dictionary = w.get(k, {})
			if String(ep.get("kind", "")) == "pin" and String(ep.get("component", "")) == component_id:
				touches = true
		if touches:
			out.append(String(w.get("id", "")))
	return out


func connect_terminals(a: Dictionary, b: Dictionary, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	if session.project.wires.size() >= MAX_WIRES:
		return _err("LIMIT_EXCEEDED", "Wire limit reached.", "Remove wires first.")
	var va := _validate_endpoint(a)
	if not va.ok:
		return _err("INVALID_CONNECTION", "Endpoint a: " + String(va.error), "Use {'kind':'pin','component':id,'pin':i} or {'kind':'hole','id':'a1'}.")
	var vb := _validate_endpoint(b)
	if not vb.ok:
		return _err("INVALID_CONNECTION", "Endpoint b: " + String(vb.error), "Use a valid endpoint.")
	if _endpoints_equal(a, b):
		return _err("INVALID_CONNECTION", "Both endpoints are the same.", "Choose two different terminals.")
	var wid: String = session.add_wire(a, b)
	if wid == "":
		return _err("OPERATION_FAILED", "Could not create the connection.", "Try again.")
	_bump()
	var built: Dictionary = session.build_circuit()
	return _ok({"connection_id": wid, "node_ids": (built.net_names as Array).duplicate()})


func _endpoints_equal(a: Dictionary, b: Dictionary) -> bool:
	return JSON.stringify(a, "", true, true) == JSON.stringify(b, "", true, true)


func _validate_endpoint(ep) -> Dictionary:
	if typeof(ep) != TYPE_DICTIONARY:
		return {"ok": false, "error": "not an object"}
	var kind := String(ep.get("kind", "hole"))
	if kind == "pin":
		var cid := String(ep.get("component", ""))
		if session.find_component(cid) == null:
			return {"ok": false, "error": "unknown component '%s'" % cid}
		var pin := int(ep.get("pin", 0))
		var c = session.find_component(cid)
		if pin < 0 or pin >= ComponentDB.pin_count(String(c.type)):
			return {"ok": false, "error": "pin %d out of range for %s" % [pin, cid]}
		return {"ok": true, "error": ""}
	elif kind == "hole":
		var hid := String(ep.get("id", ""))
		if not session.make_breadboard().is_valid_hole(hid):
			return {"ok": false, "error": "invalid hole '%s'" % hid}
		return {"ok": true, "error": ""}
	return {"ok": false, "error": "unknown endpoint kind '%s'" % kind}


func disconnect_connection(connection_id: String, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	var idx := -1
	for i in session.project.wires.size():
		if String(session.project.wires[i].get("id", "")) == connection_id:
			idx = i
			break
	if idx < 0:
		return _err("INVALID_CONNECTION", "No connection with id '%s'." % connection_id,
			"Call get_connections to list connection ids.")
	session.project.wires.remove_at(idx)
	session.changed.emit()
	_bump()
	return _ok({"connection_id": connection_id})


func clear_circuit(confirm: bool = false, expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	if not confirm:
		return _err("CONFIRMATION_REQUIRED",
			"Clearing removes %d component(s) and %d connection(s)." % [session.project.components.size(), session.project.wires.size()],
			"Re-call clear_circuit with confirm=true.")
	session.clear()
	_bump()
	return _ok({})


func get_edit_preview(operation: String, arguments: Dictionary = {}) -> Dictionary:
	var preview := {"operation": operation, "will_modify": true, "warnings": []}
	match operation:
		"add_component":
			var t := String(arguments.get("component_type", ""))
			if not ComponentDB.exists(t):
				return _err("UNKNOWN_COMPONENT_TYPE", "Unknown component type '%s'." % t, "See the catalog.")
			preview["component_type"] = t
			preview["pins"] = ComponentDB.pin_count(t)
		"remove_component":
			var cid := String(arguments.get("component_id", ""))
			if session.find_component(cid) == null:
				return _err("UNKNOWN_COMPONENT", "No component '%s'." % cid, "List components first.")
			preview["component_id"] = cid
			preview["affected_connections"] = _affected_connections(cid)
		"connect_terminals":
			preview["a"] = arguments.get("a", {})
			preview["b"] = arguments.get("b", {})
		"update_component_parameters":
			var cid2 := String(arguments.get("component_id", ""))
			if session.find_component(cid2) == null:
				return _err("UNKNOWN_COMPONENT", "No component '%s'." % cid2, "List components first.")
			preview["component_id"] = cid2
			preview["parameters"] = arguments.get("parameters", {})
		_:
			return _err("UNSUPPORTED_CAPABILITY", "No preview available for '%s'." % operation,
				"Supported: add_component, remove_component, connect_terminals, update_component_parameters.")
	preview["note"] = "This is a structural preview only; no electrical result is predicted."
	return _ok(preview)


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

func run_dc_simulation() -> Dictionary:
	var built: Dictionary = session.build_circuit()
	if built.ground_net != "0":
		return _err("NO_REFERENCE", "No reference (ground) node; cannot simulate.",
			"Add a Ground component.")
	var solver = CircuitSolver.new()
	var res: Dictionary = solver.solve_dc(built.circuit)
	_last_result = res
	_last_result["builder_warnings"] = built.warnings
	_last_result["pin_nets"] = built.pin_nets
	_sim_counter += 1
	_last_result_id = _sim_counter
	_last_result_kind = "dc"
	simulation_state = "completed" if bool(res.ok) else "failed"
	if not bool(res.ok):
		return _err("SIMULATION_FAILURE", String(res.get("error", "DC solve failed.")),
			"Check for floating nets, missing ground or conflicting sources.")
	return {
		"success": true,
		"revision": revision,
		"result_id": _last_result_id,
		"kind": "dc",
		"ok": true,
		"iterations": int(res.get("iterations", 0)),
		"node_voltages": (res.get("node_voltages", {}) as Dictionary).duplicate(true),
		"element_currents": (res.get("element_currents", {}) as Dictionary).duplicate(true),
		"element_voltages": (res.get("element_voltages", {}) as Dictionary).duplicate(true),
		"warnings": (res.get("warnings", []) as Array).duplicate(),
		"pin_nets": (built.pin_nets as Dictionary).duplicate(true),
	}


func run_transient_simulation(t_start: float = 0.0, t_stop: float = 0.5, dt: float = 1e-3, probes: Array = []) -> Dictionary:
	if t_stop <= t_start:
		return _err("INVALID_PARAMETER", "t_stop (%s) must be greater than t_start (%s)." % [t_stop, t_start],
			"Provide t_stop > t_start.")
	if dt <= 0.0:
		return _err("INVALID_PARAMETER", "dt must be positive.", "Provide a positive time step.")
	var nsteps := int(round((t_stop - t_start) / dt))
	if nsteps > MAX_TRANSIENT_STEPS:
		return _err("INVALID_PARAMETER",
			"Requested %d steps exceeds the %d limit." % [nsteps, MAX_TRANSIENT_STEPS],
			"Increase dt or shorten the interval.")
	var built: Dictionary = session.build_circuit()
	if built.ground_net != "0":
		return _err("NO_REFERENCE", "No reference (ground) node; cannot simulate.", "Add a Ground component.")
	var use_probes := probes
	if use_probes.is_empty():
		use_probes = _default_probes(built)
	var solver = CircuitSolver.new()
	var res: Dictionary = solver.solve_transient(built.circuit,
		{"t_stop": t_stop, "dt": dt, "probes": use_probes})
	_last_result = res
	_last_result["builder_warnings"] = built.warnings
	_last_result["pin_nets"] = built.pin_nets
	_last_samples = res.get("samples", []) if typeof(res.get("samples", [])) == TYPE_ARRAY else []
	_sim_counter += 1
	_last_result_id = _sim_counter
	_last_result_kind = "transient"
	simulation_state = "completed" if bool(res.ok) else "failed"
	if not bool(res.ok):
		return _err("SIMULATION_FAILURE", String(res.get("error", "Transient failed.")),
			"Reduce the interval, increase dt, or fix the circuit.")
	return {
		"success": true,
		"revision": revision,
		"result_id": _last_result_id,
		"kind": "transient",
		"ok": true,
		"samples": _last_samples.size(),
		"t_start": t_start,
		"t_stop": t_stop,
		"dt": dt,
		"iterations": int(res.get("iterations", 0)),
		"probe_keys": _probe_keys(_last_samples),
		"warnings": (res.get("warnings", []) as Array).duplicate(),
	}


func _default_probes(built: Dictionary) -> Array:
	var probes := []
	var nets := {}
	for cid in built.pin_nets:
		for n in built.pin_nets[cid]:
			nets[String(n)] = true
	nets["0"] = true
	var keys: Array = nets.keys()
	keys.sort()
	for n in keys:
		probes.append({"kind": "node", "target": n})
	return probes


func _probe_keys(samples: Array) -> Array:
	if samples.is_empty():
		return []
	var s: Dictionary = samples[0]
	var p: Dictionary = s.get("probes", {})
	var keys: Array = p.keys()
	keys.sort()
	return keys


func stop_simulation() -> Dictionary:
	simulation_state = "idle"
	return _ok({"state": "idle"})


func get_waveform_data(target: String, kind: String = "node", max_samples: int = 2000) -> Dictionary:
	if _last_result_kind != "transient" or simulation_state != "completed":
		return _err("NO_SIMULATION_RESULT", "No completed transient result is available.",
			"Run run_transient_simulation first.")
	if _last_samples.is_empty():
		return _err("NO_SIMULATION_RESULT", "The last transient produced no samples.", "Re-run the transient.")
	var k := "node" if kind == "node" else "current"
	var keys := _probe_keys(_last_samples)
	if not keys.has(target):
		return _err("UNKNOWN_NODE", "No probe '%s' in the last transient." % target,
			"Probe targets are: " + ", ".join(PackedStringArray(keys)))
	var lim: int = clampi(max_samples, 2, MAX_WAVEFORM_RETURN)
	var total := _last_samples.size()
	var stride: int = maxi(1, int(ceil(float(total) / float(lim))))
	var time := []
	var values := []
	var i := 0
	while i < total:
		var s: Dictionary = _last_samples[i]
		time.append(float(s.get("t", 0.0)))
		var pr: Dictionary = s.get("probes", {})
		values.append(float(pr.get(target, 0.0)))
		i += stride
	return _ok({
		"target": target,
		"kind": k,
		"unit": "V" if k == "node" else "A",
		"time_unit": "s",
		"result_id": _last_result_id,
		"total_samples": total,
		"returned_samples": time.size(),
		"stride": stride,
		"time": time,
		"values": values,
	})


# ---------------------------------------------------------------------------
# Persistence (sand-boxed)
# ---------------------------------------------------------------------------

func _approved_roots() -> Array:
	return [
		ProjectSettings.globalize_path("user://projects"),
		ProjectSettings.globalize_path("res://data/examples"),
	]


func _resolve_project_path(path: String, for_write: bool) -> Dictionary:
	var raw := path.strip_edges()
	if raw == "":
		if for_write:
			var base := ProjectSettings.globalize_path("user://projects")
			var nm := _slug(_project_name())
			return {"ok": true, "path": base.path_join(nm + ".cf3d")}
		return {"ok": false, "error": "A path is required."}
	if raw.contains(".."):
		return {"ok": false, "error": "Path traversal is not allowed."}
	var abs := raw
	if not raw.begins_with("res://") and not raw.begins_with("user://") and not raw.is_absolute_path():
		abs = ProjectSettings.globalize_path("user://projects").path_join(raw)
	elif raw.begins_with("res://") or raw.begins_with("user://"):
		abs = ProjectSettings.globalize_path(raw)
	abs = abs.replace("\\", "/")
	var roots := _approved_roots()
	var allowed := false
	for r in roots:
		var rr: String = String(r).replace("\\", "/")
		if abs == rr or abs.begins_with(rr + "/"):
			allowed = true
	if not allowed:
		return {"ok": false, "error": "Path is outside the approved project directory."}
	if for_write and abs.begins_with(ProjectSettings.globalize_path("res://").replace("\\", "/")):
		return {"ok": false, "error": "Writing inside the read-only application directory is not allowed."}
	return {"ok": true, "path": abs}


func _slug(name: String) -> String:
	var out := ""
	for ch in name.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "-" or ch == "_":
			out += ch
		elif ch == " ":
			out += "_"
	if out == "":
		out = "untitled"
	return out


func save_project(path: String = "", expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	var rp := _resolve_project_path(path, true)
	if not rp.ok:
		return _err("PERMISSION_DENIED", String(rp.error),
			"Save under user://projects (leave path empty to auto-name).")
	var full := String(rp.path)
	var dir := full.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var tmp := full + ".tmp"
	var w := Persistence.save_to_file(tmp, session.project)
	if not w.ok:
		return _err("INVALID_PROJECT", String(w.error), "Fix validation errors, then save.")
	var err := DirAccess.rename_absolute(tmp, full)
	if err != OK:
		return _err("OPERATION_FAILED", "Could not finalise the save (%d)." % err, "Check permissions.")
	session.mark_saved()
	_bump()
	return _ok({"path": full, "project_id": _project_id(), "revision": revision, "project_name": _project_name()})


func load_project(path: String = "", expected_revision = null) -> Dictionary:
	var cr := _check_revision(expected_revision)
	if not cr.success:
		return cr
	var rp := _resolve_project_path(path, false)
	if not rp.ok:
		return _err("PERMISSION_DENIED", String(rp.error),
			"Load from user://projects or a bundled example.")
	var full := String(rp.path)
	if not FileAccess.file_exists(full):
		return _err("INVALID_PROJECT_FILE", "File not found: %s" % full, "Check the path.")
	var r := Persistence.load_from_file(full)
	if not r.ok:
		return _err("INVALID_PROJECT_FILE", String(r.error), "Fix or choose another project.")
	session.project = r.project
	session.mark_untitled()
	session.last_result = {}
	session.waveforms = {}
	_last_result = {}
	_last_samples = []
	simulation_state = "idle"
	_bump()
	return _ok({"path": full, "project_id": _project_id(), "project_name": _project_name(),
		"revision": revision, "component_count": session.project.components.size()})


func list_example_projects() -> Dictionary:
	var dir := DirAccess.open("res://data/examples")
	var items := []
	if dir != null:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if not dir.current_is_dir() and fn.ends_with(".cf3d"):
				var r := Persistence.load_from_file(("res://data/examples/").path_join(fn))
				var meta := {}
				if r.ok:
					meta = r.project.get("metadata", {})
				items.append({
					"name": fn.get_basename(),
					"path": "res://data/examples/" + fn,
					"description": String(meta.get("description", "")),
					"component_count": (r.project.get("components", []) as Array).size() if r.ok else 0,
				})
			fn = dir.get_next()
		dir.list_dir_end()
	items.sort_custom(func(a, b): return String(a.name) < String(b.name))
	return _ok({"count": items.size(), "items": items})


func load_example_project(name: String) -> Dictionary:
	var listing := list_example_projects()
	for it in listing.items:
		if String(it.name) == name or String(it.path) == name or String(it.path).ends_with(name + ".cf3d"):
			return load_project(String(it.path), null)
	return _err("INVALID_PROJECT_FILE", "No bundled example named '%s'." % name,
		"Call list_example_projects for available names.")


# ---------------------------------------------------------------------------
# Parameter validation
# ---------------------------------------------------------------------------

func _validate_params(type: String, params: Dictionary, partial: bool = false) -> Array:
	var errors := []
	var def := ComponentDB.get_def(type)
	if def.is_empty():
		return ["unknown type '%s'" % type]
	var known: Dictionary = def.params
	for k in params:
		var key := String(k)
		if not known.has(key):
			errors.append("unknown parameter '%s' for %s" % [key, type])
			continue
		var val = params[k]
		if typeof(val) != TYPE_INT and typeof(val) != TYPE_FLOAT and typeof(val) != TYPE_BOOL:
			errors.append("parameter '%s' must be a number" % key)
			continue
		var f := float(val)
		if not is_finite(f):
			errors.append("parameter '%s' must be finite" % key)
			continue
		if key in ["r", "c", "l", "is", "n", "vdd", "rout"] and f <= 0.0:
			errors.append("parameter '%s' must be greater than zero" % key)
		if key == "position" and (f < 0.0 or f > 1.0):
			errors.append("parameter 'position' must be between 0 and 1")
		if key == "vth" and f < 0.0:
			errors.append("parameter 'vth' must not be negative")
	if not partial:
		for k in known:
			if not params.has(k):
				errors.append("missing parameter '%s'" % k)
	return errors


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

func _idempotent(operation_id: String) -> Dictionary:
	if operation_id == "":
		return {}
	if _op_cache.has(operation_id):
		var cached: Dictionary = _op_cache[operation_id].duplicate(true)
		cached["idempotent_replay"] = true
		return cached
	return {}


func _remember(operation_id: String, res: Dictionary) -> void:
	if operation_id == "":
		return
	if _op_cache.size() > 256:
		_op_cache.clear()
	_op_cache[operation_id] = res.duplicate(true)
