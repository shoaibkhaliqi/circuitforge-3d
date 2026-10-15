extends RefCounted
## Verifies every bundled example opens, validates and simulates as documented.

const Persistence = preload("res://scripts/persistence/persistence.gd")
const Breadboard = preload("res://scripts/breadboard/breadboard.gd")
const NetlistBuilder = preload("res://scripts/connectivity/netlist_builder.gd")
const CircuitSolver = preload("res://scripts/simulation/solver.gd")

const EX_DIR := "res://data/examples"


func run(t) -> void:
	t.section("Examples - load, validate and simulate")
	var dir := DirAccess.open(EX_DIR)
	if dir == null:
		t.check(false, "examples directory not found: %s" % EX_DIR)
		t.done()
		return
	var files := []
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn.ends_with(".cf3d"):
			files.append(fn)
		fn = dir.get_next()
	dir.list_dir_end()
	files.sort()
	t.check(files.size() >= 8, "at least 8 bundled examples present", "found %d" % files.size())

	var solver = CircuitSolver.new()
	var builder = NetlistBuilder.new()
	var built_count := 0
	for f in files:
		var path := "%s/%s" % [EX_DIR, f]
		var lr = Persistence.load_from_file(path)
		if not t.check(lr.ok, "example loads: %s" % f, lr.get("error", "")):
			continue
		var proj = lr.project
		var bb = Breadboard.new(int(proj.breadboard.get("rows", 30)), bool(proj.breadboard.get("rail_split", false)))
		var built = builder.build(bb, proj.components, proj.wires)
		var mode := String(proj.get("simulation", {}).get("mode", "dc"))
		if mode == "transient":
			var res = solver.solve_transient(built.circuit, {
				"t_stop": float(proj.simulation.get("t_stop", 0.5)),
				"dt": float(proj.simulation.get("dt", 1e-3)),
			})
			t.check(res.ok, "example transient solves: %s" % f, res.get("error", ""))
			if res.ok:
				t.check(res.samples.size() > 1, "example produced samples: %s" % f)
		else:
			# RC discharge uses initial conditions; treat all DC here.
			var res = solver.solve_dc(built.circuit)
			t.check(res.ok, "example DC solves: %s" % f, res.get("error", ""))
		built_count += 1

	t.check(built_count == files.size(), "all example circuits simulated", "%d/%d" % [built_count, files.size()])

	# Spot-check documented results for two examples.
	t.section("Examples - documented values")
	var lr1 = Persistence.load_from_file("%s/01_led_resistor.cf3d" % EX_DIR)
	if lr1.ok:
		var bb1 = Breadboard.new(30)
		var b1 = builder.build(bb1, lr1.project.components, lr1.project.wires)
		var r1 = solver.solve_dc(b1.circuit)
		if t.check(r1.ok, "LED example solves"):
			var i = 0.0
			for k in r1.element_currents:
				if String(k).begins_with("D"):
					i = absf(float(r1.element_currents[k]))
			t.check(i > 0.005 and i < 0.015, "LED example current 5-15 mA", "I=" + str(i))

	var lr4 = Persistence.load_from_file("%s/04_voltage_divider.cf3d" % EX_DIR)
	if lr4.ok:
		var bb4 = Breadboard.new(30)
		var b4 = builder.build(bb4, lr4.project.components, lr4.project.wires)
		var r4 = solver.solve_dc(b4.circuit)
		if t.check(r4.ok, "divider example solves"):
			var found := false
			for k in r4.node_voltages:
				if absf(float(r4.node_voltages[k]) - 5.0) < 1e-3:
					found = true
			t.check(found, "divider has a 5 V node somewhere")

	var lr11 = Persistence.load_from_file("%s/11_logic_and.cf3d" % EX_DIR)
	if lr11.ok:
		var bb11 = Breadboard.new(30)
		var b11 = builder.build(bb11, lr11.project.components, lr11.project.wires)
		var r11 = solver.solve_dc(b11.circuit)
		if t.check(r11.ok, "logic AND example solves"):
			var led_i := 0.0
			for k in r11.element_currents:
				if String(k) == "D1":
					led_i = absf(float(r11.element_currents[k]))
			t.check(led_i > 0.001, "AND(1,1) lights the LED", "I=" + str(led_i))

	t.done()
