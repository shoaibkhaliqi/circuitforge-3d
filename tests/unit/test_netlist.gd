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

	# ---- mcu_analog_in -> high-Z probe -----------------------------------
	t.section("Netlist - virtual analog input is a high-impedance probe")
	var acirc = builder.build(bb, [
		_place("V1", "vsource", ["TP1", "TM1"], {"v": 4.0}),
		_place("R1", "resistor", ["TP1", "a1"], {"r": 1000.0}),
		_place("R2", "resistor", ["a1", "TM1"], {"r": 1000.0}),
		_place("AIN1", "mcu_analog_in", ["a1"], {}),
		_place("GND", "ground", ["TM1"]),
	], [])
	var ae = _by_id(acirc, "AIN1")
	t.check(ae != null and ae.type == "resistor", "mcu_analog_in becomes a high-Z probe")
	if ae != null:
		t.near(float(ae.params["r"]), 1.0e9, "probe resistance is 1 GOhm", 1.0)
		t.check(String(ae.nets[1]) == "0", "probe references ground")
	var ar = CircuitSolver.new().solve_dc(acirc.circuit)
	t.check(ar.ok, "divider with an analog input solves", ar.get("error", ""))
	if ar.ok:
		t.near(ar.node_voltages["a1"], 2.0, "probe reads the divider midpoint", 1e-2)

	# ---- mcu_pwm_out -> average Thevenin source --------------------------
	t.section("Netlist - virtual analog output is an average source")
	var pcirc = builder.build(bb, [
		_place("PWM1", "mcu_pwm_out", ["a1"], {"voltage": 2.0, "rout": 25.0}),
		_place("RL", "resistor", ["a1", "TM1"], {"r": 1000.0}),
		_place("GND", "ground", ["TM1"]),
	], [])
	var pwe = _by_id(pcirc, "PWM1")
	t.check(pwe != null and pwe.type == "vout", "mcu_pwm_out becomes a vout source")
	if pwe != null:
		t.near(float(pwe.params["voltage"]), 2.0, "output voltage is carried through")
		t.check(String(pwe.nets[1]) == "0", "output references ground")
	var pwr = CircuitSolver.new().solve_dc(pcirc.circuit)
	t.check(pwr.ok, "PWM output with a load solves", pwr.get("error", ""))
	if pwr.ok:
		t.near(pwr.node_voltages["a1"], 2.0 * 1000.0 / 1025.0, "output sags to 2*1k/(1k+25)", 1e-3)

	# ---- eeprom_i2c is a firmware/backend part, not a solver model -------
	t.section("Netlist - I2C EEPROM is backend-only, not a solver model")
	t.check(ComponentDB.status_of("eeprom_i2c") == "external", "eeprom_i2c status is 'external'")
	t.check(not NetlistBuilder.handles("eeprom_i2c"), "eeprom_i2c is not mapped by the solver")
	t.check(ComponentDB.status_of("i2c_lcd1602") == "external", "i2c_lcd1602 status is 'external'")
	t.check(not NetlistBuilder.handles("i2c_lcd1602"), "i2c_lcd1602 is not mapped by the solver")
	t.check(ComponentDB.status_of("hcsr04") == "external", "hcsr04 status is 'external'")
	t.check(not NetlistBuilder.handles("hcsr04"), "hcsr04 is not mapped by the solver")
	t.check(ComponentDB.status_of("mpu6050") == "external", "mpu6050 status is 'external'")
	t.check(not NetlistBuilder.handles("mpu6050"), "mpu6050 is not mapped by the solver")
	t.check(ComponentDB.status_of("oled_ssd1306") == "external", "oled_ssd1306 status is 'external'")
	t.check(not NetlistBuilder.handles("oled_ssd1306"), "oled_ssd1306 is not mapped by the solver")
	t.check(ComponentDB.status_of("rotary_encoder") == "external", "rotary_encoder status is 'external'")
	t.check(not NetlistBuilder.handles("rotary_encoder"), "rotary_encoder is not mapped by the solver")
	t.check(ComponentDB.status_of("dht11") == "external", "dht11 status is 'external'")
	t.check(not NetlistBuilder.handles("dht11"), "dht11 is not mapped by the solver")
	t.check(ComponentDB.status_of("dht22") == "external", "dht22 status is 'external'")
	t.check(not NetlistBuilder.handles("dht22"), "dht22 is not mapped by the solver")
	t.check(ComponentDB.status_of("sht31") == "external", "sht31 status is 'external'")
	t.check(not NetlistBuilder.handles("sht31"), "sht31 is not mapped by the solver")
	t.check(ComponentDB.status_of("servo_sg90") == "external", "servo_sg90 status is 'external'")
	t.check(not NetlistBuilder.handles("servo_sg90"), "servo_sg90 is not mapped by the solver")
	t.check(ComponentDB.status_of("servo_mg996r") == "external", "servo_mg996r status is 'external'")
	t.check(not NetlistBuilder.handles("servo_mg996r"), "servo_mg996r is not mapped by the solver")
	t.check(ComponentDB.status_of("stepper_nema17") == "external", "stepper_nema17 status is 'external'")
	t.check(not NetlistBuilder.handles("stepper_nema17"), "stepper_nema17 is not mapped by the solver")
	t.check(ComponentDB.status_of("a4988_driver") == "external", "a4988_driver status is 'external'")
	t.check(not NetlistBuilder.handles("a4988_driver"), "a4988_driver is not mapped by the solver")
	t.check(ComponentDB.status_of("drv8825_driver") == "external", "drv8825_driver status is 'external'")
	t.check(not NetlistBuilder.handles("drv8825_driver"), "drv8825_driver is not mapped by the solver")

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

	# ---- analog sensors: thermistor, LDR, RTD -----------------------------
	t.section("Netlist - resistive sensors follow their stimulus")
	r = builder.build(bb, [_place("TH1", "thermistor_ntc", ["a1", "a9"], {"r25": 10000.0, "beta": 3950.0, "temperature": 25.0})], [])
	t.near(float(_by_id(r, "TH1").params["r"]), 10000.0, "NTC at 25 degC equals R25", 1e-6)
	r = builder.build(bb, [_place("TH1", "thermistor_ntc", ["a1", "a9"], {"r25": 10000.0, "beta": 3950.0, "temperature": 50.0})], [])
	t.near(float(_by_id(r, "TH1").params["r"]), 3588.0, "NTC at 50 degC drops to ~3.6k", 1e-2)
	r = builder.build(bb, [_place("L1", "photoresistor_ldr", ["a1", "a9"], {"r_light": 1000.0, "r_dark": 1000000.0, "light": 0.0})], [])
	t.near(float(_by_id(r, "L1").params["r"]), 1000000.0, "LDR dark = 1 MOhm", 1e-6)
	r = builder.build(bb, [_place("L1", "photoresistor_ldr", ["a1", "a9"], {"r_light": 1000.0, "r_dark": 1000000.0, "light": 1.0})], [])
	t.near(float(_by_id(r, "L1").params["r"]), 1000.0, "LDR bright = 1 kOhm", 1e-6)
	r = builder.build(bb, [_place("L1", "photoresistor_ldr", ["a1", "a9"], {"r_light": 1000.0, "r_dark": 1000000.0, "light": 0.5})], [])
	t.near(float(_by_id(r, "L1").params["r"]), 31622.7766, "LDR mid = geometric mean", 1e-4)
	r = builder.build(bb, [_place("PT1", "rtd_pt100", ["a1", "a9"], {"temperature": 100.0, "r0": 100.0})], [])
	t.near(float(_by_id(r, "PT1").params["r"]), 138.5, "PT100 at 100 degC = 138.5 Ohm", 1e-6)

	# ---- motors: winding + assumed back-EMF -------------------------------
	t.section("Netlist - brushed motor winding and back-EMF")
	r = builder.build(bb, [_place("M1", "dc_motor", ["a1", "a9"], {"r": 10.0, "back_emf": 0.0})], [])
	t.check(_by_id(r, "M1") != null and _by_id(r, "M1#emf") == null, "stalled motor is just its winding resistance")
	r = builder.build(bb, [_place("M1", "dc_motor", ["a1", "a9"], {"r": 10.0, "back_emf": 2.0})], [])
	t.check(_by_id(r, "M1") != null and _by_id(r, "M1#emf") != null, "running motor adds a back-EMF source")
	if _by_id(r, "M1#emf") != null:
		t.near(float(_by_id(r, "M1#emf").params["v"]), 2.0, "back-EMF = 2 V")
	var mcirc = builder.build(bb, [
		_place("V1", "vsource", ["TP1", "TM1"], {"v": 5.0}),
		_place("M1", "dc_motor", ["TP5", "a5"], {"r": 10.0, "back_emf": 2.0}),
		_place("GND", "ground", ["TM1"], {}),
	], [{"id": "W1", "a": _hole("a5"), "b": _hole("TM5")}])
	var mr = CircuitSolver.new().solve_dc(mcirc.circuit)
	t.check(mr.ok, "motor circuit solves", mr.get("error", ""))
	if mr.ok:
		t.near(mr.element_currents["M1"], 0.3, "current = (5-2)/10 = 0.3 A", 1e-3)
	r = builder.build(bb, [_place("SOL1", "solenoid_12v", ["a1", "a9"], {"r": 30.0, "l": 0.05})], [])
	t.check(_by_id(r, "SOL1") != null and _by_id(r, "SOL1#r") != null, "solenoid is a coil plus winding resistance")
	if _by_id(r, "SOL1") != null:
		t.check(_by_id(r, "SOL1").type == "inductor", "solenoid coil maps to an inductor")

	# ---- 7-segment display, limit switch, analog-output sensors -----------
	t.section("Netlist - 7-segment display and mechanical switch")
	r = builder.build(bb, [_place("DS1", "seven_segment", ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "TM1"], {"common": "cathode"})], [])
	var seg_count := 0
	for e2 in r.circuit.elements:
		if String(e2.id).begins_with("DS1#"):
			seg_count += 1
	t.check(seg_count == 8, "seven-segment display = 8 LED elements", "got=%d" % seg_count)
	var seg_a = _by_id(r, "DS1#A")
	t.check(seg_a != null and seg_a.type == "led", "segment A is an LED")
	if seg_a != null:
		t.check(seg_a.nets[0] == r.pin_nets["DS1"][0], "common cathode: anode at the segment pin")
		t.check(seg_a.nets[1] == r.pin_nets["DS1"][8], "common cathode: cathode at COM")
	r = builder.build(bb, [_place("DS1", "seven_segment", ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "TM1"], {"common": "anode"})], [])
	seg_a = _by_id(r, "DS1#A")
	if seg_a != null:
		t.check(seg_a.nets[0] == r.pin_nets["DS1"][8], "common anode: anode at COM")

	r = builder.build(bb, [_place("LS1", "limit_switch", ["a1", "a5", "a9"], {"actuated": false})], [])
	t.check(_by_id(r, "LS1") != null and _by_id(r, "LS1#2") != null, "limit switch makes COM-NO and COM-NC")
	if _by_id(r, "LS1") != null:
		t.check(float(_by_id(r, "LS1").params["r"]) > 1e6, "released: COM-NO open")
		t.check(float(_by_id(r, "LS1#2").params["r"]) < 1.0, "released: COM-NC closed")
	r = builder.build(bb, [_place("LS1", "limit_switch", ["a1", "a5", "a9"], {"actuated": true})], [])
	if _by_id(r, "LS1") != null:
		t.check(float(_by_id(r, "LS1").params["r"]) < 1.0, "actuated: COM-NO closed")
		t.check(float(_by_id(r, "LS1#2").params["r"]) > 1e6, "actuated: COM-NC open")

	t.section("Netlist - analog-output sensors (LM35 / TMP36 / divider)")
	r = builder.build(bb, [_place("T1", "lm35", ["TP1", "a1", "TM1"], {"temperature": 50.0})], [])
	t.check(_by_id(r, "T1") != null and _by_id(r, "T1").type == "vsource", "LM35 output is a voltage source")
	if _by_id(r, "T1") != null:
		t.near(float(_by_id(r, "T1").params["v"]), 0.5, "LM35 at 50 degC = 0.5 V", 1e-6)
	r = builder.build(bb, [_place("T1", "tmp36", ["TP1", "a1", "TM1"], {"temperature": 25.0})], [])
	if _by_id(r, "T1") != null:
		t.near(float(_by_id(r, "T1").params["v"]), 0.75, "TMP36 at 25 degC = 0.75 V", 1e-6)

	var dcirc = builder.build(bb, [
		_place("V1", "vsource", ["TP1", "TM1"], {"v": 10.0}),
		_place("VS1", "voltage_sensor_module", ["TP5", "TM5", "a1", "a5"], {"r1": 30000.0, "r2": 7500.0}),
		_place("GND", "ground", ["TM1"], {}),
	], [
		{"id": "W1", "a": _hole("a5"), "b": _hole("TP1")},
	])
	var dr = CircuitSolver.new().solve_dc(dcirc.circuit)
	t.check(dr.ok, "voltage sensor circuit solves", dr.get("error", ""))
	if dr.ok:
		t.near(dr.node_voltages[dcirc.pin_nets["VS1"][2]], 2.0, "divider SIG = 10 V * 7.5k/37.5k = 2 V", 1e-3)

	# ---- digital-output sensors + analog sensor modules --------------------
	t.section("Netlist - digital-output sensors and analog modules")
	r = builder.build(bb, [_place("PIR1", "pir_hcsr501", ["TP1", "a1", "TM1"], {"detected": true})], [])
	var pir = _by_id(r, "PIR1")
	t.check(pir != null and pir.type == "gpio", "PIR motion drives an ideal logic output")
	if pir != null:
		t.check(float(pir.params["level"]) == 1.0, "detected PIR output is high")
	r = builder.build(bb, [_place("PIR1", "pir_hcsr501", ["TP1", "a1", "TM1"], {"detected": false})], [])
	if _by_id(r, "PIR1") != null:
		t.check(float(_by_id(r, "PIR1").params["level"]) == 0.0, "idle PIR output is low")

	r = builder.build(bb, [_place("ACS1", "acs712", ["TP1", "TM1", "a1"], {"current": 0.0, "sensitivity": 0.185, "vcc": 5.0})], [])
	var acs = _by_id(r, "ACS1")
	t.check(acs != null and acs.type == "vsource", "ACS712 output is a voltage source")
	if acs != null:
		t.near(float(acs.params["v"]), 2.5, "zero current sits at Vcc/2", 1e-9)
	r = builder.build(bb, [_place("ACS1", "acs712", ["TP1", "TM1", "a1"], {"current": 5.0, "sensitivity": 0.185, "vcc": 5.0})], [])
	if _by_id(r, "ACS1") != null:
		t.near(float(_by_id(r, "ACS1").params["v"]), 2.5 + 0.925, "5 A reads 3.425 V", 1e-9)

	r = builder.build(bb, [_place("PT1", "pressure_transducer_420ma", ["TP1", "a1"], {"pressure": 0.0, "range_min": 0.0, "range_max": 10.0})], [])
	var pt = _by_id(r, "PT1")
	t.check(pt != null and pt.type == "isource", "pressure transducer is a current source")
	if pt != null:
		t.near(float(pt.params["i"]), 0.004, "0 bar -> 4 mA", 1e-9)
	r = builder.build(bb, [_place("PT1", "pressure_transducer_420ma", ["TP1", "a1"], {"pressure": 5.0, "range_min": 0.0, "range_max": 10.0})], [])
	if _by_id(r, "PT1") != null:
		t.near(float(_by_id(r, "PT1").params["i"]), 0.012, "half range -> 12 mA", 1e-9)
	r = builder.build(bb, [_place("PT1", "pressure_transducer_420ma", ["TP1", "a1"], {"pressure": 20.0, "range_min": 0.0, "range_max": 10.0})], [])
	if _by_id(r, "PT1") != null:
		t.near(float(_by_id(r, "PT1").params["i"]), 0.020, "over range clamps to 20 mA", 1e-9)

	r = builder.build(bb, [_place("LC1", "load_cell_5kg", ["TP1", "TM1", "a1", "a5"], {"load": 0.0, "capacity": 5.0, "r0": 1000.0, "sensitivity": 0.002})], [])
	t.check(_by_id(r, "LC1") != null and _by_id(r, "LC1#4") != null, "load cell builds a four-arm bridge")
	if _by_id(r, "LC1") != null:
		t.near(float(_by_id(r, "LC1").params["r"]), 1000.0, "unloaded arms are equal", 1e-9)
	r = builder.build(bb, [_place("LC1", "load_cell_5kg", ["TP1", "TM1", "a1", "a5"], {"load": 5.0, "capacity": 5.0, "r0": 1000.0, "sensitivity": 0.002})], [])
	if _by_id(r, "LC1") != null:
		t.near(float(_by_id(r, "LC1").params["r"]), 1002.0, "loaded arm rises by r0*sensitivity", 1e-9)
		t.near(float(_by_id(r, "LC1#2").params["r"]), 998.0, "opposite arm falls by r0*sensitivity", 1e-9)

	# ---- I2C I/O expander -------------------------------------------------
	t.section("Netlist - PCF8574 port follows its state byte")
	var pcf_holes := ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "TM1",
		"a9", "a10", "a11", "a12", "a13", "a14", "a15", "TP1"]
	r = builder.build(bb, [_place("U1", "pcf8574", pcf_holes, {"state": 0x55})], [])
	var port := []
	for n in 8:
		port.append(_by_id(r, "U1#P%d" % n))
	t.check(port[0] != null, "PCF8574 emits one gpio per port pin")
	if port[0] != null:
		var levels := ""
		for pe in port:
			levels += str(int(float(pe.params["level"])))
		t.check(levels == "10101010", "state 0x55 -> P0..P7 = 1,0,1,0,1,0,1,0", levels)
		t.check(port[0].nets[1] == r.pin_nets["U1"][7], "port pins reference VSS (pin 8)")
		t.near(float(port[0].params["vlogic"]), 5.0, "port logic level follows Vcc", 1e-9)
	r = builder.build(bb, [_place("U1", "pcf8574", pcf_holes, {"state": 0x00})], [])
	if _by_id(r, "U1#P0") != null:
		t.check(float(_by_id(r, "U1#P0").params["level"]) == 0.0, "state 0x00 -> all port pins low")
	r = builder.build(bb, [_place("U1", "pcf8574", pcf_holes, {"state": 0xFF})], [])
	if _by_id(r, "U1#P7") != null:
		t.check(float(_by_id(r, "U1#P7").params["level"]) == 1.0, "state 0xFF -> all port pins high")

	# ---- I2C ADC/DAC: analog probes + analog output -----------------------
	t.section("Netlist - PCF8591 maps ADC inputs and a DAC output")
	var adc_holes := ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "TM1",
		"a9", "a10", "a11", "a12", "a13", "a14", "a15", "TP1"]
	var adc_build = builder.build(bb, [
		_place("V1", "vsource", ["TP1", "TM1"], {"v": 4.0}),
		_place("R1", "resistor", ["TP1", "a1"], {"r": 1000.0}),
		_place("R2", "resistor", ["a1", "TM1"], {"r": 1000.0}),
		_place("AD1", "pcf8591", adc_holes, {"address": 72, "vref": 5.0, "aout": 2.0, "rout": 25.0}),
		_place("GND", "ground", ["TM1"]),
	], [])
	var probes := 0
	for n in 4:
		var pr = _by_id(adc_build, "AD1#AIN%d" % n)
		if pr != null and pr.type == "resistor":
			probes += 1
	t.check(probes == 4, "PCF8591 emits four high-impedance ADC probes", "probes=%d" % probes)
	var ain0 = _by_id(adc_build, "AD1#AIN0")
	if ain0 != null:
		t.near(float(ain0.params["r"]), 1.0e9, "AIN0 probe is 1 GOhm", 1.0)
		t.check(String(ain0.nets[1]) == "0", "AIN0 probe references ground")
	var aout = _by_id(adc_build, "AD1#AOUT")
	t.check(aout != null and aout.type == "vout", "PCF8591 emits a DAC output source")
	if aout != null:
		t.near(float(aout.params["voltage"]), 2.0, "DAC output voltage is carried through", 1e-9)
	var adc_res = CircuitSolver.new().solve_dc(adc_build.circuit)
	t.check(adc_res.ok, "PCF8591 circuit solves", adc_res.get("error", ""))
	if adc_res.ok:
		t.near(adc_res.node_voltages["a1"], 2.0, "AIN0 reads the divider midpoint", 1e-2)

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
