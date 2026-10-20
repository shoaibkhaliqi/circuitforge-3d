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

	# The ADS1115 is an addressed register file *and* a set of solved-voltage probes: its
	# A0..A3 pins resolve to node voltages (the I2C twin of the MCP3008's channels), while
	# the MUX/PGA settings that scale them are the firmware's to choose.
	var app6 = AppService.new()
	app6.session.add_component("ground", ["TM1"])
	app6.session.add_component("ads1115",
		["TP1", "TM1", "d2", "d3", "d4", "e5", "a6", "a7", "a8", "a9"], {}, "N1")
	var built6: Dictionary = app6.session.build_circuit()
	var ads_nets: Array = (built6.pin_nets as Dictionary).get("N1", [])
	t.check(ads_nets.size() == 10, "ADS1115 contributes 10 nets", str(ads_nets))
	var ads_volts := {}
	if ads_nets.size() == 10:
		ads_volts[String(ads_nets[6])] = 2.5
		ads_volts[String(ads_nets[9])] = 3.3
	var specs7: Array = app6._firmware_devices(ads_volts, built6.pin_nets, {})
	t.check(specs7.size() == 1, "ADS1115 produces one device spec", str(specs7))
	if specs7.size() == 1:
		var sn: Dictionary = specs7[0]
		t.check(String(sn.get("kind", "")) == "ads1115", "spec kind is ads1115")
		t.check(int(sn.get("address", -1)) == 72, "default I2C address is 0x48", str(sn))
		var ads_ain: Array = sn.get("ain", [])
		t.check(ads_ain.size() == 4, "ADS1115 spec carries four channels", str(ads_ain))
		if ads_ain.size() == 4:
			t.check(absf(float(ads_ain[0]) - 2.5) < 1e-6, "A0 probes its solved net", str(ads_ain))
			t.check(absf(float(ads_ain[3]) - 3.3) < 1e-6, "A3 probes its solved net", str(ads_ain))
			t.check(absf(float(ads_ain[1])) < 1e-9, "an unwired channel reads 0 V", str(ads_ain))

	# The DS18B20 is served over a real 1-Wire bus, so it needs neither an address nor a CS:
	# only its DQ pin, resolved from `pin_map` (the same net lookup the DHT's DATA uses).
	var app7 = AppService.new()
	app7.session.add_component("ground", ["TM1"])
	app7.session.add_component("mcu_pin", ["c2", "TM9"], {}, "P2")     # DQ
	app7.session.add_component("ds18b20", ["TM3", "a2", "TP2"], {"temp_c": 23.1}, "S1")
	var built7: Dictionary = app7.session.build_circuit()
	var specs8: Array = app7._firmware_devices({}, built7.pin_nets, {"2": "P2"})
	t.check(specs8.size() == 1, "DS18B20 produces one device spec", str(specs8))
	if specs8.size() == 1:
		var sd: Dictionary = specs8[0]
		t.check(String(sd.get("kind", "")) == "ds18b20", "spec kind is ds18b20")
		t.check(int(sd.get("pin", -1)) == 2, "DQ resolved from pin_map", str(sd))
		t.check(absf(float(sd.get("temp_c", 0.0)) - 23.1) < 1e-6, "temp_c comes from params", str(sd))

	# A DQ that no firmware pin drives is skipped, not guessed at.
	var app8 = AppService.new()
	app8.session.add_component("ground", ["TM1"])
	app8.session.add_component("ds18b20", ["TM3", "a2", "TP2"], {"temp_c": 23.1}, "S2")
	var built8: Dictionary = app8.session.build_circuit()
	var specs9: Array = app8._firmware_devices({}, built8.pin_nets, {})
	t.check(specs9.is_empty(), "unmapped DQ => no spec (nothing to answer the bus)", str(specs9))

	# E-paper panel: DC and CS resolved from pin_map like the OLED/TFT.
	var app9 = AppService.new()
	app9.session.add_component("ground", ["TM1"])
	app9.session.add_component("mcu_pin", ["b2", "TM6"], {}, "P1")     # DC
	app9.session.add_component("mcu_pin", ["b3", "TM7"], {}, "P2")     # CS
	app9.session.add_component("epaper_213",
		["TM4", "TP4", "d5", "d6", "a3", "a2", "a4", "a5"], {}, "E1")
	var built9: Dictionary = app9.session.build_circuit()
	var specs10: Array = app9._firmware_devices({}, built9.pin_nets, {"9": "P1", "10": "P2"})
	t.check(specs10.size() == 1, "e-paper produces one device spec", str(specs10))
	if specs10.size() == 1:
		var se: Dictionary = specs10[0]
		t.check(String(se.get("kind", "")) == "epaper_spi", "spec kind is epaper_spi")
		t.check(int(se.get("dc", -1)) == 9, "DC pin resolved from pin_map", str(se))
		t.check(int(se.get("cs", -1)) == 10, "CS pin resolved from pin_map", str(se))

	# MAX7219 LED matrix: CS resolved from pin_map (no DC line).
	var app10 = AppService.new()
	app10.session.add_component("ground", ["TM1"])
	app10.session.add_component("mcu_pin", ["b2", "TM6"], {}, "P1")     # CS
	app10.session.add_component("max7219_matrix",
		["TM4", "TP4", "d5", "a2", "d6"], {}, "M1")
	var built10: Dictionary = app10.session.build_circuit()
	var specs11: Array = app10._firmware_devices({}, built10.pin_nets, {"9": "P1"})
	t.check(specs11.size() == 1, "MAX7219 produces one device spec", str(specs11))
	if specs11.size() == 1:
		var sm: Dictionary = specs11[0]
		t.check(String(sm.get("kind", "")) == "max7219_spi", "spec kind is max7219_spi")
		t.check(int(sm.get("cs", -1)) == 9, "CS pin resolved from pin_map", str(sm))

	# MAX6675 thermocouple: CS resolved from pin_map (no DC line, answers on MISO).
	var app11 = AppService.new()
	app11.session.add_component("ground", ["TM1"])
	app11.session.add_component("mcu_pin", ["b2", "TM6"], {}, "P1")     # CS
	app11.session.add_component("max6675_thermocouple",
		["TM4", "TP4", "d5", "a2", "d6"], {"temperature": 100.0}, "K1")
	var built11: Dictionary = app11.session.build_circuit()
	var specs12: Array = app11._firmware_devices({}, built11.pin_nets, {"9": "P1"})
	t.check(specs12.size() == 1, "MAX6675 produces one device spec", str(specs12))
	if specs12.size() == 1:
		var sk: Dictionary = specs12[0]
		t.check(String(sk.get("kind", "")) == "max6675_spi", "spec kind is max6675_spi")
		t.check(int(sk.get("cs", -1)) == 9, "CS pin resolved from pin_map", str(sk))
		t.check(absf(float(sk.get("temperature", 0.0)) - 100.0) < 1e-6, "temperature comes from params", str(sk))

	# ToF sensor: I2C register file, no pin_map needed.
	var app12 = AppService.new()
	app12.session.add_component("ground", ["TM1"])
	app12.session.add_component("tof_vl53l0x",
		["TP1", "TM1", "d2", "d3"], {"distance_mm": 500.0}, "T1")
	var built12: Dictionary = app12.session.build_circuit()
	var specs13: Array = app12._firmware_devices({}, built12.pin_nets, {})
	t.check(specs13.size() == 1, "ToF produces one device spec", str(specs13))
	if specs13.size() == 1:
		var tof_spec2: Dictionary = specs13[0]
		t.check(String(tof_spec2.get("kind", "")) == "tof_vl53l0x", "spec kind is tof_vl53l0x")
		t.check(int(tof_spec2.get("address", -1)) == 41, "default I2C address is 0x29", str(tof_spec2))
		t.check(absf(float(tof_spec2.get("distance_mm", 0.0)) - 500.0) < 1e-6, "distance comes from params", str(tof_spec2))

	# CCS811: I2C register file, no pin_map needed.
	var app13 = AppService.new()
	app13.session.add_component("ground", ["TM1"])
	app13.session.add_component("ccs811",
		["TP1", "TM1", "d2", "d3", "d4"], {"eco2": 1000.0, "tvoc": 50.0}, "C1")
	var built13: Dictionary = app13.session.build_circuit()
	var specs14: Array = app13._firmware_devices({}, built13.pin_nets, {})
	t.check(specs14.size() == 1, "CCS811 produces one device spec", str(specs14))
	if specs14.size() == 1:
		var cc: Dictionary = specs14[0]
		t.check(String(cc.get("kind", "")) == "ccs811", "spec kind is ccs811")
		t.check(int(cc.get("address", -1)) == 90, "default I2C address is 0x5A", str(cc))
		t.check(absf(float(cc.get("eco2", 0.0)) - 1000.0) < 1e-6, "eco2 comes from params", str(cc))
		t.check(absf(float(cc.get("tvoc", 0.0)) - 50.0) < 1e-6, "tvoc comes from params", str(cc))

	# SCD40: I2C command-driven device, no pin_map needed.
	var app14 = AppService.new()
	app14.session.add_component("ground", ["TM1"])
	app14.session.add_component("scd40",
		["TP1", "TM1", "d2", "d3"], {"co2": 800.0, "temp_c": 22.0, "humidity": 40.0}, "S1")
	var built14: Dictionary = app14.session.build_circuit()
	var specs15: Array = app14._firmware_devices({}, built14.pin_nets, {})
	t.check(specs15.size() == 1, "SCD40 produces one device spec", str(specs15))
	if specs15.size() == 1:
		var scd: Dictionary = specs15[0]
		t.check(String(scd.get("kind", "")) == "scd40", "spec kind is scd40")
		t.check(int(scd.get("address", -1)) == 98, "default I2C address is 0x62", str(scd))
		t.check(absf(float(scd.get("co2", 0.0)) - 800.0) < 1e-6, "co2 comes from params", str(scd))

	# HX711: two pins (DT, SCK) resolved from pin_map.
	var app15 = AppService.new()
	app15.session.add_component("ground", ["TM1"])
	app15.session.add_component("mcu_pin", ["b2", "TM6"], {}, "P1")     # DT
	app15.session.add_component("mcu_pin", ["b3", "TM7"], {}, "P2")     # SCK
	app15.session.add_component("hx711",
		["TM4", "a2", "a3", "TP4", "d5", "d6", "d7", "d8"], {"value": 123456}, "H1")
	var built15: Dictionary = app15.session.build_circuit()
	var specs16: Array = app15._firmware_devices({}, built15.pin_nets, {"9": "P1", "10": "P2"})
	t.check(specs16.size() == 1, "HX711 produces one device spec", str(specs16))
	if specs16.size() == 1:
		var hx: Dictionary = specs16[0]
		t.check(String(hx.get("kind", "")) == "hx711", "spec kind is hx711")
		t.check(int(hx.get("dout", -1)) == 9, "DT pin resolved from pin_map", str(hx))
		t.check(int(hx.get("sck", -1)) == 10, "SCK pin resolved from pin_map", str(hx))
		t.check(int(hx.get("value", 0)) == 123456, "value comes from params", str(hx))

	# BME280/BMP280: I2C register files, no pin_map needed.
	var app16 = AppService.new()
	app16.session.add_component("ground", ["TM1"])
	app16.session.add_component("bme280",
		["TP1", "TM1", "d2", "d3"], {"temp_c": 25.0, "humidity": 50.0, "pressure": 1000.0}, "B1")
	var built16: Dictionary = app16.session.build_circuit()
	var specs17: Array = app16._firmware_devices({}, built16.pin_nets, {})
	t.check(specs17.size() == 1, "BME280 produces one device spec", str(specs17))
	if specs17.size() == 1:
		var bm: Dictionary = specs17[0]
		t.check(String(bm.get("kind", "")) == "bme280", "spec kind is bme280")
		t.check(int(bm.get("address", -1)) == 118, "default I2C address is 0x76", str(bm))
		t.check(absf(float(bm.get("temp_c", 0.0)) - 25.0) < 1e-6, "temp comes from params", str(bm))

	# WS2812B: DIN resolved from pin_map like HX711's two pins.
	var app17 = AppService.new()
	app17.session.add_component("ground", ["TM1"])
	app17.session.add_component("mcu_pin", ["b2", "TM6"], {}, "P1")      # DIN driver
	app17.session.add_component("ws2812b",
		["TP4", "TM2", "TM3", "d2"], {"count": 4}, "ST1")
	var built17: Dictionary = app17.session.build_circuit()
	var specs18: Array = app17._firmware_devices({}, built17.pin_nets, {"8": "P1"})
	t.check(specs18.size() == 1, "WS2812B produces one device spec", str(specs18))
	if specs18.size() == 1:
		var ws_dev: Dictionary = specs18[0]
		t.check(String(ws_dev.get("kind", "")) == "ws2812b", "spec kind is ws2812b")
		t.check(int(ws_dev.get("pin", -1)) == 8, "DIN pin resolved from pin_map", str(ws_dev))
		t.check(int(ws_dev.get("count", -1)) == 4, "count comes from params", str(ws_dev))

	_run_ws2812_tests(t)
	_run_pms5003_tests(t)

	t.done()


