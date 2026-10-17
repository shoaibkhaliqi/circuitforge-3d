extends RefCounted
## Firmware backend (M7 Stage B) — pure contract tests.
##
## These never require Node: they cover pin-key normalisation, pin sampling,
## labels, and that `capabilities()` is honest (reports a reason when unavailable
## rather than pretending firmware works). The real compile+run path lives in
## firmware/harness/verify.mjs and is run separately, so the Godot suite stays
## runnable with only Godot installed.

const FirmwareBackend = preload("res://scripts/simulation/firmware_backend.gd")


func _tr(pin: int, t: float, level: int) -> Dictionary:
	return {"t_ms": t, "digital_pin": pin, "level": level}


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

	t.done()
