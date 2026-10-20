extends RefCounted
## Beginner-workflow integration test, mirroring docs/plan/usability_walkthrough.md:
## find parts by searching like the library does, place them, wire them, run,
## observe the LED, save/reopen, then introduce an error and find it.

const Session = preload("res://scripts/app/session.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")

const PATH := "user://cf3d_workflow.cf3d"


## Same matching rule the library panel uses (name/id/category/part/description).
func _search(filter: String) -> Array:
	var f := filter.strip_edges().to_lower()
	if f == "":
		return ComponentDB.all_defs().keys()
	var out := []
	for tp in ComponentDB.all_defs().keys():
		var d: Dictionary = ComponentDB.get_def(tp)
		var hay := ("%s %s %s %s %s" % [String(d.name), tp, String(d.get("category", "")),
				String(d.get("part_number", "")), String(d.get("description", ""))]).to_lower()
		if hay.contains(f):
			out.append(tp)
	return out


func run(t) -> void:
	t.section("Beginner workflow - find parts by searching the library")
	var resistor_types: Array = _search("resistor")
	var led_types: Array = _search("light-emitting diode")
	t.check(resistor_types.size() >= 1, "searching 'resistor' finds at least one part")
	t.check(led_types.size() >= 1, "searching 'light-emitting diode' finds the LED")
	t.check(_search("zzz-no-such-part").is_empty(), "gibberish finds nothing")
	t.check(resistor_types.has("resistor") and led_types.has("led"),
		"the plain beginner parts live under their own names")

	t.section("Beginner workflow - place, wire, run, observe")
	var s = Session.new()
	s.add_component("ground", ["TM1"])                       # the help's step 4
	s.add_component("vsource", ["TP1", "TM1"], {"v": 5.0})
	var r1 = s.add_component("resistor", ["TP5", "a5"], {"r": 330.0})
	var led = s.add_component("led", ["a8", "TM8"], {})
	s.add_wire({"kind": "hole", "id": "a5"}, {"kind": "hole", "id": "a8"})
	var res = s.simulate_dc()
	t.check(res.ok, "the first run solves", res.get("error", ""))
	if res.ok:
		t.check(absf(float(res.element_currents[led])) > 0.004,
			"the LED carries a visible current (it lights up)",
			str(res.element_currents[led]))

	t.section("Beginner workflow - save, close, reopen")
	t.check(s.save_project(PATH), "save succeeds")
	var s2 = Session.new()
	t.check(s2.load_project(PATH), "reopen succeeds")
	t.check(s2.project.components.size() == 4, "all four parts survive the round trip")
	t.check(s2.project.wires.size() == 1, "the wire survives the round trip")

	t.section("Beginner workflow - find and fix an introduced error")
	# Removing the resistor leaves its hole-to-hole wire in place (like a real
	# jumper on an empty hole); the run then shows the LED dark.
	s2.remove_component(r1)
	t.check(s2.project.wires.size() == 1,
		"the hole jumper survives (it sits in holes, not in the part)")
	var res2 = s2.simulate_dc()
	t.check(res2.ok, "the broken circuit still solves (honest, no fake failure)", res2.get("error", ""))
	if res2.ok:
		t.check(absf(float(res2.element_currents[led])) < 1e-9,
			"the LED is dark after the break - the user sees 'no current'")

	# Fix: re-place the part; the surviving wire completes the run again.
	var r2 = s2.add_component("resistor", ["TP5", "a5"], {"r": 330.0})
	var res3 = s2.simulate_dc()
	t.check(res3.ok, "the fixed circuit solves", res3.get("error", ""))
	if res3.ok:
		t.check(absf(float(res3.element_currents[led])) > 0.004, "the LED lights again")

	t.section("Beginner workflow - explained errors")
	# Only a source, no reference: the solver must fail with a helpful line.
	var s3 = Session.new()
	s3.add_component("vsource", ["TP1", "TM1"], {"v": 5.0})
	var res4 = s3.simulate_dc()
	t.check(not res4.ok, "a circuit without a ground fails honestly")
	t.check(String(res4.get("error", "")).to_lower().contains("reference"),
		"the message names the missing ground reference", str(res4.get("error", "")))

	# Both legs of a resistor in one strip: an accidental short the netlist sees.
	var s4 = Session.new()
	s4.add_component("ground", ["TM1"])
	s4.add_component("resistor", ["b1", "d1"], {"r": 1000.0})
	var built: Dictionary = s4.build_circuit()
	var short_warn := false
	for wvl in built.warnings:
		if String(wvl).contains("accidental short"):
			short_warn = true
	t.check(short_warn, "a resistor with both legs in one strip is flagged as a short")

	# Wires can be removed again (session API the app's Delete key uses).
	s4.add_wire({"kind": "hole", "id": "TP1"}, {"kind": "hole", "id": "BP1"})
	var wid: String = String(s4.project.wires[0].id)
	s4.remove_wire(wid)
	t.check(s4.project.wires.is_empty(), "remove_wire deletes a wire")
	s4.undo()
	t.check(s4.project.wires.size() == 1, "removing a wire is undoable")

	t.done()
