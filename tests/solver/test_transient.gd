extends RefCounted
## Transient verification: RC charging against the analytical curve, plus an
## RL check and source waveform checks.

const CircuitSolver = preload("res://scripts/simulation/solver.gd")


func run(t) -> void:
	t.section("Transient Test 6 - RC charging (5 V, 1 kOhm, 100 uF)")
	var c = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 1000.0}),
		t.make_element("C1", "capacitor", ["2", "0"], {"c": 100e-6}),
	])
	var s = CircuitSolver.new()
	var dt := 1e-3
	var res = s.solve_transient(c, {"t_stop": 0.5, "dt": dt, "probes": [{"kind": "node", "target": "2"}]})
	t.check(res.ok, "transient solve succeeds", res.get("error", ""))
	if not res.ok:
		return
	var samples: Array = res.samples
	t.check(samples.size() == 501, "501 samples recorded (0 .. 0.5 s)", "got %d" % samples.size())

	# Analytical: Vc(t) = 5*(1 - exp(-t/0.1))
	var points := {100: 3.1606, 200: 4.3233, 500: 4.9663}
	for idx in points:
		var vc: float = samples[idx].probes["2"]
		var expected: float = points[idx]
		var err: float = abs(vc - expected)
		var pct: float = err / 5.0 * 100.0
		t.check(pct < 2.0, "Vc at t=%d ms within 2%% of source (analytical %.4f V)" % [idx, expected],
			"sim=%.5f V err=%.3f%%" % [vc, pct])

	# Monotonic rising towards 5 V.
	t.check(samples[500].probes["2"] < 5.0 and samples[500].probes["2"] > samples[100].probes["2"],
		"capacitor voltage rises monotonically toward the source")

	t.section("Transient - RL step response")
	# 5 V, 100 Ohm, 10 mH -> tau = L/R = 1e-4 s. i(inf) = 50 mA.
	var c2 = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"v": 5.0}),
		t.make_element("R1", "resistor", ["1", "2"], {"r": 100.0}),
		t.make_element("L1", "inductor", ["2", "0"], {"l": 10e-3}),
	])
	var res2 = s.solve_transient(c2, {"t_stop": 1e-3, "dt": 1e-6, "probes": [{"kind": "current", "target": "L1"}]})
	t.check(res2.ok, "RL transient solve succeeds", res2.get("error", ""))
	if res2.ok:
		var samples2: Array = res2.samples
		var i_final: float = samples2[samples2.size() - 1].probes["L1"]
		t.near(i_final, 0.05, "steady-state inductor current = 50 mA", 0.02)
		# At t = tau the current should be ~63.2% of final.
		var idx_tau: int = int(round(1e-4 / 1e-6))
		var i_tau: float = samples2[idx_tau].probes["L1"]
		t.near(i_tau, 0.05 * (1.0 - exp(-1.0)), "inductor current at t=tau ~ 63.2% of final", 0.05)

	t.section("Transient - time-dependent source (sine)")
	var c3 = t.make_circuit([
		t.make_element("V1", "vsource", ["1", "0"], {"waveform": {"type": "sine", "amplitude": 10.0, "frequency": 100.0, "offset": 0.0}}),
		t.make_element("R1", "resistor", ["1", "0"], {"r": 1000.0}),
	])
	var res3 = s.solve_transient(c3, {"t_stop": 2.5e-3, "dt": 1e-5, "probes": [{"kind": "node", "target": "1"}]})
	t.check(res3.ok, "sine source transient succeeds", res3.get("error", ""))
	if res3.ok:
		var sm: Array = res3.samples
		# At t = 2.5 ms = quarter period, sine should be ~ +10 V.
		var vq: float = sm[sm.size() - 1].probes["1"]
		t.near(vq, 10.0, "sine at quarter period ~ +10 V", 0.02)
	t.done()
