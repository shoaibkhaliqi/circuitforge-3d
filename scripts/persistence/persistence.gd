extends RefCounted
## CircuitForge 3D - versioned JSON project persistence.
##
## The saved document is the *design* (components + wires + settings), never the
## solver output. Electrical connections are stored as stable component/pin/hole
## identifiers, not screen coordinates.

const SCHEMA_VERSION := 1
const FORMAT := "circuitforge3d"

const ComponentDB = preload("res://scripts/components/component_db.gd")
const Breadboard = preload("res://scripts/breadboard/breadboard.gd")


static func new_project(name: String = "Untitled") -> Dictionary:
	return {
		"format": FORMAT,
		"schema_version": SCHEMA_VERSION,
		"metadata": {
			"name": name,
			"created": Time.get_datetime_string_from_system(),
			"modified": Time.get_datetime_string_from_system(),
			"app_version": "0.1.0",
		},
		"breadboard": {"rows": 30, "rail_split": false},
		"components": [],
		"wires": [],
		"simulation": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		"instruments": {},
	}


static func save_to_file(path: String, project: Dictionary) -> Dictionary:
	if project.has("metadata"):
		project.metadata["modified"] = Time.get_datetime_string_from_system()
	var v := validate(project)
	if not v.ok:
		return {"ok": false, "error": "Refusing to save invalid project: " + "; ".join(v.errors)}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Cannot open '%s' for writing (%s)." % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(JSON.stringify(project, "\t", true, true))
	f.close()
	return {"ok": true, "error": "", "path": path}


static func load_from_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: %s" % path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Cannot open '%s' (%s)." % [path, error_string(FileAccess.get_open_error())]}
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "error": "Corrupted project file (invalid JSON at line %d): %s" % [json.get_error_line(), path]}
	var parsed = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "Project file root is not an object."}
	var migrated := migrate(parsed)
	var v := validate(migrated)
	if not v.ok:
		return {"ok": false, "error": "Project validation failed: " + "; ".join(v.errors), "warnings": v.warnings}
	return {"ok": true, "error": "", "project": migrated, "warnings": v.warnings}


static func migrate(project: Dictionary) -> Dictionary:
	var ver := int(project.get("schema_version", 0))
	while ver < SCHEMA_VERSION:
		match ver:
			0:
				# v0 -> v1: ensure containers exist.
				if not project.has("breadboard"):
					project["breadboard"] = {"rows": 30, "rail_split": false}
				if not project.has("components"):
					project["components"] = []
				if not project.has("wires"):
					project["wires"] = []
				if not project.has("simulation"):
					project["simulation"] = {"mode": "dc", "t_stop": 0.5, "dt": 0.001}
			_:
				break
		ver += 1
		project["schema_version"] = ver
	if not project.has("format"):
		project["format"] = FORMAT
	if not project.has("metadata"):
		project["metadata"] = {"name": "Untitled"}
	return project


## Validate structure and cross-references. Returns {ok, errors, warnings}.
static func validate(project: Dictionary) -> Dictionary:
	var errors := []
	var warnings := []
	if typeof(project) != TYPE_DICTIONARY:
		return {"ok": false, "errors": ["Project is not a dictionary."], "warnings": []}
	if not project.has("components") or typeof(project["components"]) != TYPE_ARRAY:
		errors.append("missing 'components' array")
	if not project.has("wires") or typeof(project["wires"]) != TYPE_ARRAY:
		errors.append("missing 'wires' array")
	if errors.size() > 0:
		return {"ok": false, "errors": errors, "warnings": warnings}

	var bb_conf: Dictionary = project.get("breadboard", {})
	var bb = Breadboard.new(int(bb_conf.get("rows", 30)), bool(bb_conf.get("rail_split", false)))

	var ids := {}
	for c in project["components"]:
		if typeof(c) != TYPE_DICTIONARY:
			errors.append("component entry is not an object")
			continue
		var cid := String(c.get("id", ""))
		var ctype := String(c.get("type", ""))
		if cid == "":
			errors.append("component with empty id")
			continue
		if ids.has(cid):
			errors.append("duplicate component id '%s'" % cid)
		ids[cid] = true
		if not ComponentDB.exists(ctype):
			errors.append("component '%s' has unknown type '%s'" % [cid, ctype])
			continue
		var holes: Array = c.get("holes", [])
		var pc := ComponentDB.pin_count(ctype)
		if holes.size() != pc:
			warnings.append("component '%s' has %d holes for %d pins" % [cid, holes.size(), pc])
		for h in holes:
			var hs := String(h)
			if hs != "" and not bb.is_valid_hole(hs):
				errors.append("component '%s' references invalid hole '%s'" % [cid, hs])

	for w in project["wires"]:
		if typeof(w) != TYPE_DICTIONARY:
			errors.append("wire entry is not an object")
			continue
		for key in ["a", "b"]:
			var ep = w.get(key, null)
			if typeof(ep) != TYPE_DICTIONARY:
				errors.append("wire '%s' missing endpoint '%s'" % [String(w.get("id", "?")), key])
				continue
			if String(ep.get("kind", "")) == "pin":
				var ccid := String(ep.get("component", ""))
				if not ids.has(ccid):
					errors.append("wire '%s' references unknown component '%s'" % [String(w.get("id", "?")), ccid])
			elif String(ep.get("kind", "")) == "hole":
				if not bb.is_valid_hole(String(ep.get("id", ""))):
					errors.append("wire '%s' references invalid hole '%s'" % [String(w.get("id", "?")), String(ep.get("id", ""))])
			else:
				errors.append("wire '%s' has unknown endpoint kind" % String(w.get("id", "?")))

	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings}
