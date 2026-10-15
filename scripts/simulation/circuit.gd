extends RefCounted
## CircuitForge 3D - a circuit is an ordered list of elements plus metadata.
##
## This is a pure data container. It has no dependency on the scene tree and can
## be serialised directly with the persistence layer.

const SimElement = preload("res://scripts/simulation/element.gd")

var reference: String = "0"
var elements: Array = []
var metadata: Dictionary = {}


func add_element(el) -> void:
	elements.append(el)


func get_element(id: String):
	for el in elements:
		if el.id == id:
			return el
	return null


func remove_element(id: String) -> void:
	for i in range(elements.size() - 1, -1, -1):
		if elements[i].id == id:
			elements.remove_at(i)


func duplicate_element(id: String):
	var el = get_element(id)
	if el == null:
		return null
	var copy = el.clone()
	copy.id = id + "_copy"
	elements.append(copy)
	return copy


## Unique net names referenced by any element (empty strings ignored).
func net_names() -> Array:
	var names := []
	var seen := {}
	for el in elements:
		for n in el.nets:
			if typeof(n) != TYPE_STRING or n == "":
				continue
			if not seen.has(n):
				seen[n] = true
				names.append(n)
	return names


func to_dict() -> Dictionary:
	var els := []
	for el in elements:
		els.append(el.to_dict())
	return {
		"reference": reference,
		"elements": els,
		"metadata": metadata.duplicate(true),
	}
