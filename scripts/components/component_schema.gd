extends RefCounted
## CircuitForge 3D - unified component catalog schema (v2).
##
## One definition format is shared by the renderer, the connectivity layer, the
## solver, the persistence layer and the MCP server. Definitions live in JSON
## files under data/components/ and are normalised + validated here.
##
## Nothing in this file knows about any specific component: it only defines and
## enforces the shape of a definition.

const SCHEMA_VERSION := 2

## Implementation status vocabulary (see docs/catalog/schema.md).
const STATUSES := ["full", "partial", "visual", "external", "planned"]
const STATUS_LABELS := {
	"full": "Fully simulated",
	"partial": "Partially simulated",
	"visual": "Visual model only",
	"external": "External backend required",
	"planned": "Not yet implemented",
}

## Electrical type of a terminal.
const PIN_TYPES := [
	"passive", "power", "ground", "input", "output", "bidirectional",
	"analog", "digital", "clock", "open", "nc",
]

## Rough physical form factor (used only for grouping / search).
const MOUNTINGS := ["tht", "smd", "module", "board", "device", "virtual"]


static func status_label(status: String) -> String:
	return String(STATUS_LABELS.get(status, status))


static func is_simulatable(status: String) -> bool:
	return status == "full" or status == "partial"


# ---------------------------------------------------------------------------
# Normalisation
# ---------------------------------------------------------------------------

static func _string_array(v) -> Array:
	var out := []
	if typeof(v) == TYPE_ARRAY:
		for x in v:
			out.append(String(x))
	return out


static func _normalize_pins(v) -> Array:
	var out := []
	if typeof(v) != TYPE_ARRAY:
		return out
	for i in v.size():
		var p = v[i]
		if typeof(p) == TYPE_STRING:
			out.append({"id": String(p), "name": String(p), "type": "passive", "number": i + 1})
		elif typeof(p) == TYPE_DICTIONARY:
			var pd := {}
			pd["id"] = String(p.get("id", str(i + 1)))
			pd["name"] = String(p.get("name", pd["id"]))
			pd["type"] = String(p.get("type", "passive"))
			pd["number"] = int(p.get("number", i + 1))
			if p.has("voltage"):
				pd["voltage"] = float(p.get("voltage"))
			out.append(pd)
	return out


static func _normalize_params(v) -> Dictionary:
	var out := {}
	if typeof(v) != TYPE_DICTIONARY:
		return out
	for key in v.keys():
		var spec = v[key]
		if typeof(spec) == TYPE_DICTIONARY:
			var s := {}
			s["default"] = spec.get("default", 0.0)
			s["unit"] = String(spec.get("unit", ""))
			s["label"] = String(spec.get("label", String(key)))
			if spec.has("min"):
				s["min"] = spec.get("min")
			if spec.has("max"):
				s["max"] = spec.get("max")
			if spec.has("options"):
				s["options"] = spec.get("options")
			out[String(key)] = s
		else:
			out[String(key)] = {"default": spec, "unit": "", "label": String(key)}
	return out


## Documented board identity + peripheral mappings (development boards).
## Everything is documentation data - never a guess: MCU part number, core,
## clock, logic level, USB connector, programming interface, and the fixed
## interface-to-header-pin mappings the manufacturer documents, e.g.
## {"i2c": ["A4", "A5"], "spi": ["D10", "D11", "D12", "D13"]}.
static func _normalize_board_info(v) -> Dictionary:
	var o := {}
	if typeof(v) != TYPE_DICTIONARY:
		return o
	for key in ["mcu", "core", "usb", "programming"]:
		o[key] = String(v.get(key, ""))
	if v.has("cpu_mhz"):
		o["cpu_mhz"] = float(v.get("cpu_mhz"))
	if v.has("logic_voltage"):
		o["logic_voltage"] = float(v.get("logic_voltage"))
	var ifc: Variant = v.get("interfaces", {})
	if typeof(ifc) == TYPE_DICTIONARY:
		var out := {}
		for bus in ifc.keys():
			var pins: Variant = ifc[bus]
			if typeof(pins) == TYPE_ARRAY:
				var arr := []
				for p in pins:
					arr.append(String(p))
				out[String(bus)] = arr
		o["interfaces"] = out
	return o


