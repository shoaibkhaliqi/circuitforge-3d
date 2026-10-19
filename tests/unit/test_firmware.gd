extends RefCounted
## Firmware backend (M7 Stage B) — pure contract tests.
##
## These never require Node: they cover pin-key normalisation, pin sampling,
## labels, and that `capabilities()` is honest (reports a reason when unavailable
## rather than pretending firmware works). The real compile+run path lives in
## firmware/harness/verify.mjs and is run separately, so the Godot suite stays
## runnable with only Godot installed.

const FirmwareBackend = preload("res://scripts/simulation/firmware_backend.gd")
const AppService = preload("res://scripts/api/app_service.gd")


func _tr(pin: int, t: float, level: int) -> Dictionary:
	return {"t_ms": t, "digital_pin": pin, "level": level}


## Transitions for a four-phase pattern list the way the harness reports them: one entry per
## changed bit, all bits of one port write sharing a timestamp (IN1..IN4 are D8..D11).
func _phase_trs(patterns: Array) -> Array:
	var out := []
	var lvls := [0, 0, 0, 0]
	var t := 0.0
	for p in patterns:
		t += 1.0
		for i in 4:
			var bit := (int(p) >> i) & 1
			if bit != lvls[i]:
				lvls[i] = bit
				out.append(_tr(8 + i, t, bit))
	return out


