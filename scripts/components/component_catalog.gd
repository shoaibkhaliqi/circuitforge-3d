extends RefCounted
## CircuitForge 3D - data-driven component catalog.
##
## Loads component definitions from JSON files under data/components/, normalises
## and validates them, and exposes search / filter / facet queries used by the UI
## and the MCP server. Metadata only: 3D models are built lazily by the renderer.
##
## This is the single source of truth for component definitions. Nothing is
## hardcoded in the GUI.

const Schema = preload("res://scripts/components/component_schema.gd")

const DIR := "res://data/components"
## Fallback file list for platforms/builds where res:// directory listing is not
## available (e.g. some exports). Kept in sync with the files on disk.
const MANIFEST := [
	"passive.json", "sources.json", "semiconductor.json", "logic.json",
	"analog_ic.json", "displays.json", "sensors.json", "communication.json",
	"power.json", "motors.json", "connectors.json", "instruments.json",
	"boards.json", "android.json", "mobile_devices.json", "virtual.json",
]

static var _defs: Dictionary = {}
static var _loaded := false
static var _errors: Array = []


static func reset() -> void:
	_defs = {}
	_loaded = false
	_errors = []


static func _list_files() -> Array:
	var files := []
	var dir := DirAccess.open(DIR)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and f.ends_with(".json") and f != "schema.json":
				files.append(DIR + "/" + f)
			f = dir.get_next()
		dir.list_dir_end()
	if files.is_empty():
		for name in MANIFEST:
			files.append(DIR + "/" + name)
	files.sort()
	return files


