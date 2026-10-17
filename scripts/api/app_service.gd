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
			"set_pin_levels", "apply_firmware_pins", "apply_firmware_device", "move_component", "connect_terminals", "disconnect_connection"],
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


func run_firmware(hex_path: String, ms: int = 2000, attach_devices: bool = false, analog_map: Dictionary = {}) -> Dictionary:
	var cap := FirmwareBackend.capabilities()
	if not bool(cap.get("available", false)):
		return _err("FIRMWARE_UNAVAILABLE",
			"Firmware execution is unavailable: " + ", ".join(PackedStringArray(cap.get("unavailable_reasons", []))),
			"Install Node.js (or set CIRCUITFORGE_NODE) and keep firmware/harness/run.mjs.")
	var devices := _firmware_devices() if attach_devices else []
	var adc := {}
	var analog_applied := []
	if not analog_map.is_empty():
		var built: Dictionary = session.build_circuit()
		if built.ground_net != "0":
			return _err("NO_REFERENCE", "Analog inputs need a reference (ground) node.",
				"Add a Ground component.")
		var solver = CircuitSolver.new()
		var res: Dictionary = solver.solve_dc(built.circuit)
		if not bool(res.get("ok", false)):
			return _err("SIMULATION_FAILURE", "Could not solve to read the analog inputs: " + String(res.get("error", "")),
				"Check the circuit for floating nets or conflicting sources.")
		var volts_by_node: Dictionary = res.get("node_voltages", {})
		for key in analog_map.keys():
			var ch := _adc_channel(key)
			var cid := String(analog_map[key])
			var c = session.find_component(cid)
			if c == null or String(c.type) != "mcu_analog_in":
				analog_applied.append({"channel": String(key), "component_id": cid, "skipped": "not an mcu_analog_in"})
				continue
			var nets: Array = (built.pin_nets as Dictionary).get(cid, [])
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
		note = "Closed loop: attached bus devices can be read/written and firmware ADC channels read the solved node voltages; no analog OUTPUT to the circuit."
	elif attach_devices:
		note = "Closed bus loop: attached devices (from the circuit) can be read/written by firmware; analog/ADC feedback still absent."
	elif not analog_map.is_empty():
		note = "Closed analog loop: firmware ADC channels read the solved node voltages; no analog output to the circuit."
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
		"devices": r.get("devices", []),
		"attached_devices": devices.size(),
		"adc": r.get("adc", {}),
		"analog_inputs": analog_applied,
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


## Build harness device specs from the circuit's device components so firmware can
## read (and write) them. Currently only the PCF8574 expander.
func _firmware_devices() -> Array:
	var out := []
	var comps: Array = session.project.get("components", []) if session != null else []
	for c in comps:
		if String(c.get("type", "")) != "pcf8574":
			continue
		var p: Dictionary = c.get("params", {})
		out.append({
			"kind": "pcf8574",
			"address": int(p.get("address", 39)) & 0x7F,
			"state": int(p.get("state", 0)) & 0xFF,
			"inputs": int(p.get("inputs", 0)) & 0xFF,
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
	if ctype != "pcf8574":
		return _err("UNSUPPORTED_DEVICE",
			"Component '%s' is '%s', which has no firmware device model." % [component_id, ctype],
			"Only 'pcf8574' is supported for now.")
	var cap := FirmwareBackend.capabilities()
	if not bool(cap.get("available", false)):
		return _err("FIRMWARE_UNAVAILABLE",
			"Firmware execution is unavailable: " + ", ".join(PackedStringArray(cap.get("unavailable_reasons", []))),
			"Install Node.js (or set CIRCUITFORGE_NODE) and keep firmware/harness/run.mjs.")
	var r := FirmwareBackend.run_hex(hex_path, ms)
	if not bool(r.get("ok", false)):
		return _err("FIRMWARE_ERROR", String(r.get("error", "firmware run failed")),
			"Compile a sketch to Intel HEX (arduino-cli compile --fqbn arduino:avr:uno) and pass its path.")
	var addr := int(c.get("params", {}).get("address", 39)) & 0x7F
	var byte := FirmwareBackend.last_i2c_write_byte(r.get("i2c", []), addr)
	if byte < 0:
		return _err("NO_DEVICE_WRITE",
			"Firmware did not write to I2C address 0x%02X." % addr,
			"Check the sketch and the device 'address' parameter.")
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