func run(t) -> void:
	t.section("Firmware - pin key normalisation")
	t.check(FirmwareBackend.pin_number("13") == 13, "bare number")
	t.check(FirmwareBackend.pin_number("D13") == 13, "D-prefixed")
	t.check(FirmwareBackend.pin_number("d7") == 7, "lower case")
	t.check(FirmwareBackend.pin_number("A0") == 14, "analog A0 -> 14")
	t.check(FirmwareBackend.pin_number("A5") == 19, "analog A5 -> 19")
	t.check(FirmwareBackend.pin_number("nope") == -1, "unknown -> -1")

	t.section("Firmware - pin labels")
	t.check(FirmwareBackend.label(13) == "D13", "13 -> D13")
	t.check(FirmwareBackend.label(14) == "A0", "14 -> A0")
	t.check(FirmwareBackend.label(19) == "A5", "19 -> A5")

	t.section("Firmware - sampling transitions")
	var trs := [_tr(13, 0.0, 1), _tr(13, 500.0, 0), _tr(13, 1000.0, 1), _tr(12, 250.0, 1)]
	var at0 := FirmwareBackend.levels_at(trs, 0.0)
	t.check(at0.get(13) == 1, "t=0 D13 high")
	t.check(at0.get(12) == 0, "t=0 D12 defaults low")
	var at300 := FirmwareBackend.levels_at(trs, 300.0)
	t.check(at300.get(13) == 1 and at300.get(12) == 1, "t=300 D13 high, D12 high")
	var at750 := FirmwareBackend.levels_at(trs, 750.0)
	t.check(at750.get(13) == 0, "t=750 D13 low")
	var at2000 := FirmwareBackend.levels_at(trs, 2000.0)
	t.check(at2000.get(13) == 1, "t=2000 D13 high again")

	t.section("Firmware - pins touched")
	var touched := FirmwareBackend.pins_touched(trs)
	t.check(touched == [12, 13], "touched == [12, 13]", str(touched))

	t.section("Firmware - serial decode helpers")
	var lines := FirmwareBackend.serial_lines("a\r\nb\n\nc\n")
	t.check(lines == ["a", "b", "c"], "serial_lines drops CR and empties", str(lines))
	t.check(FirmwareBackend.serial_lines("").is_empty(), "empty serial -> no lines")
	var long := "x".repeat(FirmwareBackend.MAX_SERIAL_CHARS + 50)
	var cut := FirmwareBackend.truncate_serial(long)
	t.check(cut.length() < long.length(), "long serial is truncated")
	t.check(cut.ends_with("[serial truncated]"), "truncation is marked")
	t.check(FirmwareBackend.truncate_serial("hi") == "hi", "short serial is untouched")

	t.section("Firmware - I2C trace summary")
	var ev := [
		{"address": 39, "write": true, "bytes": [0, 65]},
		{"address": 39, "write": true, "bytes": [0, 65]},
		{"address": 0x3C, "write": false, "bytes": []},
	]
	var addrs := FirmwareBackend.i2c_addresses(ev)
	t.check(addrs == ["0x27", "0x3C"], "unique sorted addresses", str(addrs))
	t.check(FirmwareBackend.i2c_addresses([]).is_empty(), "no events -> no addresses")
	t.check(FirmwareBackend.last_i2c_write_byte(ev, 0x27) == 65,
		"last write byte to 0x27 is the port byte", str(FirmwareBackend.last_i2c_write_byte(ev, 0x27)))
	t.check(FirmwareBackend.last_i2c_write_byte(ev, 0x3C) == -1, "a read is not a device write")
	t.check(FirmwareBackend.last_i2c_write_byte([], 0x27) == -1, "no events -> -1")
	t.check(FirmwareBackend.last_i2c_write_byte([{"address": 0x27, "write": true, "bytes": []}], 0x27) == -1,
		"an empty write has no byte")
	var ev2 := [
		{"address": 0x27, "write": true, "bytes": [0x55]},
		{"address": 0x20, "write": true, "bytes": [0xFF]},
		{"address": 0x27, "write": true, "bytes": [0xAA]},
	]
	t.check(FirmwareBackend.last_i2c_write_byte(ev2, 0x27) == 0xAA,
		"latest write wins", str(FirmwareBackend.last_i2c_write_byte(ev2, 0x27)))
	var ev3 := [
		{"address": 0x27, "write": true, "bytes": [0xFF]},
		{"address": 0x27, "write": false, "bytes": [0xF0]},
	]
	t.check(FirmwareBackend.last_i2c_read_byte(ev3, 0x27) == 0xF0,
		"read byte is what the device returned", str(FirmwareBackend.last_i2c_read_byte(ev3, 0x27)))
	t.check(FirmwareBackend.last_i2c_read_byte(ev3, 0x20) == -1, "no read at that address -> -1")
	t.check(FirmwareBackend.last_i2c_read_byte([], 0x27) == -1, "no events -> no read byte")

	t.section("Firmware - PWM duty summary parsing")
	var pwm := {"9": {"duty": 0.50176, "freq_hz": 490}, "10": {"duty": 1.0}}
	t.near(FirmwareBackend.pwm_duty(pwm, 9), 0.50176, "duty from the summary", 1e-6)
	t.near(FirmwareBackend.pwm_duty(pwm, 10), 1.0, "full duty reads 1.0", 1e-6)
	t.check(FirmwareBackend.pwm_duty(pwm, 11) < 0.0, "a pin with no PWM -> -1")
	t.check(FirmwareBackend.pwm_duty({}, 9) < 0.0, "empty summary -> -1")
	t.near(FirmwareBackend.pwm_duty({"9": {"duty": 2.5}}, 9), 1.0, "duty is clamped to 1", 1e-6)

	t.section("Firmware - servo pulse measurement")
	# A 50 Hz servo sweep: 544 us (0 deg) ... 2400 us (180 deg), then settled at 1472 us.
	var srv := []
	var t_ms := 0.0
	for us in [544.0, 853.0, 1163.0, 1472.0, 1781.0, 2091.0, 2400.0]:
		srv.append(_tr(9, t_ms, 1))
		srv.append(_tr(9, t_ms + us / 1000.0, 0))
		t_ms += 20.0
	srv.append(_tr(9, t_ms + 0.0, 1))
	srv.append(_tr(9, t_ms + 1.472, 0))
	var widths := FirmwareBackend.pulse_widths(srv, 9)
	t.check(widths.size() == 8, "eight pulses measured", str(widths.size()))
	t.near(float(widths[0]), 544.0, "first pulse is 544 us", 0.01)
	t.near(float(widths[6]), 2400.0, "seventh pulse is 2400 us", 0.01)
	t.check(FirmwareBackend.pulse_widths(srv, 10).is_empty(), "another pin has no pulses")
	t.near(FirmwareBackend.servo_angle(544.0), 0.0, "544 us -> 0 deg", 1e-3)
	t.near(FirmwareBackend.servo_angle(2400.0), 180.0, "2400 us -> 180 deg", 1e-3)
	t.near(FirmwareBackend.servo_angle(1472.0), 90.0, "1472 us -> 90 deg", 1e-3)
	t.near(FirmwareBackend.servo_angle(100.0), 0.0, "below the band clamps to 0", 1e-3)
	t.near(FirmwareBackend.servo_angle(5000.0), 180.0, "above the band clamps to 180", 1e-3)
	var pos := FirmwareBackend.servo_position(srv, 9)
	t.check(int(pos.pulses) == 8, "position counts every pulse")
	t.near(float(pos.last_us), 1472.0, "last pulse is 1472 us", 0.01)
	t.near(float(pos.angle_deg), 90.0, "the settled pulse commands 90 deg", 0.01)
	t.near(float(pos.min_us_seen), 544.0, "sweep minimum seen", 0.01)
	t.near(float(pos.max_us_seen), 2400.0, "sweep maximum seen", 0.01)
	var none := FirmwareBackend.servo_position(srv, 3)
	t.check(int(none.pulses) == 0 and float(none.angle_deg) < 0.0, "no pulses -> no angle")

	t.section("Firmware - stepper STEP/DIR counting")
	# Five steps with DIR high, then three with DIR low - the classic sweep move.
	var step_trs := []
	var st := 0.0
	step_trs.append(_tr(2, st, 1))
	for i in 5:
		st += 1.0
		step_trs.append(_tr(3, st, 1))
		step_trs.append(_tr(3, st + 0.005, 0))
	st += 1.0
	step_trs.append(_tr(2, st, 0))
	for i in 3:
		st += 1.0
		step_trs.append(_tr(3, st, 1))
		step_trs.append(_tr(3, st + 0.005, 0))
	var sc := FirmwareBackend.stepper_steps(step_trs, 3, 2)
	t.check(int(sc.steps) == 2, "5 forward then 3 reverse nets +2 steps", str(sc.steps))
	t.check(int(sc.forward) == 5, "five forward steps", str(sc.forward))
	t.check(int(sc.reverse) == 3, "three reverse steps", str(sc.reverse))
	t.check(int(sc.last_dir) == 0, "last DIR level is low")
	t.check(int(FirmwareBackend.stepper_steps(step_trs, 3, 2, false).steps) == -2, "flipped polarity nets -2 steps")
	t.check(int(FirmwareBackend.stepper_steps(step_trs, 3).steps) == 8, "no DIR pin -> all forward")
	var single := FirmwareBackend.stepper_steps([_tr(3, 1.0, 1), _tr(3, 1.005, 0)], 3)
	t.check(int(single.steps) == 1 and int(single.forward) == 1, "one rising edge -> one step")
	t.check(int(FirmwareBackend.stepper_steps(step_trs, 7, 2).steps) == 0, "a pin with no edges -> no steps")
	t.check(int(FirmwareBackend.stepper_steps(step_trs, -1, 2).steps) == 0, "no step pin -> no steps")

	t.section("Firmware - stepper four-phase (ULN2003) sequence")
	# Half-step driving: each pattern change is one half step (bit 0 = IN1).
	var half := FirmwareBackend.stepper_phases(_phase_trs([1, 3, 2, 6, 4, 12, 8, 9, 1]), [8, 9, 10, 11])
	t.check(int(half.steps) == 8, "half-step cycle of 9 patterns -> 8 half steps", str(half.steps))
	t.check(int(half.changes) == 8, "eight pattern changes", str(half.changes))
	t.check(int(half.forward) == 8 and int(half.reverse) == 0, "all forward")
	t.check(int(half.skipped) == 0, "a clean sequence skips nothing")
	# Wave driving changes two coils at once: those two transitions share one timestamp, so
	# they are one pattern change worth two half steps - not an invalid pattern in between.
	var wave := FirmwareBackend.stepper_phases(_phase_trs([1, 2, 4, 8, 1]), [8, 9, 10, 11])
	t.check(int(wave.steps) == 8 and int(wave.changes) == 4, "wave cycle -> 4 changes of 2 half steps", str(wave.steps))
	var back := FirmwareBackend.stepper_phases(_phase_trs([1, 8, 4, 2, 1]), [8, 9, 10, 11])
	t.check(int(back.steps) == -8 and int(back.reverse) == 8, "the wave cycle backwards -> -8", str(back.steps))
	# A coil-off pattern breaks the sequence: nothing is counted across it.
	var gap := FirmwareBackend.stepper_phases(_phase_trs([1, 3, 0, 2]), [8, 9, 10, 11])
	t.check(int(gap.steps) == 1, "coils released -> the sequence restarts", str(gap.steps))
	t.check(int(gap.skipped) == 1, "the coil-off pattern is counted as skipped")
	# A 180-degree jump has no defined direction, so it is skipped rather than guessed.
	var jump := FirmwareBackend.stepper_phases(_phase_trs([1, 4]), [8, 9, 10, 11])
	t.check(int(jump.steps) == 0 and int(jump.skipped) == 1, "180-degree jump is not counted")
	# Non-phase pins and too-few wired phases are ignored.
	var noise := _phase_trs([1, 3])
	noise.append(_tr(13, 0.5, 1))
	t.check(int(FirmwareBackend.stepper_phases(noise, [8, 9, 10, 11]).steps) == 1, "D13 transitions are ignored")
	t.check(int(FirmwareBackend.stepper_phases(_phase_trs([1, 3]), [-1, -1, -1, -1]).steps) == 0,
		"no wired phases -> no steps")

	t.section("Firmware - stepper angle mapping")
	t.near(FirmwareBackend.stepper_angle(150.0, 200.0, 16.0), 16.875, "150 of 3200 microsteps", 1e-3)
	t.near(FirmwareBackend.stepper_angle(150.0, 200.0, 1.0), 270.0, "150 of 200 full steps", 1e-3)
	t.near(FirmwareBackend.stepper_angle(200.0, 200.0, 1.0), 0.0, "one full turn wraps to 0", 1e-3)
	t.near(FirmwareBackend.stepper_angle(-50.0, 200.0, 1.0), 270.0, "negative travel wraps", 1e-3)
	t.near(FirmwareBackend.stepper_angle(0.0, 200.0, 1.0), 0.0, "no steps -> 0 deg", 1e-3)

	t.section("Firmware - capabilities honesty")
	var cap := FirmwareBackend.capabilities()
	t.check(cap.get("engine") == "avr8js", "engine is avr8js")
	t.check(cap.get("engine_license") == "MIT", "engine license is MIT")
	t.check(typeof(cap.get("available")) == TYPE_BOOL, "available is a bool")
	if not bool(cap.get("available")):
		var reasons: Array = cap.get("unavailable_reasons", [])
		t.check(reasons.size() > 0, "unavailable reports a reason")

	t.section("Firmware - missing file is a clean error, never a fake success")
	var r := FirmwareBackend.run_hex("res://does-not-exist.hex", 100)
	t.check(not bool(r.get("ok", true)), "missing hex does not claim success")
	t.check(String(r.get("error", "")) != "", "missing hex reports an error string")

	t.section("Firmware - SPI display device spec from the circuit")
	# The app builds the harness spec itself: an SPI panel has no address, so its DC and
	# CS lines must resolve to firmware pins through `pin_map` (the same net lookup the
	# HC-SR04/encoder use). Without DC the stream cannot be tagged, so nothing is sent.
	var app = AppService.new()
	app.session.add_component("ground", ["TM1"])
	app.session.add_component("mcu_pin", ["b2", "TM6"], {}, "P1")     # DC
	app.session.add_component("mcu_pin", ["b3", "TM7"], {}, "P2")     # CS
	app.session.add_component("oled_ssd1306_spi",
		["TM4", "TP4", "d5", "d6", "b4", "a2", "a3"], {"cols": 128, "pages": 8}, "D1")
	var built: Dictionary = app.session.build_circuit()
	var specs: Array = app._firmware_devices({}, built.pin_nets, {"9": "P1", "10": "P2"})
	t.check(specs.size() == 1, "SPI OLED produces one device spec", str(specs))
	if specs.size() == 1:
		var sp: Dictionary = specs[0]
		t.check(String(sp.get("kind", "")) == "ssd1306_spi", "spec kind is ssd1306_spi")
		t.check(int(sp.get("dc", -1)) == 9, "DC pin resolved from pin_map", str(sp))
		t.check(int(sp.get("cs", -1)) == 10, "CS pin resolved from pin_map", str(sp))
		t.check(int(sp.get("cols", 0)) == 128 and int(sp.get("pages", 0)) == 8, "size from params")

	# A panel whose DC line no firmware pin drives is skipped, not guessed at.
	var app2 = AppService.new()
	app2.session.add_component("ground", ["TM1"])
	app2.session.add_component("oled_ssd1306_spi",
		["TM4", "TP4", "d5", "d6", "b4", "a20", "a21"], {"cols": 128, "pages": 8}, "D1")
	var built2: Dictionary = app2.session.build_circuit()
	var specs2: Array = app2._firmware_devices({}, built2.pin_nets, {"9": "P1"})
	t.check(specs2.is_empty(), "unwired DC => no spec (the stream cannot be tagged)", str(specs2))

	# The colour TFT is resolved the same way, from its own pin order (CS = 2, DC = 4).
	var app3 = AppService.new()
	app3.session.add_component("ground", ["TM1"])
	app3.session.add_component("mcu_pin", ["b2", "TM6"], {}, "P2")     # TFT CS
	app3.session.add_component("mcu_pin", ["b3", "TM7"], {}, "P3")     # TFT DC
	app3.session.add_component("tft_ili9341",
		["TP2", "TM5", "a2", "d3", "a3", "d4", "d5", "TP3", "d6"],
		{"width": 240, "height": 320}, "T1")
	var built3: Dictionary = app3.session.build_circuit()
	var specs3: Array = app3._firmware_devices({}, built3.pin_nets, {"9": "P3", "10": "P2"})
	t.check(specs3.size() == 1, "TFT produces one device spec", str(specs3))
	if specs3.size() == 1:
		var tp: Dictionary = specs3[0]
		t.check(String(tp.get("kind", "")) == "ili9341", "spec kind is ili9341")
		t.check(int(tp.get("dc", -1)) == 9, "TFT DC pin resolved from pin_map", str(tp))
		t.check(int(tp.get("cs", -1)) == 10, "TFT CS pin resolved from pin_map", str(tp))
		t.check(int(tp.get("width", 0)) == 240 and int(tp.get("height", 0)) == 320, "TFT size from params")

	# The SPI ADC answers reads: its CS comes from pin_map (pin 9) and its CH0..CH7 pins
	# are probes on the solved nets, so a divider the circuit solves can be read by
	# firmware. Without CS a conversion cannot be framed, so the part is skipped.
	var app4 = AppService.new()
	app4.session.add_component("ground", ["TM1"])
	app4.session.add_component("mcu_pin", ["c2", "TM9"], {}, "P2")     # ADC CS
	app4.session.add_component("mcp3008",
		["a1", "a4", "a5", "a6", "a7", "a8", "a9", "a10",
			"TM2", "a2", "d3", "d4", "d5", "TM3", "TP2", "TP3"],
		{"vref": 3.3}, "M1")
	var built4: Dictionary = app4.session.build_circuit()
	var adc_nets: Array = (built4.pin_nets as Dictionary).get("M1", [])
	t.check(adc_nets.size() == 16, "MCP3008 contributes 16 nets", str(adc_nets))
	var volts := {}
	if adc_nets.size() == 16:
		volts[String(adc_nets[0])] = 2.5
		volts[String(adc_nets[2])] = 1.0
	var specs4: Array = app4._firmware_devices(volts, built4.pin_nets, {"9": "P2"})
	t.check(specs4.size() == 1, "MCP3008 produces one device spec", str(specs4))
	if specs4.size() == 1:
		var sp: Dictionary = specs4[0]
		t.check(String(sp.get("kind", "")) == "mcp3008", "spec kind is mcp3008")
		t.check(int(sp.get("cs", -1)) == 9, "ADC CS pin resolved from pin_map", str(sp))
		t.check(absf(float(sp.get("vref", 0.0)) - 3.3) < 1e-6, "ADC vref comes from params")
		var ain: Array = sp.get("ain", [])
		t.check(ain.size() == 8, "ADC spec carries eight channels", str(ain))
		if ain.size() == 8:
			t.check(absf(float(ain[0]) - 2.5) < 1e-6, "CH0 probes its solved net", str(ain))
			t.check(absf(float(ain[2]) - 1.0) < 1e-6, "CH2 probes its solved net", str(ain))
			t.check(absf(float(ain[1])) < 1e-9, "an unwired channel reads 0 V", str(ain))
	var specs5: Array = app4._firmware_devices(volts, built4.pin_nets, {})
	t.check(specs5.is_empty(), "unwired ADC CS => no spec (a conversion cannot be framed)",
		str(specs5))

	# The ADXL345 is an I2C register file like the MPU-6050: its address and the sample
	# accelerations come from params, and no netlist is needed to serve it.
	var app5 = AppService.new()
	app5.session.add_component("ground", ["TM1"])
	app5.session.add_component("adxl345",
		["TP1", "TM1", "d2", "d3"], {"ax": 0.5, "ay": -0.25, "az": 1.0}, "A1")
	var built5: Dictionary = app5.session.build_circuit()
	var specs6: Array = app5._firmware_devices({}, built5.pin_nets, {})
	t.check(specs6.size() == 1, "ADXL345 produces one device spec", str(specs6))
	if specs6.size() == 1:
		var sa: Dictionary = specs6[0]
		t.check(String(sa.get("kind", "")) == "adxl345", "spec kind is adxl345")
		t.check(int(sa.get("address", -1)) == 83, "default I2C address is 0x53", str(sa))
		t.check(absf(float(sa.get("ax", 0.0)) - 0.5) < 1e-9, "ax comes from params", str(sa))
		t.check(absf(float(sa.get("ay", 0.0)) + 0.25) < 1e-9, "ay comes from params", str(sa))
		t.check(absf(float(sa.get("az", 0.0)) - 1.0) < 1e-9, "az comes from params", str(sa))

	t.done()