static func load_all(force: bool = false) -> void:
	if _loaded and not force:
		return
	_defs = {}
	_errors = []
	var loaded_any := false
	for path in _list_files():
		if not FileAccess.file_exists(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		if text.strip_edges() == "":
			_errors.append("%s: empty file" % path)
			continue
		var parsed = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			_errors.append("%s: root is not a JSON object" % path)
			continue
		var comps = parsed.get("components", [])
		if typeof(comps) != TYPE_ARRAY:
			_errors.append("%s: 'components' is not an array" % path)
			continue
		for raw in comps:
			if typeof(raw) != TYPE_DICTIONARY:
				_errors.append("%s: component entry is not an object" % path)
				continue
			var d := Schema.normalize(raw)
			var id := String(d.id)
			if id == "":
				_errors.append("%s: component without id" % path)
				continue
			if _defs.has(id):
				_errors.append("duplicate component id '%s' (%s)" % [id, path])
				continue
			var verrs := Schema.validate(d)
			if not verrs.is_empty():
				_errors.append("%s: %s -> %s" % [path, id, ", ".join(verrs)])
			_defs[id] = d
			loaded_any = true
	if not loaded_any:
		_defs = _fallback_defs()
	_loaded = true


static func defs() -> Dictionary:
	load_all()
	return _defs


static func errors() -> Array:
	load_all()
	return _errors.duplicate()


static func count() -> int:
	return defs().size()


static func has(id: String) -> bool:
	return defs().has(id)


static func get_def(id: String) -> Dictionary:
	return defs().get(id, {})


static func ids() -> Array:
	var out := defs().keys()
	out.sort()
	return out


# ---------------------------------------------------------------------------
# Facets + search
# ---------------------------------------------------------------------------

static func _collect(key: String) -> Array:
	var seen := {}
	for id in defs():
		var d: Dictionary = defs()[id]
		if key == "category" or key == "subcategory" or key == "package" or key == "mounting" or key == "manufacturer" or key == "simulation_status":
			var v := String(d.get(key, ""))
			if v != "":
				seen[v] = true
		elif key == "protocols" or key == "interfaces":
			for v2 in d.get(key, []):
				seen[String(v2)] = true
	var out := seen.keys()
	out.sort()
	return out


static func facets() -> Dictionary:
	return {
		"categories": _collect("category"),
		"subcategories": _collect("subcategory"),
		"packages": _collect("package"),
		"mountings": _collect("mounting"),
		"manufacturers": _collect("manufacturer"),
		"statuses": _collect("simulation_status"),
		"protocols": _collect("protocols"),
		"interfaces": _collect("interfaces"),
	}


static func _matches_query(d: Dictionary, q: String) -> bool:
	if q == "":
		return true
	var hay := String(d.get("name", "")) + " " + String(d.get("id", "")) + " " \
			+ String(d.get("part_number", "")) + " " + String(d.get("manufacturer", "")) + " " \
			+ String(d.get("category", "")) + " " + String(d.get("subcategory", "")) + " " \
			+ String(d.get("description", ""))
	for k in d.get("keywords", []):
		hay += " " + String(k)
	for a in d.get("aliases", []):
		hay += " " + String(a)
	hay = hay.to_lower()
	for token in q.to_lower().split(" ", false):
		if not hay.contains(token):
			return false
	return true


static func _matches_filters(d: Dictionary, f: Dictionary) -> bool:
	if f.has("category") and String(f.category) != "" and String(d.category) != String(f.category):
		return false
	if f.has("subcategory") and String(f.subcategory) != "" and String(d.subcategory) != String(f.subcategory):
		return false
	if f.has("package") and String(f.package) != "" and String(d.package) != String(f.package):
		return false
	if f.has("mounting") and String(f.mounting) != "" and String(d.mounting) != String(f.mounting):
		return false
	if f.has("manufacturer") and String(f.manufacturer) != "" and String(d.manufacturer) != String(f.manufacturer):
		return false
	if f.has("status") and String(f.status) != "" and String(d.simulation_status) != String(f.status):
		return false
	if f.has("protocol") and String(f.protocol) != "" and not (d.protocols as Array).has(String(f.protocol)):
		return false
	if f.has("interface") and String(f.interface) != "" and not (d.interfaces as Array).has(String(f.interface)):
		return false
	if f.has("arduino_compatible") and bool(f.arduino_compatible) and not bool(d.arduino_compatible):
		return false
	if f.has("simulatable_only") and bool(f.simulatable_only) and not Schema.is_simulatable(String(d.simulation_status)):
		return false
	return true


## Search the catalog. Returns a dictionary {"count", "items": [id...]} with
## pagination applied (limit 0 = no limit).
static func search(query: String = "", filters: Dictionary = {}) -> Dictionary:
	var hits := []
	for id in ids():
		var d: Dictionary = defs()[id]
		if _matches_query(d, query) and _matches_filters(d, filters):
			hits.append(id)
	var total := hits.size()
	var offset: int = max(0, int(filters.get("offset", 0)))
	var limit: int = int(filters.get("limit", 0))
	if offset > 0:
		hits = hits.slice(offset)
	if limit > 0 and hits.size() > limit:
		hits = hits.slice(0, limit)
	return {"count": total, "items": hits}


# ---------------------------------------------------------------------------
# Built-in fallback (used only if no catalog file could be loaded)
# ---------------------------------------------------------------------------

static func _fallback_defs() -> Dictionary:
	var raw := {
		"components": [
			{"id": "resistor", "name": "Resistor", "category": "Passive", "subcategory": "Resistors",
				"pins": ["1", "2"], "description": "Limits current. V = I x R.",
				"params": {"r": {"default": 1000.0, "unit": "Ohm", "label": "Resistance"}}},
			{"id": "capacitor", "name": "Capacitor", "category": "Passive", "subcategory": "Capacitors",
				"pins": ["1", "2"], "description": "Stores charge. Blocks DC, passes AC.",
				"params": {"c": {"default": 100e-6, "unit": "F", "label": "Capacitance"}}},
			{"id": "inductor", "name": "Inductor", "category": "Passive", "subcategory": "Inductors",
				"pins": ["1", "2"], "description": "Stores energy in a magnetic field.",
				"params": {"l": {"default": 10e-3, "unit": "H", "label": "Inductance"}}},
			{"id": "potentiometer", "name": "Potentiometer", "category": "Passive", "subcategory": "Variable",
				"pins": ["1", "W", "3"], "description": "Variable resistor with a wiper.",
				"params": {"r": {"default": 10000.0, "unit": "Ohm", "label": "Total resistance"},
					"position": {"default": 0.5, "unit": "", "label": "Wiper position (0-1)"}}},
			{"id": "vsource", "name": "DC Voltage Source", "category": "Sources", "pins": ["+", "-"],
				"params": {"v": {"default": 5.0, "unit": "V", "label": "Voltage"}}},
			{"id": "isource", "name": "DC Current Source", "category": "Sources", "pins": ["+", "-"],
				"params": {"i": {"default": 0.01, "unit": "A", "label": "Current"}}},
			{"id": "ground", "name": "Ground", "category": "Sources", "pins": ["GND"]},
			{"id": "switch", "name": "Switch", "category": "Passive", "subcategory": "Switches",
				"pins": ["1", "2"], "params": {"closed": {"default": false, "unit": "", "label": "Closed"}}},
			{"id": "led", "name": "LED", "category": "Semiconductor", "pins": ["A", "K"]},
			{"id": "diode", "name": "Diode", "category": "Semiconductor", "pins": ["A", "K"]},
			{"id": "zener", "name": "Zener Diode", "category": "Semiconductor", "pins": ["A", "K"]},
		],
	}
	var out := {}
	for raw_def in raw["components"]:
		var d := Schema.normalize(raw_def)
		out[String(d.id)] = d
	return out
