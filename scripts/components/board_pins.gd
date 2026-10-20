extends RefCounted
## CircuitForge 3D - board-aware pin metadata helpers.
##
## Development boards (Arduino / ESP / Pico / Pi / STM32 / Teensy / Android ...)
## are ordinary catalog entries whose `mounting` is `board` and whose pins carry
## a name, an electrical type and a header position. These helpers group and
## query those pins without inventing any hardware data: everything comes from
## the definition in `data/components/*.json`.
##
## Nothing here simulates a board. It only describes what the documented pin map
## says, so the UI, the API and the MCP server can present it honestly.

const ComponentDB = preload("res://scripts/components/component_db.gd")

## Pin types grouped for presentation.
const DIGITAL_TYPES := ["bidirectional", "input", "output", "digital", "clock", "open"]
const ANALOG_TYPES := ["analog"]
const POWER_TYPES := ["power"]
const GROUND_TYPES := ["ground"]

const GROUP_ORDER := ["digital", "analog", "power", "ground", "other"]


## True when the definition describes a development board / single-board computer.
static func is_board(type: String) -> bool:
	var def := ComponentDB.get_def(type)
	if def.is_empty():
		return false
	return String(def.get("mounting", "")) == "board" or String(def.get("category", "")) == "Board"


## All normalised pins of a board (empty for unknown types).
static func pinout(type: String) -> Array:
	return ComponentDB.get_def(type).get("pins", [])


## Every pin whose name matches exactly (e.g. several "GND" pins).
static func named(type: String, name: String) -> Array:
	var out := []
	for p in pinout(type):
		if String(p.get("name", "")) == name:
			out.append(p)
	return out


## The first pin with this name, or {} if there is none.
static func first(type: String, name: String) -> Dictionary:
	var hit := named(type, name)
	return hit[0] if hit.size() > 0 else {}


static func by_type(type: String, pin_type: String) -> Array:
	var out := []
	for p in pinout(type):
		if String(p.get("type", "")) == pin_type:
			out.append(p)
	return out


static func _names(pins: Array) -> Array:
	var out := []
	for p in pins:
		out.append(String(p.get("name", "")))
	return out


## Pins grouped into digital / analog / power / ground / other (lists of names).
static func groups(type: String) -> Dictionary:
	var g := {"digital": [], "analog": [], "power": [], "ground": [], "other": []}
	for p in pinout(type):
		var pt := String(p.get("type", "passive"))
		if pt in GROUND_TYPES:
			g["ground"].append(String(p.get("name", "")))
		elif pt in POWER_TYPES:
			g["power"].append(String(p.get("name", "")))
		elif pt in ANALOG_TYPES:
			g["analog"].append(String(p.get("name", "")))
		elif pt in DIGITAL_TYPES:
			g["digital"].append(String(p.get("name", "")))
		else:
			g["other"].append(String(p.get("name", "")))
	return g


static func counts(type: String) -> Dictionary:
	var g := groups(type)
	return {
		"total": pinout(type).size(),
		"digital": g["digital"].size(),
		"analog": g["analog"].size(),
		"power": g["power"].size(),
		"ground": g["ground"].size(),
		"other": g["other"].size(),
	}


## The `board_info` block of a definition (empty when the type is unknown).
## It carries the documented identity: MCU part, core, clock, logic level,
## USB connector and the programming interface - plus the fixed peripheral
## mappings (`interfaces`) the manufacturer documents, e.g.
## {"i2c": ["A4", "A5"], "spi": ["D10", "D11", "D12", "D13"]}.
static func board_info(type: String) -> Dictionary:
	var def := ComponentDB.get_def(type)
	var bi: Dictionary = def.get("board_info", {})
	return bi if typeof(bi) == TYPE_DICTIONARY else {}


## The documented peripheral-to-header-pin mappings, or {}.
static func interfaces(type: String) -> Dictionary:
	return board_info(type).get("interfaces", {})


## The named pins of one documented interface ("uart", "i2c", "spi", ...).
static func interface_pins(type: String, bus: String) -> Array:
	var out: Array = interfaces(type).get(bus, [])
	return out if typeof(out) == TYPE_ARRAY else []


## Consistency checks for a board's pin map (empty list = fine).
static func issues(type: String) -> Array:
	var out := []
	if not is_board(type):
		return ["not a board"]
	var pins := pinout(type)
	if pins.is_empty():
		out.append("no pins defined")
		return out
	var c := counts(type)
	if c["ground"] == 0:
		out.append("no ground pin")
	if c["power"] == 0:
		out.append("no power pin")
	var seen := {}
	for p in pins:
		var pid := String(p.get("id", ""))
		if pid == "":
			out.append("pin missing id")
		elif seen.has(pid):
			out.append("duplicate pin id '%s'" % pid)
		seen[pid] = true
	if c["digital"] == 0 and c["analog"] == 0:
		out.append("no digital or analog pins")
	# A documented board_info block must be coherent when present: interface
	# pins have to exist in the pinout and the logic level must be stated.
	# board_info itself is optional (a board can be pinout-only).
	var bi := board_info(type)
	if not bi.is_empty():
		var names := _names(pins)
		for bus in interfaces(type):
			for pn in interface_pins(type, String(bus)):
				if not names.has(String(pn)):
					out.append("%s interface names missing pin '%s'" % [bus, pn])
		# Logic level must be a documented operating voltage, not a guess.
		var lv: Variant = bi.get("logic_voltage", 0.0)
		if not (typeof(lv) in [TYPE_FLOAT, TYPE_INT]) or float(lv) <= 0.0:
			out.append("board_info.logic_voltage must be positive")
	return out


## A one-object presentation of a board's pin map (used by the API / MCP).
static func summary(type: String) -> Dictionary:
	var def := ComponentDB.get_def(type)
	if def.is_empty():
		return {}
	var pins := []
	for p in pinout(type):
		var e := {
			"id": String(p.get("id", "")),
			"name": String(p.get("name", "")),
			"type": String(p.get("type", "passive")),
			"number": int(p.get("number", 0)),
		}
		if p.has("voltage"):
			e["voltage"] = float(p.get("voltage"))
		pins.append(e)
	return {
		"type": type,
		"name": String(def.get("name", "")),
		"manufacturer": String(def.get("manufacturer", "")),
		"part_number": String(def.get("part_number", "")),
		"arduino_compatible": bool(def.get("arduino_compatible", false)),
		"recommended_voltage": def.get("recommended_voltage", {}),
		"pin_count": pins.size(),
		"pins": pins,
		"groups": groups(type),
		"counts": counts(type),
		"issues": issues(type),
		# Documented identity + capability split (see board_info()).
		"board_info": board_info(type),
		"interfaces": interfaces(type),
		# Honest capability vocabulary: the MCU itself is never simulated in the
		# netlist; firmware execution is the optional external backend's job.
		"simulation_status": String(def.get("simulation_status", "")),
		"simulation_backend": String(def.get("simulation_backend", "")),
		"notes": String(def.get("notes", "")),
		"references": def.get("references", []),
	}


## All board type ids in the catalog, sorted.
static func all_boards() -> Array:
	var out := []
	for type in ComponentDB.all_defs().keys():
		if is_board(String(type)):
			out.append(String(type))
	out.sort()
	return out
