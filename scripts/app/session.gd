extends RefCounted
## CircuitForge 3D - application session state.
##
## Holds the editable design (components + wires + settings), the selection,
## undo/redo history and the latest simulation results. The 3D view and the UI
## are pure observers driven by the signals below.

signal changed
signal selection_changed(id)
signal simulation_updated(result)
signal status_message(text)

const Persistence = preload("res://scripts/persistence/persistence.gd")
const NetlistBuilder = preload("res://scripts/connectivity/netlist_builder.gd")
const Breadboard = preload("res://scripts/breadboard/breadboard.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")
const CircuitSolver = preload("res://scripts/simulation/solver.gd")

var project: Dictionary = {}
var selected_id := ""
var last_result: Dictionary = {}
var waveforms: Dictionary = {}
var last_error := ""

var _undo: Array = []
var _redo: Array = []
var _id_counters: Dictionary = {}
var _current_file := ""
var _dirty := false


func _init() -> void:
	project = Persistence.new_project()


func _design() -> Dictionary:
	return {
		"breadboard": project.breadboard,
		"components": project.components,
		"wires": project.wires,
		"simulation": project.simulation,
	}


func _snapshot() -> String:
	return JSON.stringify(_design(), "", true, true)


func _push_undo() -> void:
	_undo.append(_snapshot())
	if _undo.size() > 100:
		_undo.pop_front()
	_redo.clear()
	_dirty = true


func is_dirty() -> bool:
	return _dirty


func mark_saved() -> void:
	_dirty = false


func undo() -> void:
	if _undo.is_empty():
		return
	_redo.append(_snapshot())
	_restore(_undo.pop_back())
	_dirty = true
	status_message.emit("Undo")


func redo() -> void:
	if _redo.is_empty():
		return
	_undo.append(_snapshot())
	_restore(_redo.pop_back())
	_dirty = true
	status_message.emit("Redo")


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func _restore(snapshot: String) -> void:
	var d = JSON.parse_string(snapshot)
	if typeof(d) != TYPE_DICTIONARY:
		return
	project.breadboard = d.breadboard
	project.components = d.components
	project.wires = d.wires
	project.simulation = d.simulation
	if not _has_component(selected_id):
		selected_id = ""
	changed.emit()
	selection_changed.emit(selected_id)


func _has_component(id: String) -> bool:
	for c in project.components:
		if String(c.id) == id:
			return true
	return false


# ---------------------------------------------------------------------------
# Editing operations
# ---------------------------------------------------------------------------

func _gen_id(type: String) -> String:
	var prefix := "X"
	match type:
		"resistor": prefix = "R"
		"capacitor": prefix = "C"
		"inductor": prefix = "L"
		"vsource": prefix = "V"
		"isource": prefix = "I"
		"ground": prefix = "GND"
		"switch": prefix = "SW"
		"led": prefix = "D"
		"diode": prefix = "D"
		"zener": prefix = "DZ"
		"potentiometer": prefix = "RV"
		"seven_segment": prefix = "DS"
		"mcu_pin": prefix = "P"
		"and", "or", "not", "nand", "nor", "xor", "buffer": prefix = "U"
		_: prefix = type.substr(0, 1).to_upper()
	var n := int(_id_counters.get(prefix, 0)) + 1
	_id_counters[prefix] = n
	var id := "%s%d" % [prefix, n]
	var guard := 0
	while _has_component(id):
		n += 1
		_id_counters[prefix] = n
		id = "%s%d" % [prefix, n]
		guard += 1
		if guard > 10000:
			break
	return id


func add_component(type: String, holes: Array = [], params: Dictionary = {}, id: String = "") -> String:
	if not ComponentDB.exists(type):
		last_error = "Unknown component type '%s'." % type
		status_message.emit(last_error)
		return ""
	_push_undo()
	var pc := ComponentDB.pin_count(type)
	var use_params := params.duplicate(true)
	if use_params.is_empty():
		use_params = ComponentDB.default_params(type)
	var placed := holes.duplicate()
	while placed.size() < pc:
		placed.append("")
	var use_id := id
	if use_id == "" or _has_component(use_id):
		use_id = _gen_id(type)
	var comp := {
		"id": use_id,
		"type": type,
		"holes": placed,
		"params": use_params,
		"rotation": 0.0,
		"position": [0, 0, 0],
	}
	project.components.append(comp)
	selected_id = comp.id
	changed.emit()
	selection_changed.emit(selected_id)
	status_message.emit("Placed %s (%s)" % [comp.id, type])
	return comp.id


