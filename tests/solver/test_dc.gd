extends RefCounted
## Numerical verification of the DC solver against analytical results.
## Covers tests 1-5 and 7 of the engineering specification.

const CircuitSolver = preload("res://scripts/simulation/solver.gd")


func run(t) -> void:
	# ---- Test 1: Ohm's law -------------------------------------------------
	t.section("DC Test 1 - Ohm's law (5 V, 1 kOhm)")
	var c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "0"], {"r": 1000.0}),
	])
	var s = CircuitSolver.new()
	var r = s.solve_dc(c)
	t.check(r.ok, "solve succeeds", r.get("error", ""))
	if r.ok:
		t.near(r.node_voltages["1"], 5.0, "node 1 voltage = 5 V")
		t.near(r.element_currents["R1"], 0.005, "resistor current = 5 mA", 1e-4)
		t.near(r.element_currents["V1"], -0.005, "source current = -5 mA (opposite orientation)", 1e-4)
		t.near(r.element_voltages["R1"], 5.0, "resistor voltage = 5 V")

	# ---- Test 2: Voltage divider ------------------------------------------
	t.section("DC Test 2 - Voltage divider (10 V, two 1 kOhm)")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 10.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 1000.0}),
		t.make_element("R2", "resistor", ["2", "0"], {"r": 1000.0}),
	])
	r = s.solve_dc(c)
	t.check(r.ok, "solve succeeds", r.get("error", ""))
	if r.ok:
		t.near(r.node_voltages["2"], 5.0, "midpoint = 5 V", 1e-4)
		t.near(r.element_currents["R1"], 0.005, "series current = 5 mA", 1e-4)
		t.near(r.element_voltages["R1"], 5.0, "R1 voltage = 5 V")
		t.near(r.element_voltages["R2"], 5.0, "R2 voltage = 5 V")

	# ---- Test 3: Parallel resistors ---------------------------------------
	t.section("DC Test 3 - Parallel resistors (12 V, 2x 1 kOhm)")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 12.0}),
		t.make_element("R1", "resistor", ["1", "0"], {"r": 1000.0}),
		t.make_element("R2", "resistor", ["1", "0"], {"r": 1000.0}),
	])
	r = s.solve_dc(c)
	t.check(r.ok, "solve succeeds", r.get("error", ""))
	if r.ok:
		t.near(r.element_currents["R1"], 0.012, "branch 1 current = 12 mA", 1e-4)
		t.near(r.element_currents["R2"], 0.012, "branch 2 current = 12 mA", 1e-4)
		t.near(r.element_currents["V1"], -0.024, "total source current = -24 mA", 1e-4)
		var req: float = 12.0 / abs(r.element_currents["V1"])
		t.near(req, 500.0, "equivalent resistance = 500 Ohm", 1e-4)

	# ---- Test 4: Kirchhoff's Current Law ----------------------------------
	t.section("DC Test 4 - Kirchhoff's Current Law")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 9.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 1000.0}),
		t.make_element("R2", "resistor", ["2", "0"], {"r": 2200.0}),
		t.make_element("R3", "resistor", ["2", "3"], {"r": 470.0}),
		t.make_element("R4", "resistor", ["3", "0"], {"r": 1000.0}),
	])
	r = s.solve_dc(c)
	t.check(r.ok, "solve succeeds", r.get("error", ""))
	if r.ok:
		var worst := 0.0
		for net in ["1", "2", "3"]:
			worst = max(worst, abs(_node_current_sum(c, r, net)))
		t.check(worst < 1e-6, "KCL residual < 1e-6 A at every node", "worst=" + str(worst))

	# ---- Test 5: Kirchhoff's Voltage Law ----------------------------------
	t.section("DC Test 5 - Kirchhoff's Voltage Law")
	if r.ok:
		var loop1: float = r.element_voltages["V1"] - r.element_voltages["R1"] - r.element_voltages["R2"]
		t.near(loop1, 0.0, "loop V1-R1-R2 sums to 0", 1e-4, 1e-6)
		var loop2: float = r.element_voltages["R3"] + r.element_voltages["R4"] - r.element_voltages["R2"]
		t.near(loop2, 0.0, "loop node2-R3-node3-R4-node0-R2 sums to 0", 1e-4, 1e-6)

	# ---- Test 7: Parameter sensitivity ------------------------------------
	t.section("DC Test 7 - Parameter sensitivity (recompute without restart)")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "0"], {"r": 1000.0}),
	])
	var r1 = s.solve_dc(c)
	t.near(r1.element_currents["R1"], 0.005, "initial current = 5 mA")
	c.get_element("R1").params["r"] = 2000.0
	var r2 = s.solve_dc(c)
	t.check(r2.ok, "re-solve after edit succeeds")
	t.near(r2.element_currents["R1"], 0.0025, "current after R=2k is 2.5 mA", 1e-4)

	# ---- Test 8: floating node robustness (gmin leakage) ------------------
	t.section("DC Test 8 - unwired node is handled (gmin leakage)")
	c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 1000.0}),
		t.make_element("R2", "resistor", ["2", "0"], {"r": 1000.0}),
		t.make_element("D1", "led", ["3", "0"], {"is": 1e-14, "n": 1.0}),
	])
	r = s.solve_dc(c)
	t.check(r.ok, "circuit with a dangling node still solves", r.get("error", ""))
	if r.ok:
		t.near(r.node_voltages["3"], 0.0, "dangling node sits near 0 V", 1e-3)
		t.near(r.element_currents["D1"], 0.0, "no current through the dangling diode", 1e-6)
		t.near(r.node_voltages["2"], 2.5, "rest of the circuit is unaffected", 1e-4)
	t.done()


## Sum of currents leaving `net` over every element of the circuit.
func _node_current_sum(c, r: Dictionary, net: String) -> float:
	var total := 0.0
	for el in c.elements:
		var i: float = r.element_currents.get(el.id, 0.0)
		if el.nets.size() < 2:
			continue
		if el.nets[0] == net:
			total += i
		if el.nets[1] == net:
			total -= i
	return total
