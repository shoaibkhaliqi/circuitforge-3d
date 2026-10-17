extends SceneTree
## Developer tool: generate the bundled example circuits as validated .cf3d files.
## Run: godot --headless --path <project> --script res://tools/make_examples.gd

const Session = preload("res://scripts/app/session.gd")

const EX_DIR := "res://data/examples"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EX_DIR))
	var examples := _definitions()
	var made := 0
	for e in examples:
		var s = Session.new()
		for c in e.components:
			s.add_component(c.type, c.holes, c.get("params", {}), c.get("id", ""))
		for w in e.get("wires", []):
			s.add_wire(w[0], w[1])
		s.project.metadata["name"] = e.name
		s.project.metadata["description"] = e.description
		s.project.metadata["measurement"] = e.measurement
		s.project.simulation = e.sim
		var path := "%s/%s.cf3d" % [EX_DIR, e.file]
		var r = s.save_project(path)
		if r:
			made += 1
			print("wrote ", path)
		else:
			print("FAILED ", path, " ", s.last_error)
	print("examples written: ", made, "/", examples.size())
	quit(0 if made == examples.size() else 1)


func _h(id: String) -> Dictionary:
	return {"kind": "hole", "id": id}


func _definitions() -> Array:
	return [
		{
			"file": "01_led_resistor", "name": "LED and Resistor",
			"description": "5 V through a 330 Ohm resistor into a red LED. Classic current-limiting setup.",
			"measurement": "Run DC. Expect LED forward voltage near 1.8 V and current near 9-10 mA.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 5.0}},
				{"type": "resistor", "holes": ["TP5", "a5"], "params": {"r": 330.0}},
				{"type": "led", "holes": ["a10", "TM10"]},
			],
			"wires": [[_h("a5"), _h("a10")]],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "02_series_resistors", "name": "Series Resistors",
			"description": "Two 1 kOhm resistors in series across a 9 V supply.",
			"measurement": "Run DC. Expect 4.5 V at the midpoint and 4.5 mA of current.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 9.0}},
				{"type": "resistor", "holes": ["TP5", "a5"], "params": {"r": 1000.0}},
				{"type": "resistor", "holes": ["a10", "TM10"], "params": {"r": 1000.0}},
			],
			"wires": [[_h("a5"), _h("a10")]],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "03_parallel_resistors", "name": "Parallel Resistors",
			"description": "Two 1 kOhm resistors in parallel across a 12 V supply.",
			"measurement": "Run DC. Expect 12 mA in each branch, 24 mA total, 500 Ohm equivalent.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 12.0}},
				{"type": "resistor", "holes": ["TP5", "TM5"], "params": {"r": 1000.0}},
				{"type": "resistor", "holes": ["TP10", "TM10"], "params": {"r": 1000.0}},
			],
			"wires": [],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "04_voltage_divider", "name": "Voltage Divider",
			"description": "10 V divided by two equal resistors gives 5 V at the midpoint.",
			"measurement": "Run DC. The midpoint net equals 5 V; each resistor drops 5 V.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 10.0}},
				{"type": "resistor", "holes": ["TP5", "a5"], "params": {"r": 1000.0}},
				{"type": "resistor", "holes": ["a10", "TM10"], "params": {"r": 1000.0}},
			],
			"wires": [[_h("a5"), _h("a10")]],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "05_rc_charging", "name": "RC Charging",
			"description": "1 kOhm and 100 uF in series from 5 V. Time constant tau = 0.1 s.",
			"measurement": "Run Transient (0.5 s, 1 ms). Capacitor reaches ~3.16 V at 0.1 s and ~4.97 V at 0.5 s.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 5.0}},
				{"type": "resistor", "holes": ["TP5", "a5"], "params": {"r": 1000.0}},
				{"type": "capacitor", "holes": ["a10", "TM10"], "params": {"c": 100e-6}},
			],
			"wires": [[_h("a5"), _h("a10")]],
			"sim": {"mode": "transient", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "06_rc_discharging", "name": "RC Discharging",
			"description": "Capacitor pre-charged to 5 V discharges through 1 kOhm. tau = 0.1 s.",
			"measurement": "Run Transient. Capacitor decays from 5 V toward 0 V.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "resistor", "holes": ["a5", "a10"], "params": {"r": 1000.0}},
				{"type": "capacitor", "holes": ["a10", "TM10"], "params": {"c": 100e-6, "ic": 5.0}},
				{"type": "ground", "holes": ["TM10"]},
			],
			"wires": [],
			"sim": {"mode": "transient", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "07_rl_response", "name": "RL Transient Response",
			"description": "5 V through 100 Ohm and 10 mH. tau = L/R = 0.1 ms.",
			"measurement": "Run Transient (1 ms, 1 us). Current rises to ~50 mA.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 5.0}},
				{"type": "resistor", "holes": ["TP5", "a5"], "params": {"r": 100.0}},
				{"type": "inductor", "holes": ["a10", "TM10"], "params": {"l": 10e-3}},
			],
			"wires": [[_h("a5"), _h("a10")]],
			"sim": {"mode": "transient", "t_stop": 0.001, "dt": 1e-6},
		},
		{
			"file": "08_half_wave_rectifier", "name": "Half-Wave Rectifier",
			"description": "A sine source through a diode produces half-wave output.",
			"measurement": "Run Transient. Output is only positive half-cycles minus the diode drop.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 5.0, "waveform": {"type": "sine", "amplitude": 5.0, "frequency": 50.0, "offset": 0.0}}},
				{"type": "diode", "holes": ["TP5", "a5"]},
				{"type": "resistor", "holes": ["a10", "TM10"], "params": {"r": 1000.0}},
			],
			"wires": [[_h("a5"), _h("a10")]],
			"sim": {"mode": "transient", "t_stop": 0.04, "dt": 1e-5},
		},
		{
			"file": "09_led_switch", "name": "Switch-Controlled LED",
			"description": "A series switch controls the LED. Set the switch to closed = true.",
			"measurement": "Run DC with the switch open (no current), then set closed=true and run again.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 5.0}},
				{"type": "switch", "holes": ["TP5", "a5"], "params": {"closed": true}},
				{"type": "resistor", "holes": ["a10", "b10"], "params": {"r": 330.0}},
				{"type": "led", "holes": ["b15", "TM10"]},
			],
			"wires": [[_h("a5"), _h("a10")], [_h("b10"), _h("b15")]],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "10_zener_regulator", "name": "Zener Regulator",
			"description": "A 5.1 V zener clamps the output of a 9 V supply through 470 Ohm.",
			"measurement": "Run DC. The zener node settles near the breakdown voltage (about -5.1 V across the zener).",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 9.0}},
				{"type": "resistor", "holes": ["TP5", "a5"], "params": {"r": 470.0}},
				{"type": "zener", "holes": ["a10", "TM10"], "params": {"vz": 5.1}},
			],
			"wires": [[_h("a5"), _h("a10")]],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "11_logic_and", "name": "Logic AND Gate",
			"description": "Two switches drive the inputs of an AND gate; the output drives an LED through 330 Ohm.",
			"measurement": "Run DC with both switches closed: the output is logic-high (5 V) and the LED lights. Open either switch (closed=false) and re-run: the output drops low.",
			"components": [
				{"type": "ground", "holes": ["TM1"]},
				{"type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 5.0}},
				{"type": "switch", "holes": ["TP5", "a5"], "params": {"closed": true}},
				{"type": "switch", "holes": ["TP10", "a10"], "params": {"closed": true}},
				{"type": "and", "holes": ["a5", "a10", "a15"]},
				{"type": "resistor", "holes": ["a15", "a20"], "params": {"r": 330.0}},
				{"type": "led", "holes": ["a20", "TM20"]},
			],
			"wires": [],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "12_seven_segment", "name": "7-Segment Display (virtual pins)",
			"description": "A common-cathode 7-segment display driven by two virtual MCU pins (Stage A), each segment through a 330 Ohm resistor.",
			"measurement": "Run DC: pins P1 and P2 are logic-high, so segments B and C light and the digit shows '1'. Set a pin's level to 0 and re-run to blank that segment. No firmware is executed.",
			"components": [
				{"id": "GND1", "type": "ground", "holes": ["TM1"]},
				{"id": "DS1", "type": "seven_segment", "holes": ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "TM1"], "params": {"common": "cathode"}},
				{"id": "R1", "type": "resistor", "holes": ["e2", "f2"], "params": {"r": 330.0}},
				{"id": "R2", "type": "resistor", "holes": ["e3", "f3"], "params": {"r": 330.0}},
				{"id": "P1", "type": "mcu_pin", "holes": ["a15", "f15"], "params": {"level": 1.0, "rout": 25.0, "vlogic": 5.0}},
				{"id": "P2", "type": "mcu_pin", "holes": ["a20", "f20"], "params": {"level": 1.0, "rout": 25.0, "vlogic": 5.0}},
			],
			"wires": [[_h("f2"), _h("a15")], [_h("f3"), _h("a20")], [_h("f15"), _h("TM25")], [_h("f20"), _h("TM25")]],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "13_ntc_thermistor", "name": "NTC Thermistor Divider",
			"description": "A 10k NTC thermistor and a fixed 10k resistor form a divider across 5 V; the sense node carries a voltage that tracks temperature.",
			"measurement": "Run DC at 25 C: the NTC is 10k, so the sense node is 2.5 V. Set the thermistor temperature to 50 C and re-run: the resistance drops (about 3.6k) and the node rises to about 3.6 V.",
			"components": [
				{"id": "GND1", "type": "ground", "holes": ["TM1"]},
				{"id": "V1", "type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 5.0}},
				{"id": "RT1", "type": "thermistor_ntc", "holes": ["TP5", "a5"], "params": {"beta": 3950.0, "r25": 10000.0, "temperature": 25.0}},
				{"id": "R1", "type": "resistor", "holes": ["a10", "TM10"], "params": {"r": 10000.0}},
			],
			"wires": [[_h("a5"), _h("a10")]],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
		{
			"file": "14_limit_switch_motor", "name": "Limit Switch Drives a DC Motor",
			"description": "A limit switch (SPDT) switches 5 V to a small brushed DC motor; the motor is modelled as stalled (assumed back-EMF 0 V).",
			"measurement": "Run DC with the switch actuated: COM-NO closes, so the motor sees 5 V and draws about 1 A (5 V across 5 Ohm). Set actuated to false and re-run: COM-NO opens and the current falls to almost zero.",
			"components": [
				{"id": "GND1", "type": "ground", "holes": ["TM1"]},
				{"id": "V1", "type": "vsource", "holes": ["TP1", "TM1"], "params": {"v": 5.0}},
				{"id": "SW1", "type": "limit_switch", "holes": ["a1", "a5", "a10"], "params": {"actuated": true}},
				{"id": "M1", "type": "dc_motor", "holes": ["a15", "TM5"], "params": {"back_emf": 0.0, "r": 5.0, "v_nom": 6.0}},
			],
			"wires": [[_h("TP1"), _h("a1")], [_h("a5"), _h("a15")]],
			"sim": {"mode": "dc", "t_stop": 0.5, "dt": 0.001},
		},
	]