func remove_component(id: String) -> void:
	if not _has_component(id):
		return
	_push_undo()
	for i in range(project.components.size() - 1, -1, -1):
		if String(project.components[i].id) == id:
			project.components.remove_at(i)
	var kept := []
	for w in project.wires:
		if _wire_touches(w, id):
			continue
		kept.append(w)
	project.wires = kept
	if selected_id == id:
		selected_id = ""
	changed.emit()
	selection_changed.emit(selected_id)
	status_message.emit("Deleted %s" % id)


func _wire_touches(w: Dictionary, id: String) -> bool:
	for k in ["a", "b"]:
		var ep = w.get(k, {})
		if typeof(ep) == TYPE_DICTIONARY and String(ep.get("kind", "")) == "pin" and String(ep.get("component", "")) == id:
			return true
	return false


func duplicate_component(id: String) -> String:
	var src = null
	for c in project.components:
		if String(c.id) == id:
			src = c
			break
	if src == null:
		return ""
	_push_undo()
	var copy = src.duplicate(true)
	copy.id = _gen_id(String(src.type))
	# Offset the copy one row down if possible.
	var new_holes := []
	for h in copy.holes:
		new_holes.append(_shift_row(String(h), 1))
	copy.holes = new_holes
	project.components.append(copy)
	selected_id = copy.id
	changed.emit()
	selection_changed.emit(selected_id)
	status_message.emit("Duplicated %s -> %s" % [id, copy.id])
	return copy.id


func _shift_row(hole: String, dr: int) -> String:
	if hole == "" or hole.length() < 2:
		return hole
	var prefix := hole.substr(0, 2)
	if ["TP", "TM", "BP", "BM"].has(prefix):
		var r := int(hole.substr(2)) + dr
		if r < 1 or r > int(project.breadboard.rows):
			return hole
		return "%s%d" % [prefix, r]
	var col := hole.substr(0, 1)
	var row := int(hole.substr(1)) + dr
	if row < 1 or row > int(project.breadboard.rows):
		return hole
	return "%s%d" % [col, row]


func rotate_component(id: String, delta: float = PI * 0.5) -> void:
	var c = find_component(id)
	if c == null:
		return
	_push_undo()
	c.rotation = fmod(float(c.rotation) + delta, TAU)
	changed.emit()
	status_message.emit("Rotated %s" % id)


func set_param(id: String, key: String, value) -> void:
	var c = find_component(id)
	if c == null:
		return
	_push_undo()
	c.params[key] = value
	changed.emit()


## Atomically set several parameters on one component with a single undo step.
## Returns false (without mutating) when the component is unknown.
func set_params(id: String, values: Dictionary) -> bool:
	var c = find_component(id)
	if c == null:
		return false
	_push_undo()
	for k in values:
		c.params[String(k)] = values[k]
	changed.emit()
	status_message.emit("Updated %s" % id)
	return true


func move_component(id: String, holes: Array) -> void:
	var c = find_component(id)
	if c == null:
		return
	_push_undo()
	c.holes = holes.duplicate()
	changed.emit()


func add_wire(a: Dictionary, b: Dictionary) -> String:
	if a == b:
		return ""
	_push_undo()
	var wid := "W" + str(project.wires.size() + 1)
	var guard := 0
	while _has_wire(wid):
		guard += 1
		wid = "W" + str(project.wires.size() + 1 + guard)
	var w := {"id": wid, "a": a, "b": b}
	project.wires.append(w)
	changed.emit()
	status_message.emit("Wire %s added" % wid)
	return wid


func _has_wire(id: String) -> bool:
	for w in project.wires:
		if String(w.id) == id:
			return true
	return false


