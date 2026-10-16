extends RefCounted
## Board pin metadata tests.
##
## Every board must expose an internally consistent, documented pin map. These
## checks are structural (no fabricated values): they verify the data present in
## data/components/boards.json is coherent, not that any board is simulated.

const BoardPins = preload("res://scripts/components/board_pins.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")


func run(t) -> void:
	t.section("Boards - discovery")
	var boards := BoardPins.all_boards()
	t.check(boards.size() >= 15, "catalog has at least 15 boards", str(boards.size()))
	for id in ["arduino_uno_r3", "esp32_devkit_v1", "rp2040_pico", "stm32_bluepill_f103"]:
		t.check(BoardPins.is_board(id), "%s is recognised as a board" % id)
	t.check(not BoardPins.is_board("resistor"), "a resistor is not a board")
	t.check(not BoardPins.is_board(""), "an empty type is not a board")

	t.section("Boards - every board pin map is internally consistent")
	for id in boards:
		var issues: Array = BoardPins.issues(id)
		t.check(issues.is_empty(), "board %s has a valid pin map" % id, str(issues))

	t.section("Boards - groups and counts add up")
	for id in boards:
		var c: Dictionary = BoardPins.counts(id)
		var g: Dictionary = BoardPins.groups(id)
		var sum := int(g.digital.size()) + int(g.analog.size()) + int(g.power.size()) \
				+ int(g.ground.size()) + int(g.other.size())
		t.check(sum == int(c.total), "board %s groups sum to total" % id,
			"%d vs %d" % [sum, c.total])
		t.check(int(c.total) == BoardPins.pinout(id).size(), "board %s count matches pinout" % id)

	t.section("Boards - documented Uno R3 pin map")
	var c := BoardPins.counts("arduino_uno_r3")
	t.check(int(c.total) == 29, "Uno R3 exposes 29 header pins", str(c.total))
	t.check(int(c.digital) >= 14, "Uno R3 has at least 14 digital pins", str(c.digital))
	t.check(int(c.analog) == 6, "Uno R3 has 6 analog pins", str(c.analog))
	t.check(int(c.ground) >= 3, "Uno R3 has several ground pins", str(c.ground))
	t.check(BoardPins.named("arduino_uno_r3", "GND").size() == 3, "Uno R3 has three GND pins")
	t.check(String(BoardPins.first("arduino_uno_r3", "5V").get("type", "")) == "power",
		"Uno R3 5V is a power pin")
	t.check(BoardPins.first("arduino_uno_r3", "D13").is_empty() == false, "Uno R3 has D13")
	t.check(String(BoardPins.first("arduino_uno_r3", "A0").get("type", "")) == "analog",
		"Uno R3 A0 is analog")

	t.section("Boards - provenance references")
	for id in boards:
		var s := BoardPins.summary(id)
		var refs: Array = s.get("references", [])
		t.check(refs.size() >= 1, "board %s cites a source" % id, str(refs))

	t.section("Boards - summary payload")
	var s := BoardPins.summary("arduino_uno_r3")
	t.check(String(s.get("type", "")) == "arduino_uno_r3", "summary carries the type")
	t.check(int(s.get("pin_count", 0)) == 29, "summary pin count matches")
	t.check((s.get("pins", []) as Array).size() == 29, "summary lists every pin")
	t.check(s.has("references"), "summary exposes provenance references")
	t.check((s.get("issues", []) as Array).is_empty(), "summary reports no issues")
	t.check(s.get("counts") is Dictionary and s.get("groups") is Dictionary,
		"summary carries counts and groups")

	t.section("Boards - unknown type is handled")
	t.check(BoardPins.pinout("no_such_board").is_empty(), "unknown board has no pins")
	t.check(BoardPins.summary("no_such_board").is_empty(), "unknown board summary is empty")
	t.check(BoardPins.issues("no_such_board") == ["not a board"], "unknown type reports not a board")

	t.done()
