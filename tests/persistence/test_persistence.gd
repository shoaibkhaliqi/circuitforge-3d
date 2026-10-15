extends RefCounted
## Persistence tests, including the full "save -> reload -> re-simulate" check.

const Persistence = preload("res://scripts/persistence/persistence.gd")
const NetlistBuilder = preload("res://scripts/connectivity/netlist_builder.gd")
const Breadboard = preload("res://scripts/breadboard/breadboard.gd")
const CircuitSolver = preload("res://scripts/simulation/solver.gd")

const TEST_PATH := "user://cf3d_persist_test.cf3d"


func _sample_project() -> Dictionary:
	var p = Persistence.new_project("Divider")
	p.components = [
		{"id": "V1", "type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 10.0}, "rotation": 0.0, "position": [0, 0, 0]},
		{"id": "R1", "type": "resistor", "holes": ["TP5", "a5"], "params": {"r": 1000.0}, "rotation": 0.0, "position": [0, 0, 0]},
		{"id": "R2", "type": "resistor", "holes": ["a10", "TM10"], "params": {"r": 1000.0}, "rotation": 0.0, "position": [0, 0, 0]},
		{"id": "GND", "type": "ground", "holes": ["TM1"], "params": {}, "rotation": 0.0, "position": [0, 0, 0]},
	]
	p.wires = [
		{"id": "W1", "a": {"kind": "hole", "id": "a5"}, "b": {"kind": "hole", "id": "a10"}},
	]
	return p


func run(t) -> void:
	t.section("Persistence - validation")
	var p = _sample_project()
	var v = Persistence.validate(p)
	t.check(v.ok, "valid project passes validation", str(v.errors))

	var bad = _sample_project()
	bad.components[1].type = "flux_capacitor"
	t.check(not Persistence.validate(bad).ok, "unknown component type fails validation")

	var bad2 = _sample_project()
	bad2.wires[0].a = {"kind": "hole", "id": "zz99"}
	t.check(not Persistence.validate(bad2).ok, "invalid hole reference fails validation")

	var bad3 = _sample_project()
	bad3.components[0].id = "R1"
	t.check(not Persistence.validate(bad3).ok, "duplicate ids fail validation")

	t.section("Persistence - save and reload")
	var sr = Persistence.save_to_file(TEST_PATH, p)
	t.check(sr.ok, "save succeeds", sr.get("error", ""))
	var lr = Persistence.load_from_file(TEST_PATH)
	t.check(lr.ok, "load succeeds", lr.get("error", ""))
	if lr.ok:
		var q = lr.project
		t.check(q.components.size() == p.components.size(), "component count preserved")
		t.check(q.wires.size() == p.wires.size(), "wire count preserved")
		t.check(q.metadata.name == "Divider", "metadata preserved")
		# Parameters preserved.
		t.check(abs(float(q.components[0].params.v) - 10.0) < 1e-9, "source value preserved")

	t.section("Persistence - same results after reload")
	var bb = Breadboard.new(30)
	var builder = NetlistBuilder.new()
	var before = builder.build(bb, p.components, p.wires)
	var solver = CircuitSolver.new()
	var res_before = solver.solve_dc(before.circuit)
	t.check(res_before.ok, "pre-save solve ok", res_before.get("error", ""))

	if lr.ok:
		var after = builder.build(bb, lr.project.components, lr.project.wires)
		var res_after = solver.solve_dc(after.circuit)
		t.check(res_after.ok, "post-reload solve ok", res_after.get("error", ""))
		if res_before.ok and res_after.ok:
			t.check(after.pin_nets == before.pin_nets, "connectivity graph identical after reload")
			var maxdiff := 0.0
			for k in res_before.node_voltages:
				if res_after.node_voltages.has(k):
					maxdiff = max(maxdiff, abs(res_before.node_voltages[k] - res_after.node_voltages[k]))
			t.check(maxdiff < 1e-9, "node voltages identical after reload", "maxdiff=" + str(maxdiff))
			t.check(abs(res_before.element_currents["R1"] - res_after.element_currents["R1"]) < 1e-12,
				"R1 current identical after reload")
			t.check(abs(res_before.element_currents["R1"] - 0.005) < 1e-4, "divider current is 5 mA")

	t.section("Persistence - corrupted file fails safely")
	var f = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string("{ this is not valid json ")
	f.close()
	var cr = Persistence.load_from_file(TEST_PATH)
	t.check(not cr.ok, "corrupted file is rejected")
	t.check(cr.error.to_lower().contains("corrupt") or cr.error.to_lower().contains("json"), "error mentions corruption", cr.error)

	t.section("Persistence - version migration")
	var old = {"schema_version": 0, "components": [], "wires": []}
	var mig = Persistence.migrate(old)
	t.check(int(mig.schema_version) == Persistence.SCHEMA_VERSION, "old schema migrated to current")
	t.check(mig.has("breadboard"), "migration adds missing breadboard section")

	t.section("Persistence - missing file")
	var mf = Persistence.load_from_file("user://does_not_exist_xyz.cf3d")
	t.check(not mf.ok, "missing file reports an error", mf.get("error", ""))

	# Clean up the temp file.
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	t.done()
