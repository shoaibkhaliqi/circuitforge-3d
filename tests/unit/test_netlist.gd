extends RefCounted
## Netlist-mapping and model-honesty tests for catalogue parts.
##
## Verifies that every part claiming a `full`/`partial` simulation status is
## actually mapped by the netlist builder, and that the newly mapped catalogue
## aliases (switches, capacitor/diode/LED variants, batteries, supplies) produce
## the expected solver elements.

const Breadboard = preload("res://scripts/breadboard/breadboard.gd")
const NetlistBuilder = preload("res://scripts/connectivity/netlist_builder.gd")
const CircuitSolver = preload("res://scripts/simulation/solver.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")


func _place(id: String, type: String, holes: Array, params: Dictionary = {}, rot: float = 0.0) -> Dictionary:
	return {"id": id, "type": type, "holes": holes, "params": params, "rotation": rot, "position": [0, 0, 0]}


func _hole(id: String) -> Dictionary:
	return {"kind": "hole", "id": id}


func _by_id(r, id: String):
	for e in r.circuit.elements:
		if e.id == id:
			return e
	return null


func _vsource_vs(r) -> Array:
	var out := []
	for e in r.circuit.elements:
		if e.type == "vsource":
			out.append(e)
	return out


func run(t) -> void:
	var builder = NetlistBuilder.new()
	var bb = Breadboard.new(30)

	# ---- Honesty: status never over-claims --------------------------------
	t.section("Netlist - catalogue status matches solver coverage")
	var defs = ComponentDB.all_defs()
	var overclaim := []
	var unmapped_visual := 0
	var checked := 0
	for id in defs.keys():
		var st = ComponentDB.status_of(id)
		if st != "full" and st != "partial" and st != "visual":
			continue
		checked += 1
		var handled: bool = NetlistBuilder.handles(id)
		if ComponentDB.is_simulatable(id) and not handled:
			overclaim.append(id)
		if st == "visual" and handled:
			unmapped_visual += 1
	t.check(overclaim.is_empty(), "every full/partial part is mapped by the solver", str(overclaim))
	t.check(unmapped_visual == 0, "no part labelled visual is nonetheless simulated", str(unmapped_visual))
	t.check(checked >= 70, "honesty check covered the catalogue", "checked=%d" % checked)

	# ---- mcu_pin -> gpio --------------------------------------------------
	t.section("Netlist - virtual MCU pin maps to a gpio driver")
	var r = builder.build(bb, [_place("U1", "mcu_pin", ["TP1", "TM1"], {})], [])
	var e = _by_id(r, "U1")
	t.check(e != null and e.type == "gpio", "mcu_pin becomes a gpio element")
	if e != null:
		t.near(e.params["vlogic"], 5.0, "default logic voltage = 5 V")
		t.near(e.params["rout"], 25.0, "default output resistance = 25 Ohm")
		t.near(e.params["level"], 1.0, "default level = 1 (high)")

	# ---- gpio drives a load (numerical) -----------------------------------
	t.section("Netlist - gpio Thevenin behaviour")
	var gc = t.make_circuit([
		t.make_element("U1", "gpio", ["1", "0"], {"level": 1.0, "vlogic": 5.0, "rout": 25.0}),
		t.make_element("R1", "resistor", ["1", "0"], {"r": 1000.0}),
	])
	var s = CircuitSolver.new()
	var gr = s.solve_dc(gc)
	t.check(gr.ok, "gpio circuit solves", gr.get("error", ""))
	if gr.ok:
		t.near(gr.node_voltages["1"], 5.0 * 1000.0 / 1025.0, "output sags to 5*1k/(1k+25)", 1e-3)
	gc.get_element("U1").params["level"] = 0.0
	gr = s.solve_dc(gc)
	t.check(gr.ok, "gpio low solves")
	if gr.ok:
		t.near(gr.node_voltages["1"], 0.0, "driven low sits at 0 V", 1e-6, 1e-6)
	gc.get_element("U1").params["level"] = -1.0
	gr = s.solve_dc(gc)
	t.check(gr.ok, "gpio high-Z solves")
	if gr.ok:
		t.near(gr.element_currents["R1"], 0.0, "high-Z pin sources no current", 1e-6, 1e-6)

	# ---- push_button / reed_switch -> resistor ----------------------------
	t.section("Netlist - momentary button and reed switch")
	r = builder.build(bb, [_place("SW1", "push_button", ["a1", "a9"], {"closed": true})], [])
	var e1 = _by_id(r, "SW1")
	t.check(e1 != null and e1.type == "resistor", "closed push button is a low-value resistor")
	if e1 != null:
		t.check(float(e1.params["r"]) < 1.0, "closed contact resistance is tiny")
	r = builder.build(bb, [_place("SW1", "push_button", ["a1", "a9"], {"closed": false})], [])
	e1 = _by_id(r, "SW1")
	if e1 != null:
		t.check(float(e1.params["r"]) > 1e6, "open contact resistance is huge")

	# ---- toggle_switch -> two resistors -----------------------------------
	t.section("Netlist - SPDT toggle switch")
	var tr = builder.build(bb, [_place("T1", "toggle_switch", ["a1", "a5", "a9"], {"position": 0.0})], [])
	var no = _by_id(tr, "T1")
	var nc = _by_id(tr, "T1#2")
	t.check(no != null and nc != null, "toggle produces COM-NO and COM-NC halves")
	if no != null and nc != null:
		t.check(float(no.params["r"]) > 1e6, "position 0 leaves NO open")
		t.check(float(nc.params["r"]) < 1.0, "position 0 closes NC")
	tr = builder.build(bb, [_place("T1", "toggle_switch", ["a1", "a5", "a9"], {"position": 1.0})], [])
	if _by_id(tr, "T1") != null:
		t.check(float(_by_id(tr, "T1").params["r"]) < 1.0, "position 1 closes NO")
		t.check(float(_by_id(tr, "T1#2").params["r"]) > 1e6, "position 1 opens NC")

	# ---- trimmer -> potentiometer -----------------------------------------
	t.section("Netlist - trimmer maps to a potentiometer")
	r = builder.build(bb, [_place("RV1", "trimmer", ["a1", "a5", "a9"], {"r": 10000.0, "position": 0.5})], [])
	var hi = _by_id(r, "RV1")
	var lo = _by_id(r, "RV1#2")
	t.check(hi != null and lo != null and hi.type == "resistor", "trimmer splits into two resistors")
	if hi != null and lo != null:
		t.near(float(hi.params["r"]), 5000.0, "upper half = 5k at mid position", 1e-3)
		t.near(float(lo.params["r"]), 5000.0, "lower half = 5k at mid position", 1e-3)

	# ---- capacitor / inductor / LED / diode aliases -----------------------
	t.section("Netlist - passive and semiconductor aliases")
	for id in ["electrolytic_capacitor", "film_capacitor", "tantalum_capacitor", "supercapacitor"]:
		var rr = builder.build(bb, [_place("C1", id, ["a1", "a9"], {})], [])
		t.check(_by_id(rr, "C1") != null and _by_id(rr, "C1").type == "capacitor", "%s maps to a capacitor" % id)
	r = builder.build(bb, [_place("L1", "ferrite_bead", ["a1", "a9"], {})], [])
	t.check(_by_id(r, "L1") != null and _by_id(r, "L1").type == "inductor", "ferrite bead maps to an inductor")
	r = builder.build(bb, [_place("D1", "led_green", ["a1", "a9"], {})], [])
	t.check(_by_id(r, "D1") != null and _by_id(r, "D1").type == "led", "led_green maps to an led")
	r = builder.build(bb, [_place("D2", "schottky_diode", ["a1", "a9"], {})], [])
	t.check(_by_id(r, "D2") != null and _by_id(r, "D2").type == "diode", "schottky maps to a diode")
	r = builder.build(bb, [_place("R9", "shunt_resistor", ["a1", "a9"], {"r": 0.1})], [])
	t.check(_by_id(r, "R9") != null and _by_id(r, "R9").type == "resistor", "shunt maps to a resistor")

	# ---- sources: battery with internal resistance ------------------------
	t.section("Netlist - batteries and supplies")
	r = builder.build(bb, [_place("B1", "battery_aa", ["TP1", "TM1"], {"v": 1.5, "r_internal": 0.0})], [])
	var vs = _vsource_vs(r)
	t.check(vs.size() == 1 and _by_id(r, "B1") != null, "ideal battery is a single source")
	if _by_id(r, "B1") != null:
		t.near(float(_by_id(r, "B1").params["v"]), 1.5, "battery voltage = 1.5 V")
	r = builder.build(bb, [_place("B1", "battery_aa", ["TP1", "TM1"], {"v": 1.5, "r_internal": 0.15})], [])
	t.check(_by_id(r, "B1") != null and _by_id(r, "B1#r") != null, "internal resistance becomes a series resistor")
	if _by_id(r, "B1#r") != null:
		t.near(float(_by_id(r, "B1#r").params["r"]), 0.15, "series resistance = 0.15 Ohm")
	r = builder.build(bb, [_place("PS1", "bench_psu", ["TP1", "TM1"], {"voltage": 9.0})], [])
	if _by_id(r, "PS1") != null:
		t.near(float(_by_id(r, "PS1").params["v"]), 9.0, "bench PSU output follows the voltage parameter")
	r = builder.build(bb, [_place("AC1", "ac_source", ["a1", "a9"], {"amplitude": 5.0, "frequency": 50.0})], [])
	if _by_id(r, "AC1") != null:
		t.check(_by_id(r, "AC1").params.has("waveform"), "AC source carries a waveform")
		t.check(String(_by_id(r, "AC1").params["waveform"]["type"]) == "sine", "AC source waveform is a sine")
	r = builder.build(bb, [_place("P1", "breadboard_psu_5v", ["a1", "TM1", "a5", "a9"], {})], [])
	t.check(_by_id(r, "P1") != null and _by_id(r, "P1#3v3") != null, "breadboard PSU exposes 5 V and 3.3 V rails")
	if _by_id(r, "P1") != null:
		t.near(float(_by_id(r, "P1").params["v"]), 5.0, "5 V rail")
		t.near(float(_by_id(r, "P1#3v3").params["v"]), 3.3, "3.3 V rail")

	# ---- electrical: battery + internal resistance drives a load ----------
	t.section("Netlist - battery with internal resistance (numerical)")
	var circ = builder.build(bb, [
		_place("B1", "battery_aa", ["TP1", "TM1"], {"v": 1.5, "r_internal": 1.0}),
		_place("R1", "resistor", ["TP5", "a5"], {"r": 1.0}),
		_place("GND", "ground", ["TM1"], {}),
	], [{"id": "W1", "a": _hole("a5"), "b": _hole("TM5")}])
	var br = CircuitSolver.new().solve_dc(circ.circuit)
	t.check(br.ok, "battery circuit solves", br.get("error", ""))
	if br.ok:
		t.near(br.element_currents["R1"], 0.75, "load current = 1.5/(1+1) = 0.75 A", 1e-3)
		t.near(br.node_voltages[circ.pin_nets["B1"][0]], 0.75, "terminal voltage = 0.75 V", 1e-3)

	# ---- unhandled parts warn instead of pretending -----------------------
	t.section("Netlist - unmapped parts are skipped with a warning")
	r = builder.build(bb, [_place("J1", "barrel_jack", ["a1", "a9"], {})], [])
	t.check(_by_id(r, "J1") == null, "visual-only barrel jack produces no element")
	var warned := false
	for w in r.warnings:
		if String(w).contains("not yet simulatable"):
			warned = true
	t.check(warned, "a warning is emitted for the skipped part")

	t.done()