## WS2812B decode: emulate the transitions a strip send produces - one high
## pulse per bit (0.8 us encodes 1, 0.3 us encodes 0), ~1.1 us idle low, and a
## >50 us reset between frames. Timestamps carry the cycle-precise t_us.
func _ws_trs(fill: Array, t_start := 0.0) -> Dictionary:
	var out := []
	var t := t_start
	for bit in fill:
		var high := 0.8 if bit == 1 else 0.3
		out.append({"digital_pin": 8, "level": 1, "t_us": t, "t_ms": t / 1000.0})
		t += high
		out.append({"digital_pin": 8, "level": 0, "t_us": t, "t_ms": t / 1000.0})
		t += 1.1
	return {"trs": out, "end_us": t}


func _ws_bytes(r: int, g: int, b: int) -> Array:
	var bits := []
	for byte in [g, r, b]:      # wire order is GRB, MSB first
		for i in range(7, -1, -1):
			bits.append((byte >> i) & 1)
	return bits


func _run_ws2812_tests(t) -> void:
	t.section("Firmware - WS2812B decode")

	# 3 pixels: red, green, blue.
	var r1: Dictionary = _ws_trs(_ws_bytes(255, 0, 0))
	var r2: Dictionary = _ws_trs(_ws_bytes(0, 255, 0), r1["end_us"])
	var r3: Dictionary = _ws_trs(_ws_bytes(0, 0, 255), r2["end_us"])
	var frame_one: Array = r1["trs"]
	frame_one.append_array(r2["trs"])
	frame_one.append_array(r3["trs"])
	var leds := FirmwareBackend.ws2812_leds(frame_one, 8)
	t.check(leds.size() == 3, "three pixels decoded", str(leds))
	if leds.size() == 3:
		t.check(int(leds[0]["r"]) == 255 and int(leds[0]["g"]) == 0 and int(leds[0]["b"]) == 0,
			"pixel 1 is red (GRB byte order)", str(leds[0]))
		t.check(int(leds[1]["g"]) == 255 and int(leds[1]["r"]) == 0 and int(leds[1]["b"]) == 0,
			"pixel 2 is green", str(leds[1]))
		t.check(int(leds[2]["b"]) == 255 and int(leds[2]["r"]) == 0 and int(leds[2]["g"]) == 0,
			"pixel 3 is blue", str(leds[2]))

	# A second frame after a >50 us reset replaces the strip's state - but only
	# once IT is latched too: until its reset arrives the strip keeps showing
	# the previous frame, exactly like hardware. Frame 2 is three white pixels.
	var white: Array = _ws_bytes(255, 255, 255)
	var t_gap: float = r3["end_us"] + 100.0                    # gap latches frame 1
	var w1: Dictionary = _ws_trs(white, t_gap)
	var w2: Dictionary = _ws_trs(white, w1["end_us"])
	var w3: Dictionary = _ws_trs(white, w2["end_us"])
	var r5: Dictionary = _ws_trs(white, w3["end_us"] + 100.0)  # gap latches frame 2
	var two_trs: Array = frame_one.duplicate(true)
	two_trs.append_array(w1["trs"])   # the first rise is the reset gap's far edge
	two_trs.append_array(w2["trs"])
	two_trs.append_array(w3["trs"])
	two_trs.append_array(r5["trs"])
	var leds_two := FirmwareBackend.ws2812_leds(two_trs, 8)
	t.check(leds_two.size() == 3, "second frame decodes three pixels", str(leds_two))
	if leds_two.size() == 3:
		t.check(int(leds_two[0]["r"]) == 255 and int(leds_two[0]["g"]) == 255,
			"after a latch the LAST frame is the strip's state", str(leds_two))

	# An unterminated partial frame decodes nothing (a real strip shows nothing).
	var partial: Dictionary = _ws_trs(_ws_bytes(255, 0, 0).slice(0, 10))
	t.check(FirmwareBackend.ws2812_leds(partial["trs"], 8).is_empty(),
		"incomplete frame has no latched pixels")

	# The t_ms-only fallback (older capture files, 1 us grid) still decodes.
	var ms_only := []
	for tr in frame_one:
		ms_only.append({"t_ms": float(tr["t_us"]) / 1000.0, "digital_pin": 8, "level": tr["level"]})
	var ms_leds := FirmwareBackend.ws2812_leds(ms_only, 8)
	t.check(ms_leds.size() == 3 and int(ms_leds[2]["b"]) == 255,
		"decode works from t_ms stamps alone", str(ms_leds))


