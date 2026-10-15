extends RefCounted
## End-to-end integration test for Milestone 4:
## place -> connect -> simulate -> edit value -> re-simulate -> save -> reload.

const Session = preload("res://scripts/app/session.gd")
const Persistence = preload("res://scripts/persistence/persistence.gd")

const PATH := "user://cf3d_e2e.cf3d"


func run(t) -> void:
	t.section("End-to-end - build, solve, edit, save, reload")
	var s = Session.new()

	# Negative rail TM1 is the ground net.
	s.add_component("ground", ["TM1"])
	s.add_component("vsource", ["TP1", "TM1"], {"v": 5.0})
	var r1 = s.add_component("resistor", ["TP5", "a5"], {"r": 330.0})
	var led = s.add_component("led", ["a10", "TM10"])
	s.add_wire({"kind": "hole", "id": "a5"}, {"kind": "hole", "id": "a10"})

	t.check(s.project.components.size() == 4, "four components placed")

	var res = s.simulate_dc()
	t.check(res.ok, "end-to-end DC solve succeeds", res.get("error", ""))
	if not res.ok:
		return
	t.near(res.node_voltages["TP1"], 5.0, "supply rail is 5 V", 1e-3)
	var i_led: float = res.element_currents[led]
	t.check(i_led > 0.005 and i_led < 0.015, "LED current between 5 and 15 mA", "I=" + str(i_led))
	t.near(res.element_currents[r1], i_led, "resistor current equals LED current (series)", 1e-3)

	# Change the resistor value; result must change without a restart.
	var before: float = absf(res.element_currents[r1])
	s.set_param(r1, "r", 1000.0)
	var res2 = s.simulate_dc()
	t.check(res2.ok, "re-solve after editing the resistor succeeds", res2.get("error", ""))
	var after: float = absf(res2.element_currents[r1])
	t.check(after < before, "increasing R reduces the current", "%s -> %s" % [str(before), str(after)])
	t.near(after, (5.0 - res2.element_voltages[led]) / 1000.0, "current matches (Vs - Vf)/R", 1e-3)

	# Save, reload, re-simulate and compare.
	t.check(s.save_project(PATH), "save succeeds")
	var s2 = Session.new()
	t.check(s2.load_project(PATH), "reload succeeds")
	t.check(s2.project.components.size() == 4, "component count preserved")
	t.check(s2.project.wires.size() == 1, "wire count preserved")
	var res3 = s2.simulate_dc()
	t.check(res3.ok, "reload + re-simulate succeeds", res3.get("error", ""))
	if res3.ok:
		t.near(res3.element_currents[r1], res2.element_currents[r1], "current identical after reload", 1e-9)
		t.near(res3.node_voltages["TP1"], 5.0, "rail voltage identical after reload", 1e-9)

	# Undo / redo through the session.
	var count_before = s2.project.components.size()
	s2.add_component("resistor", ["b5", "b10"], {"r": 1000.0})
	t.check(s2.project.components.size() == count_before + 1, "component added")
	s2.undo()
	t.check(s2.project.components.size() == count_before, "undo removed the component")
	s2.redo()
	t.check(s2.project.components.size() == count_before + 1, "redo restored the component")
	s2.undo()
	s2.undo()  # undo the param edit too, just to exercise the stack

	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	t.done()
