extends RefCounted
## Nonlinear device tests: LED forward/reverse, diode clamp.

const CircuitSolver = preload("res://scripts/simulation/solver.gd")


func run(t) -> void:
	var s = CircuitSolver.new()

	t.section("Nonlinear - LED forward (5 V, 330 Ohm, red LED)")
	var c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 330.0}),
		t.make_element("D1", "led", ["2", "0"], {"is": 2e-19, "n": 1.8}),
	])
	var r = s.solve_dc(c)
	t.check(r.ok, "LED circuit converges", r.get("error", ""))
	if r.ok:
		var vf: float = r.element_voltages["D1"]
		var i: float = r.element_currents["D1"]
		t.check(vf > 1.6 and vf < 2.1, "LED forward voltage between 1.6 and 2.1 V", "Vf=%.4f" % vf)
		t.check(i > 0.005 and i < 0.015, "LED current between 5 and 15 mA", "I=%.5f" % i)
		# KCL / KVL consistency across R1.
		t.near(r.element_voltages["R1"], 5.0 - vf, "R1 voltage = 5 V - Vf", 1e-3)
		t.near(i, r.element_currents["R1"], "LED and resistor currents match", 1e-3)

	t.section("Nonlinear - LED reverse bias (~0 current)")
	var c2 = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": -5.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 330.0}),
		t.make_element("D1", "led", ["2", "0"], {"is": 2e-19, "n": 1.8}),
	])
	var r2 = s.solve_dc(c2)
	t.check(r2.ok, "reverse LED converges", r2.get("error", ""))
	if r2.ok:
		t.check(abs(r2.element_currents["D1"]) < 1e-6, "reverse current is negligible",
			"I=" + str(r2.element_currents["D1"]))

	t.section("Nonlinear - silicon diode drop")
	var c3 = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 1000.0}),
		t.make_element("D1", "diode", ["2", "0"], {"is": 1e-14, "n": 1.0}),
	])
	var r3 = s.solve_dc(c3)
	t.check(r3.ok, "silicon diode converges", r3.get("error", ""))
	if r3.ok:
		var vf3: float = r3.element_voltages["D1"]
		t.check(vf3 > 0.5 and vf3 < 0.8, "silicon forward drop between 0.5 and 0.8 V", "Vf=%.4f" % vf3)
		t.check(r3.get("iterations", 0) > 0, "used Newton-Raphson iterations", "iters=%d" % r3.get("iterations", 0))
	t.done()