func clear() -> void:
	_push_undo()
	project.components = []
	project.wires = []
	selected_id = ""
	changed.emit()
	selection_changed.emit("")


func find_component(id: String):
	for c in project.components:
		if String(c.id) == id:
			return c
	return null


func select(id: String) -> void:
	selected_id = id if _has_component(id) else ""
	selection_changed.emit(selected_id)
	changed.emit()


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

func make_breadboard():
	return Breadboard.new(int(project.breadboard.get("rows", 30)), bool(project.breadboard.get("rail_split", false)))


func build_circuit() -> Dictionary:
	var builder = NetlistBuilder.new()
	return builder.build(make_breadboard(), project.components, project.wires)


func simulate_dc() -> Dictionary:
	var built := build_circuit()
	var solver = CircuitSolver.new()
	var res = solver.solve_dc(built.circuit)
	res["builder_warnings"] = built.warnings
	res["pin_nets"] = built.pin_nets
	last_result = res
	if res.ok:
		last_error = ""
		status_message.emit("DC simulation complete (%d iteration(s))." % int(res.get("iterations", 0)))
	else:
		last_error = String(res.error)
		status_message.emit("Simulation failed: " + last_error)
	simulation_updated.emit(res)
	return res


func run_transient() -> Dictionary:
	var built := build_circuit()
	var solver = CircuitSolver.new()
	var t_stop := float(project.simulation.get("t_stop", 0.5))
	var dt := float(project.simulation.get("dt", 1e-3))

	var probes := []
	var nets := {}
	for cid in built.pin_nets:
		for n in built.pin_nets[cid]:
			nets[n] = true
	nets["0"] = true
	for n in nets:
		probes.append({"kind": "node", "target": n})
	for el in built.circuit.elements:
		probes.append({"kind": "current", "target": el.id})

	var res = solver.solve_transient(built.circuit, {"t_stop": t_stop, "dt": dt, "probes": probes})
	res["builder_warnings"] = built.warnings
	res["pin_nets"] = built.pin_nets
	res["t_stop"] = t_stop
	res["dt"] = dt
	last_result = res
	if res.ok:
		_waveforms_from_samples(res.samples)
		var nk: Array = nets.keys()
		nk.sort()
		waveforms["node_keys"] = nk
		var ek := []
		for el in built.circuit.elements:
			ek.append(el.id)
		ek.sort()
		waveforms["current_keys"] = ek
		last_error = ""
		status_message.emit("Transient complete: %d samples over %s s." % [res.samples.size(), str(t_stop)])
	else:
		last_error = String(res.error)
		status_message.emit("Transient failed: " + last_error)
	simulation_updated.emit(res)
	return res


func _waveforms_from_samples(samples: Array) -> void:
	var time := []
	var series := {}
	for s in samples:
		time.append(s.t)
		for k in s.probes:
			if not series.has(k):
				series[k] = []
			series[k].append(s.probes[k])
	waveforms = {"time": time, "series": series}


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

func new_project() -> void:
	_push_undo()
	project = Persistence.new_project()
	selected_id = ""
	last_result = {}
	waveforms = {}
	_dirty = false
	changed.emit()
	selection_changed.emit("")
	status_message.emit("New project")


func load_project(path: String) -> bool:
	var r = Persistence.load_from_file(path)
	if not r.ok:
		last_error = String(r.error)
		status_message.emit("Open failed: " + last_error)
		return false
	project = r.project
	_current_file = path
	selected_id = ""
	last_result = {}
	waveforms = {}
	_dirty = false
	_id_counters.clear()
	changed.emit()
	selection_changed.emit("")
	status_message.emit("Opened " + path)
	return true


func mark_untitled() -> void:
	_current_file = ""


func save_project(path: String) -> bool:
	var r = Persistence.save_to_file(path, project)
	if not r.ok:
		last_error = String(r.error)
		status_message.emit("Save failed: " + last_error)
		return false
	_current_file = path
	_dirty = false
	status_message.emit("Saved " + path)
	return true


func current_file() -> String:
	return _current_file
