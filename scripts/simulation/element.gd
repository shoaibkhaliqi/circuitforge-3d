extends RefCounted
## CircuitForge 3D - a single two-terminal (or multi-terminal) circuit element.
##
## Elements are pure data: identity, type, pin->net mapping and parameters.
## They carry no scene-tree references. Current sign convention:
## the element current I flows from pin[0] to pin[1] *through* the element.

var id: String = ""
var type: String = ""
var nets: Array = []        # pin net names, indexed by pin number
var pin_names: Array = []   # human-readable pin labels (optional)
var params: Dictionary = {}


func pin_count() -> int:
	return nets.size()


func clone():
	var e = get_script().new()
	e.id = id
	e.type = type
	e.nets = nets.duplicate()
	e.pin_names = pin_names.duplicate()
	e.params = params.duplicate(true)
	return e


func to_dict() -> Dictionary:
	return {
		"id": id,
		"type": type,
		"nets": nets.duplicate(),
		"pin_names": pin_names.duplicate(),
		"params": params.duplicate(true),
	}


static func from_dict(d: Dictionary):
	var script = load("res://scripts/simulation/element.gd")
	var e = script.new()
	e.id = String(d.get("id", ""))
	e.type = String(d.get("type", ""))
	e.nets = (d.get("nets", []) as Array).duplicate()
	e.pin_names = (d.get("pin_names", []) as Array).duplicate()
	e.params = (d.get("params", {}) as Dictionary).duplicate(true)
	return e
