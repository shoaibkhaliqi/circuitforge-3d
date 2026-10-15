extends RefCounted
## Combinational logic gate tests: full truth tables against the solver.

const CircuitSolver = preload("res://scripts/simulation/solver.gd")


func run(t) -> void:
	var s = CircuitSolver.new()
	var vdd := 5.0

	t.section("Logic - AND gate truth table")
	_check_gate(t, s, "and", 2, vdd, [
		[false, false, false], [false, true, false],
		[true, false, false], [true, true, true],
	])

	t.section("Logic - OR gate truth table")
	_check_gate(t, s, "or", 2, vdd, [
		[false, false, false], [false, true, true],
		[true, false, true], [true, true, true],
	])

	t.section("Logic - NAND gate truth table")
	_check_gate(t, s, "nand", 2, vdd, [
		[false, false, true], [false, true, true],
		[true, false, true], [true, true, false],
	])

	t.section("Logic - NOR gate truth table")
	_check_gate(t, s, "nor", 2, vdd, [
		[false, false, true], [false, true, false],
		[true, false, false], [true, true, false],
	])

	t.section("Logic - XOR gate truth table")
	_check_gate(t, s, "xor", 2, vdd, [
		[false, false, false], [false, true, true],
		[true, false, true], [true, true, false],
	])

	t.section("Logic - NOT gate truth table")
	_check_gate(t, s, "not", 1, vdd, [
		[false, true], [true, false],
	])

	t.section("Logic - Buffer gate truth table")
	_check_gate(t, s, "buffer", 1, vdd, [
		[false, false], [true, true],
	])

	t.section("Logic - two-gate chain (AND into NOT = NAND)")
	# A AND B -> NOT -> Y  should equal NAND(A,B).
	var c = t.make_circuit([
		t.make_element("VA", "vsource", ["A", "0"], {"v": vdd}),
		t.make_element("VB", "vsource", ["B", "0"], {"v": vdd}),
		t.make_element("U1", "logic", ["A", "B", "M"], {"fn": "and", "vdd": vdd, "vth": 2.5}),
		t.make_element("U2", "logic", ["M", "Y"], {"fn": "not", "vdd": vdd, "vth": 2.5}),
		t.make_element("RL", "resistor", ["Y", "0"], {"r": 1000.0}),
	])
	var r = s.solve_dc(c)
	if t.check(r.ok, "gate chain converges", r.get("error", "")):
		var vy: float = r.node_voltages.get("Y", 0.0)
		t.check(vy < 0.5, "AND(1,1) then NOT gives a low output", "Y=%.3f" % vy)
	t.done()


## Build a gate (via the solver's "logic" element) driven by ideal sources and
## verify the output against the truth table.
func _check_gate(t, s, fn: String, inputs: int, vdd: float, table: Array) -> void:
	for row in table:
		var els := []
		var net := ["A", "B"]
		for i in inputs:
			var v: float = vdd if bool(row[i]) else 0.0
			els.append(t.make_element("V%d" % i, "vsource", [net[i], "0"], {"v": v}))
		var gate_nets := []
		for i in inputs:
			gate_nets.append(net[i])
		gate_nets.append("Y")
		els.append(t.make_element("U1", "logic", gate_nets, {"fn": fn, "vdd": vdd, "vth": 2.5}))
		els.append(t.make_element("RL", "resistor", ["Y", "0"], {"r": 1000.0}))
		var c = t.make_circuit(els)
		var r = s.solve_dc(c)
		var label := "%s(" % fn.to_upper()
		for i in inputs:
			label += "1" if bool(row[i]) else "0"
		label += ")"
		if not t.check(r.ok, "%s solves" % label, r.get("error", "")):
			continue
		var vy: float = r.node_voltages.get("Y", 0.0)
		var expect_high := bool(row[inputs])
		if expect_high:
			t.near(vy, vdd, "%s -> high" % label, 1e-2, 0.05)
		else:
			t.check(vy < 0.5, "%s -> low" % label, "Y=%.4f" % vy)
