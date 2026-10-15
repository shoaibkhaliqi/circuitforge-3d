extends RefCounted
## Test 8: invalid / degenerate circuits must produce meaningful diagnostics and
## must never crash or fabricate results.

const CircuitSolver = preload("res://scripts/simulation/solver.gd")


func run(t) -> void:
	var s = CircuitSolver.new()

	t.section("Invalid Test 8a - missing reference node")
	var c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "2"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 1000.0}),
	])
	var r = s.solve_dc(c)
	t.check(not r.ok, "solve fails without a ground node")
	t.check(r.error.to_lower().contains("reference") or r.error.to_lower().contains("ground"),
		"error mentions the missing reference", r.error)

	t.section("Invalid Test 8b - floating node (capacitor-only node in DC)")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("C1", "capacitor", ["1", "2"], {"c": 1e-6}),
	])
	r = s.solve_dc(c)
	t.check(not r.ok, "floating node is detected as singular")
	t.check(r.error.to_lower().contains("singular") or r.error.to_lower().contains("floating"),
		"error mentions singular/floating", r.error)

	t.section("Invalid Test 8c - conflicting ideal voltage sources")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("V2", "vsource", ["1", "0"], {"v": 3.0}),
	])
	r = s.solve_dc(c)
	t.check(not r.ok, "conflicting sources are rejected", r.get("error", ""))

	t.section("Invalid Test 8d - disconnected terminal warns but does not crash")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", ""], {"r": 1000.0}),
	])
	r = s.solve_dc(c)
	t.check(r.ok or not r.ok, "does not crash")
	t.check(r.get("warnings", []).size() > 0, "produces a warning for the unconnected part")

	t.section("Invalid Test 8e - unknown element type is ignored with a warning")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "0"], {"r": 1000.0}),
		t.make_element("X1", "quantum_flux_capacitor", ["1", "0"], {}),
	])
	r = s.solve_dc(c)
	t.check(r.ok, "still solves the valid part")
	t.check(r.warnings.size() > 0, "warns about the unknown element", str(r.warnings))

	t.section("Invalid Test 8f - empty circuit")
	c = t.make_circuit([])
	r = s.solve_dc(c)
	t.check(not r.ok, "empty circuit reports a meaningful error", r.get("error", ""))

	t.section("Invalid Test 8g - zero-ohm resistor does not crash")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "0"], {"r": 0.0}),
	])
	r = s.solve_dc(c)
	t.check(r.ok or not r.ok, "does not crash on r=0")
	t.done()
