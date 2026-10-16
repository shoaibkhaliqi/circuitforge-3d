extends RefCounted
## Component factory (3D visuals) tests.
##
## Verifies that a built model lines up with its terminal positions and that the
## catalog-driven package shapes produce geometry without error.

const ComponentFactory = preload("res://scripts/components/component_factory.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")


func _column(count: int, spacing: float = 0.1) -> Array:
	var out := []
	for i in count:
		out.append(Vector3(0.0, 0.0, float(i) * spacing))
	return out


func _meshes(node: Node) -> Array:
	return node.find_children("*", "MeshInstance3D", true, false)


func _mesh_at_pin(meshes: Array, pin: Vector3, tol: float = 0.02) -> bool:
	for mi in meshes:
		var p: Vector3 = (mi as MeshInstance3D).position
		if absf(p.x - pin.x) <= tol and absf(p.z - pin.z) <= tol:
			return true
	return false


func _check_build(t, type: String, pins: int) -> Node3D:
	var positions := _column(pins)
	var node := ComponentFactory.build(type, positions)
	t.check(node != null, "%s builds a model" % type)
	if node == null:
		return null
	t.check(node.name == "Visual", "%s model is named Visual" % type)
	t.check(node.get_node_or_null("ValueLabel") != null, "%s has a value label" % type)
	var meshes := _meshes(node)
	t.check(meshes.size() > 0, "%s has geometry" % type)
	for p in positions:
		t.check(_mesh_at_pin(meshes, p), "%s pad lines up with a terminal" % type, str(p))
	return node


func run(t) -> void:
	t.section("Factory - core types align to their terminals")
	for spec in [["resistor", 2], ["led", 2], ["diode", 2], ["capacitor", 2], ["and", 3], ["switch", 2], ["ground", 1]]:
		var node := _check_build(t, spec[0], spec[1])
		if node != null:
			node.free()

	t.section("Factory - multi-pin parts get a lead per terminal")
	var gate := ComponentFactory.build("and", _column(3))
	var gate_meshes := _meshes(gate)
	t.check(gate_meshes.size() >= 3 + 3, "3-pin gate has pads plus leads", str(gate_meshes.size()))
	gate.free()

	t.section("Factory - catalog package shapes build")
	var samples := {
		"lm358": "dip8",
		"ne555": "dip8",
		"seven_segment": "seven_segment",
		"lcd1602": "module",
		"arduino_uno_r3": "board",
		"lm7805": "to220",
	}
	for id in samples:
		if not ComponentDB.exists(id):
			continue
		var pc: int = maxi(ComponentDB.pin_count(id), 2)
		var node := ComponentFactory.build(id, _column(pc))
		t.check(node != null, "catalog part %s builds" % id)
		if node != null:
			t.check(_meshes(node).size() > 0, "catalog part %s has geometry" % id)
			node.free()

	t.done()
