extends RefCounted
## Scale / performance smoke test: a large resistor ladder solves quickly and
## within tolerance, guarding against accidental O(n^2) blow-ups in the solver.

const CircuitSolver = preload("res://scripts/simulation/solver.gd")


func run(t) -> void:
	t.section("Scale - large resistor ladder")
	var n := 200
	var els := [t.make_element("V1", "vsource", ["n0", "0"], {"v": 10.0})]
	for i in range(n):
		els.append(t.make_element("R%d" % i, "resistor", ["n%d" % i, "n%d" % (i + 1)], {"r": 100.0}))
	els.append(t.make_element("Rload", "resistor", ["n%d" % n, "0"], {"r": 100.0}))
	var c = t.make_circuit(els)
	var s = CircuitSolver.new()
	var t0 := Time.get_ticks_msec()
	var r = s.solve_dc(c)
	var ms := Time.get_ticks_msec() - t0
	t.check(r.ok, "%d-node ladder solves" % n, r.get("error", ""))
	if r.ok:
		var expected := 10.0 / (float(n + 1) * 100.0)
		print("  (scale: %d nodes, %d resistors solved in %d ms)" % [n, n + 1, ms])
		t.near(r.element_currents["Rload"], expected, "load current follows the series law", 1e-9)
		t.check(ms < 5000, "solves within 5 s", "%d ms for %d nodes" % [ms, n])
	t.done()