## Return a fully-populated definition dictionary (all keys present).
static func normalize(d: Dictionary) -> Dictionary:
	var o := {}
	o["schema_version"] = int(d.get("schema_version", SCHEMA_VERSION))
	o["id"] = String(d.get("id", ""))
	o["name"] = String(d.get("name", o["id"]))
	o["category"] = String(d.get("category", "Uncategorized"))
	o["subcategory"] = String(d.get("subcategory", ""))
	o["manufacturer"] = String(d.get("manufacturer", ""))
	o["part_number"] = String(d.get("part_number", ""))
	o["description"] = String(d.get("description", ""))
	o["keywords"] = _string_array(d.get("keywords", []))
	o["aliases"] = _string_array(d.get("aliases", []))
	o["package"] = String(d.get("package", ""))
	o["mounting"] = String(d.get("mounting", ""))
	o["dimensions_mm"] = d.get("dimensions_mm", {})
	o["pins"] = _normalize_pins(d.get("pins", []))
	o["params"] = _normalize_params(d.get("params", {}))
	o["logic_fn"] = String(d.get("logic_fn", ""))
	o["simulation_status"] = String(d.get("simulation_status", "full"))
	o["simulation_models"] = _string_array(d.get("simulation_models", []))
	o["simulation_backend"] = String(d.get("simulation_backend", ""))
	o["firmware_required"] = bool(d.get("firmware_required", false))
	o["recommended_voltage"] = d.get("recommended_voltage", {})
	o["max_ratings"] = d.get("max_ratings", {})
	o["protocols"] = _string_array(d.get("protocols", []))
	o["interfaces"] = _string_array(d.get("interfaces", []))
	o["arduino_compatible"] = bool(d.get("arduino_compatible", false))
	o["board_info"] = _normalize_board_info(d.get("board_info", {}))
	o["model"] = d.get("model", {})
	o["notes"] = String(d.get("notes", ""))
	o["references"] = _string_array(d.get("references", []))
	o["example_circuits"] = _string_array(d.get("example_circuits", []))
	o["provenance"] = String(d.get("provenance", "original"))
	return o


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

## Validate a single (already-normalised) definition. Returns a list of errors.
static func validate(d: Dictionary) -> Array:
	var errs := []
	if String(d.get("id", "")) == "":
		errs.append("missing id")
	if String(d.get("name", "")) == "":
		errs.append("missing name")
	if String(d.get("category", "")) == "":
		errs.append("missing category")
	var pins: Array = d.get("pins", [])
	if pins.is_empty():
		errs.append("no pins defined")
	var seen := {}
	for p in pins:
		var pid := String(p.get("id", ""))
		if pid == "":
			errs.append("pin missing id")
			continue
		if seen.has(pid):
			errs.append("duplicate pin id '%s'" % pid)
		seen[pid] = true
		var pt := String(p.get("type", "passive"))
		if not PIN_TYPES.has(pt):
			errs.append("pin '%s' has unknown type '%s'" % [pid, pt])
	var st := String(d.get("simulation_status", ""))
	if not STATUSES.has(st):
		errs.append("invalid simulation_status '%s'" % st)
	var params = d.get("params", {})
	if typeof(params) == TYPE_DICTIONARY:
		for k in params.keys():
			if not (params[k] is Dictionary) or not params[k].has("default"):
				errs.append("parameter '%s' has no default" % String(k))
	return errs


## Validate a whole catalog keyed by id. Returns a list of errors (already
## including duplicate ids).
static func validate_catalog(defs: Dictionary) -> Array:
	var errs := []
	for id in defs.keys():
		for e in validate(defs[id]):
			errs.append("%s: %s" % [id, e])
		if String(defs[id].get("id", "")) != String(id):
			errs.append("%s: id key does not match definition id" % id)
	return errs
