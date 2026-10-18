extends RefCounted
## Scale / performance smoke test: a large resistor ladder solves quickly and within
## tolerance, and a dense breadboard project (many components through the real netlist
## path) still solves quickly - guarding against accidental complexity regressions.
## Recorded numbers live in `docs/plan/m10_performance.md`, measured by `tools/bench.gd`.

const CircuitSolver = preload("res://scripts/simulation/solver.gd")
const Session = preload("res://scripts/app/session.gd")


## `branches` identical LED + resistor branches across the rails: branch i is a resistor from
## the supply rail (every TP* is the same net) to its own column `a{i}`, and a LED from that
## column to ground (every TM* is the same net). So 2*branches + 2 components and
## branches + 2 nets. Returns the built circuit.
func _dense_branches(branches: int):
	var s = Session.new()
	s.project.breadboard["rows"] = maxi(30, branches)
	s.add_component("ground", ["TM1"])
	s.add_component("vsource", ["TP1", "TM1"], {"v": 5.0})
	for i in range(1, branches + 1):
		s.add_component("resistor", ["TP%d" % i, "a%d" % i], {"r": 220.0})
		s.add_component("led", ["a%d" % i, "TM%d" % i])
	return s.build_circuit()


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

	t.section("Scale - dense breadboard project (component count)")
	# The ladder varies the *node* count in a synthetic circuit; this varies the *component*
	# count through the real path (catalogue -> netlist builder -> DC solve), which is what a
	# full breadboard actually stresses. The branch current must scale linearly, which also
	# proves the netlist really wired all the branches in parallel.
	var small_branches := 25
	var big_branches := 100
	var small = _dense_branches(small_branches)
	var big = _dense_branches(big_branches)
	var solver = CircuitSolver.new()
	var rs = solver.solve_dc(small.circuit)
	var t1 := Time.get_ticks_msec()
	var rb = solver.solve_dc(big.circuit)
	var big_ms := Time.get_ticks_msec() - t1
	t.check(rs.ok, "%d-branch project solves" % small_branches, rs.get("error", ""))
	t.check(rb.ok, "%d-branch project solves" % big_branches, rb.get("error", ""))
	if rs.ok and rb.ok:
		var i_small: float = rs.element_currents["V1"]
		var i_big: float = rb.element_currents["V1"]
		print("  (scale: %d components solved in %d ms; source current %.4f A -> %.4f A)"
			% [big.circuit.elements.size(), big_ms, i_small, i_big])
		t.check(absf(i_small) > 0.0, "branches draw current", "%.6f A" % i_small)
		t.near(absf(i_big) / absf(i_small), float(big_branches) / float(small_branches),
			"source current scales with the branch count", 0.05)
		t.check(big_ms < 5000, "solves within 5 s", "%d ms for %d components"
			% [big_ms, big.circuit.elements.size()])
	t.done()
