extends RefCounted
## Verifies every bundled example opens, validates and simulates as documented.

const Persistence = preload("res://scripts/persistence/persistence.gd")
const Breadboard = preload("res://scripts/breadboard/breadboard.gd")
const NetlistBuilder = preload("res://scripts/connectivity/netlist_builder.gd")
const CircuitSolver = preload("res://scripts/simulation/solver.gd")

const EX_DIR := "res://data/examples"


func run(t) -> void:
	t.section("Examples - load, validate and simulate")
	var dir := DirAccess.open(EX_DIR)
	if dir == null:
		t.check(false, "examples directory not found: %s" % EX_DIR)
		t.done()
		return
	var files := []
	dir.list_dir_begin()
	var fn := dir.get_next()
	while fn != "":
		if fn.ends_with(".cf3d"):
			files.append(fn)
		fn = dir.get_next()
	dir.list_dir_end()
	files.sort()
	t.check(files.size() >= 16, "at least 16 bundled examples present", "found %d" % files.size())

	var solver = CircuitSolver.new()
	var builder = NetlistBuilder.new()
	var built_count := 0
	for f in files:
		var path := "%s/%s" % [EX_DIR, f]
		var lr = Persistence.load_from_file(path)
		if not t.check(lr.ok, "example loads: %s" % f, lr.get("error", "")):
			continue
		var proj = lr.project
		var bb = Breadboard.new(int(proj.breadboard.get("rows", 30)), bool(proj.breadboard.get("rail_split", false)))
		var built = builder.build(bb, proj.components, proj.wires)
		var mode := String(proj.get("simulation", {}).get("mode", "dc"))
		if mode == "transient":
			var res = solver.solve_transient(built.circuit, {
				"t_stop": float(proj.simulation.get("t_stop", 0.5)),
				"dt": float(proj.simulation.get("dt", 1e-3)),
			})
			t.check(res.ok, "example transient solves: %s" % f, res.get("error", ""))
			if res.ok:
				t.check(res.samples.size() > 1, "example produced samples: %s" % f)
		else:
			# RC discharge uses initial conditions; treat all DC here.
			var res = solver.solve_dc(built.circuit)
			t.check(res.ok, "example DC solves: %s" % f, res.get("error", ""))
		built_count += 1

	t.check(built_count == files.size(), "all example circuits simulated", "%d/%d" % [built_count, files.size()])

	# Spot-check documented results for two examples.
	t.section("Examples - documented values")
	var lr1 = Persistence.load_from_file("%s/01_led_resistor.cf3d" % EX_DIR)
	if lr1.ok:
		var bb1 = Breadboard.new(30)
		var b1 = builder.build(bb1, lr1.project.components, lr1.project.wires)
		var r1 = solver.solve_dc(b1.circuit)
		if t.check(r1.ok, "LED example solves"):
			var i = 0.0
			for k in r1.element_currents:
				if String(k).begins_with("D"):
					i = absf(float(r1.element_currents[k]))
			t.check(i > 0.005 and i < 0.015, "LED example current 5-15 mA", "I=" + str(i))

	var lr4 = Persistence.load_from_file("%s/04_voltage_divider.cf3d" % EX_DIR)
	if lr4.ok:
		var bb4 = Breadboard.new(30)
		var b4 = builder.build(bb4, lr4.project.components, lr4.project.wires)
		var r4 = solver.solve_dc(b4.circuit)
		if t.check(r4.ok, "divider example solves"):
			var found := false
			for k in r4.node_voltages:
				if absf(float(r4.node_voltages[k]) - 5.0) < 1e-3:
					found = true
			t.check(found, "divider has a 5 V node somewhere")

	var lr11 = Persistence.load_from_file("%s/11_logic_and.cf3d" % EX_DIR)
	if lr11.ok:
		var bb11 = Breadboard.new(30)
		var b11 = builder.build(bb11, lr11.project.components, lr11.project.wires)
		var r11 = solver.solve_dc(b11.circuit)
		if t.check(r11.ok, "logic AND example solves"):
			var led_i := 0.0
			for k in r11.element_currents:
				if String(k) == "D1":
					led_i = absf(float(r11.element_currents[k]))
			t.check(led_i > 0.001, "AND(1,1) lights the LED", "I=" + str(led_i))

	var lr12 = Persistence.load_from_file("%s/12_seven_segment.cf3d" % EX_DIR)
	if lr12.ok:
		var bb12 = Breadboard.new(30)
		var b12 = builder.build(bb12, lr12.project.components, lr12.project.wires)
		var r12 = solver.solve_dc(b12.circuit)
		if t.check(r12.ok, "7-segment example solves"):
			var i_b := absf(float(r12.element_currents.get("DS1#B", 0.0)))
			var i_c := absf(float(r12.element_currents.get("DS1#C", 0.0)))
			var i_a := absf(float(r12.element_currents.get("DS1#A", 0.0)))
			t.check(i_b > 0.002, "segment B lit (>2 mA)", "I=" + str(i_b))
			t.check(i_c > 0.002, "segment C lit (>2 mA)", "I=" + str(i_c))
			t.check(i_a < 1e-6, "unwired segment A dark", "I=" + str(i_a))

	var lr13 = Persistence.load_from_file("%s/13_ntc_thermistor.cf3d" % EX_DIR)
	if lr13.ok:
		var bb13 = Breadboard.new(30)
		var b13 = builder.build(bb13, lr13.project.components, lr13.project.wires)
		var r13 = solver.solve_dc(b13.circuit)
		if t.check(r13.ok, "thermistor example solves"):
			var vsense := float(r13.node_voltages.get(b13.pin_nets["RT1"][1], 0.0))
			t.check(absf(vsense - 2.5) < 0.01, "NTC at 25 C => 2.5 V sense node", "V=" + str(vsense))

	var lr14 = Persistence.load_from_file("%s/14_limit_switch_motor.cf3d" % EX_DIR)
	if lr14.ok:
		var bb14 = Breadboard.new(30)
		var b14 = builder.build(bb14, lr14.project.components, lr14.project.wires)
		var r14 = solver.solve_dc(b14.circuit)
		if t.check(r14.ok, "limit-switch/motor example solves"):
			var i_m := absf(float(r14.element_currents.get("M1", 0.0)))
			t.check(i_m > 0.9 and i_m < 1.1, "motor draws about 1 A", "I=" + str(i_m))

	# Firmware example: the DHT22 DATA net is shared with the virtual MCU pin P1, which
	# is exactly what run_firmware(pin_map={"2": "P1"}) resolves at run time.
	t.section("Examples - firmware example wiring")
	var lr15 = Persistence.load_from_file("%s/15_firmware_env_logger.cf3d" % EX_DIR)
	if t.check(lr15.ok, "firmware example loads", lr15.get("error", "")):
		var bb15 = Breadboard.new(30)
		var b15 = builder.build(bb15, lr15.project.components, lr15.project.wires)
		var dht_nets: Array = b15.pin_nets.get("DHT1", [])
		var pin_nets: Array = b15.pin_nets.get("P1", [])
		t.check(dht_nets.size() >= 2 and pin_nets.size() >= 1
				and String(dht_nets[1]) == String(pin_nets[0]),
			"DHT22 DATA shares the virtual pin P1 net",
			"%s vs %s" % [str(dht_nets), str(pin_nets)])
		var r15 = solver.solve_dc(b15.circuit)
		if t.check(r15.ok, "firmware example solves"):
			t.check(b15.get("warnings", []).size() > 0, "unmapped devices are skipped with a warning")

	# Motion example: both firmware-driven actuators, each on the net of a virtual MCU pin,
	# which is what run_firmware(pin_map={"9": "P1", "3": "P2", "2": "P3"}) resolves.
	t.section("Examples - firmware motion example wiring")
	var lr16 = Persistence.load_from_file("%s/16_firmware_motion.cf3d" % EX_DIR)
	if t.check(lr16.ok, "motion example loads", lr16.get("error", "")):
		var bb16 = Breadboard.new(30)
		var b16 = builder.build(bb16, lr16.project.components, lr16.project.wires)
		var servo_nets: Array = b16.pin_nets.get("S1", [])
		var p1_nets: Array = b16.pin_nets.get("P1", [])
		t.check(servo_nets.size() >= 3 and p1_nets.has(String(servo_nets[2])),
			"servo PWM shares the virtual pin P1 net",
			"%s vs %s" % [str(servo_nets), str(p1_nets)])
		var drv_nets: Array = b16.pin_nets.get("U1", [])
		var p2_nets: Array = b16.pin_nets.get("P2", [])
		var p3_nets: Array = b16.pin_nets.get("P3", [])
		t.check(drv_nets.size() >= 15 and p2_nets.has(String(drv_nets[6])),
			"driver STEP shares the virtual pin P2 net",
			"%s vs %s" % [str(drv_nets), str(p2_nets)])
		t.check(p3_nets.has(String(drv_nets[7])),
			"driver DIR shares the virtual pin P3 net", "%s vs %s" % [str(drv_nets), str(p3_nets)])
		var motor_nets: Array = b16.pin_nets.get("M1", [])
		var coils_ok := motor_nets.size() >= 4
		for i in 4:
			if not drv_nets.has(String(motor_nets[i])):
				coils_ok = false
		t.check(coils_ok, "the NEMA 17 coils sit on the driver's coil-output nets",
			"%s vs %s" % [str(motor_nets), str(drv_nets)])
		var r16 = solver.solve_dc(b16.circuit)
		t.check(r16.ok, "motion example solves", r16.get("error", ""))

	t.done()