func _pms_frame(pm10: int, pm25: int, pm100: int) -> PackedByteArray:
	# 32-byte PMS5003 passive frame: 0x42 0x4D, length 0x001C, 26 payload bytes,
	# 2-byte checksum (sum of the first 30 bytes, little details module-defined).
	var b := PackedByteArray()
	b.append(0x42)
	b.append(0x4D)
	b.append(0x00)
	b.append(0x1C)
	b.resize(30)   # zero payload; exact fields set below
	b[4] = (pm10 >> 8) & 0xff
	b[5] = pm10 & 0xff
	b[6] = (pm25 >> 8) & 0xff
	b[7] = pm25 & 0xff
	b[8] = (pm100 >> 8) & 0xff
	b[9] = pm100 & 0xff
	var sum := 0
	for i in 30:
		sum += b[i]
	b.append((sum >> 8) & 0xff)
	b.append(sum & 0xff)
	return b


func _run_pms5003_tests(t) -> void:
	t.section("Firmware - PMS5003 frame decode")
	var good: PackedByteArray = _pms_frame(12, 34, 56)
	var frames: Array = FirmwareBackend.pms5003_decode(good)
	t.check(frames.size() == 1, "one valid frame decoded", str(frames.size()))
	if frames.size() == 1:
		var f: Dictionary = frames[0]
		t.check(bool(f["checksum_ok"]), "checksum validates", str(f))
		t.check(int(f["pm1_0"]) == 12, "PM1.0 field decoded", str(f))
		t.check(int(f["pm2_5"]) == 34, "PM2.5 field decoded", str(f))
		t.check(int(f["pm10"]) == 56, "PM10 field decoded", str(f))

	# Corrupt one payload byte: the checksum must fail.
	var bad: PackedByteArray = good.duplicate()
	bad[6] = 99
	var badframes: Array = FirmwareBackend.pms5003_decode(bad)
	t.check(badframes.size() == 1, "corrupted frame still yields one entry", str(badframes))
	if badframes.size() == 1:
		t.check(not bool(badframes[0]["checksum_ok"]), "corrupted frame fails its checksum")
		t.check(not bool(badframes[0]["valid"]), "corrupted frame is not valid")

	# Hidden frames inside noise: the parser re-syncs on the 0x42 0x4D header.
	var noisy := PackedByteArray()
	for i in 7:
		noisy.append((i * 37) & 0xff)
	noisy.append_array(good)
	noisy.append(0xff)
	noisy.append_array(good)
	var resync: Array = FirmwareBackend.pms5003_decode(noisy)
	t.check(resync.size() == 2, "frames re-sync inside a noisy stream", str(resync.size()))
	t.check(bool(resync[0]["checksum_ok"]) or bool(resync[1]["checksum_ok"]),
		"recovers a valid frame after stray bytes")

	# Incomplete tail: ignored, no half frame.
	var short := PackedByteArray()
	for i in 20:
		short.append(0x42 if i < 2 else i)
	t.check(FirmwareBackend.pms5003_decode(short).is_empty(), "truncated frame is skipped")

	# Hex-string input (serial bytes as text).
	var hf: Array = FirmwareBackend.pms5003_decode(good.hex_encode())
	t.check(hf.size() == 1 and bool(hf[0]["checksum_ok"]), "hex string input decodes", str(hf.size()))
