extends RefCounted
## Board pin metadata + integration tests.
##
## Every board must expose an internally consistent, documented pin map, a
## documented identity (MCU, logic level, USB, programming) and an honest
## capability split: the pinout is electrical (terminals in the netlist), the
## MCU is not a solver element, and firmware execution belongs to the optional
## external backend. These checks are structural - they verify the data present
## in data/components/boards.json is coherent, not that any board is simulated.

const BoardPins = preload("res://scripts/components/board_pins.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")
const FirmwareBackend = preload("res://scripts/simulation/firmware_backend.gd")
const Breadboard = preload("res://scripts/breadboard/breadboard.gd")
const NetlistBuilder = preload("res://scripts/connectivity/netlist_builder.gd")
const AppService = preload("res://scripts/api/app_service.gd")

const ROUNDTRIP_PATH := "user://cf3d_board_roundtrip.cf3d"


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
	t.check(String(s.get("simulation_status", "")) == "external",
		"summary carries the honest status")
	t.check(s.has("board_info"), "summary carries the documented identity")
	t.check(s.has("interfaces"), "summary carries the interface mappings")

	t.section("Boards - unknown type is handled")
	t.check(BoardPins.pinout("no_such_board").is_empty(), "unknown board has no pins")
	t.check(BoardPins.summary("no_such_board").is_empty(), "unknown board summary is empty")
	t.check(BoardPins.issues("no_such_board") == ["not a board"], "unknown type reports not a board")

	_run_documented_layouts(t)
	_run_identity(t)
	_run_backend_honesty(t)
	_run_electrical(t)

	t.done()


## Exact header sizes the manufacturer documents. These are the layouts this
## project deliberately corrected to match the real boards; a regression here
## means the catalog pin list no longer matches the physical board.
func _run_documented_layouts(t) -> void:
	t.section("Boards - documented header sizes")
	var exact := {
		"arduino_uno_r3": 29,       # 14 digital + 6 analog + 9 power/control
		"arduino_nano": 30,         # 2x15 classic Nano header (AREF + RST on both sides)
		"esp32_devkit_v1": 30,      # DOIT DevKit V1, 2x15, GND on both sides
		"rp2040_pico": 40,          # full Pico header incl. ADC_VREF
		"rp2350_pico2": 40,         # same layout as the Pico
		"raspberry_pi_4b": 40,      # 40-pin HAT header incl. ID EEPROM pins
		"raspberry_pi_zero_2w": 40,
		"raspberry_pi_5": 40,
	}
	for id in exact:
		t.check(BoardPins.counts(id)["total"] == exact[id],
			"%s exposes %d header pins" % [id, exact[id]], str(BoardPins.counts(id)["total"]))

	# The Pi SDA1/SCL1 entries were aliases of GPIO2/GPIO3 - real headers have
	# no such separate positions, so the pin list must not resurrect them.
	for id in ["raspberry_pi_4b", "raspberry_pi_zero_2w", "raspberry_pi_5"]:
		t.check(BoardPins.first(id, "SDA1").is_empty(), "%s has no separate SDA1 header pin" % id)
		t.check(BoardPins.named(id, "3V3").size() == 2, "%s has 3V3 on both header sides" % id)
		t.check(BoardPins.first(id, "ID_SD").is_empty() == false,
			"%s exposes the HAT ID EEPROM pins" % id)
		t.check(BoardPins.first(id, "GPIO2").is_empty() == false,
			"%s keeps GPIO2 (the I2C1 SDA alias lives on it)" % id)

	# The Pico's ADC_VREF (header pin 35) must exist on both Pico generations.
	for id in ["rp2040_pico", "rp2350_pico2"]:
		t.check(BoardPins.first(id, "ADC_VREF").is_empty() == false, "%s has ADC_VREF" % id)
		t.check(BoardPins.named(id, "GND").size() == 8, "%s has 8 ground pins" % id)

	# Voltage marks: pins whose NAME is a documented voltage carry it.
	for id in BoardPins.all_boards():
		for nm in ["5V", "3V3", "VBUS"]:
			var p := BoardPins.first(id, nm)
			if p.is_empty():
				continue
			t.check(p.has("voltage"), "%s %s carries its voltage" % [id, nm])
			if p.has("voltage"):
				var want := 5.0 if nm != "3V3" else 3.3
				t.check(absf(float(p["voltage"]) - want) < 1e-9,
					"%s %s is %g V" % [id, nm, want], str(p["voltage"]))


## Documented board identity: MCU part, core, logic level, USB, programming.
func _run_identity(t) -> void:
	t.section("Boards - documented identity")
	var with_info := 0
	for id in BoardPins.all_boards():
		var bi := BoardPins.board_info(id)
		if bi.is_empty():
			continue   # a board can be pinout-only; coherence is still checked
		with_info += 1
		for k in ["mcu", "core", "usb", "programming"]:
			t.check(bi.has(k) and String(bi[k]) != "",
				"%s documents its %s" % [id, k], str(bi))
		var lv := float(bi.get("logic_voltage", 0.0))
		t.check(lv == 5.0 or lv == 3.3, "%s logic level is 5 V or 3.3 V" % id, str(lv))
		if bi.has("cpu_mhz"):
			t.check(float(bi["cpu_mhz"]) > 0.0, "%s documents a clock" % id)
		var ifaces := BoardPins.interfaces(id)
		for bus in ifaces:
			t.check((ifaces[bus] as Array).size() >= 1,
				"%s %s mapping names pins" % [id, bus], str(ifaces[bus]))
	t.check(with_info >= 20, "the 20 development boards document their identity",
		str(with_info))

	t.section("Boards - documented interface mappings")
	t.check(BoardPins.interface_pins("arduino_uno_r3", "i2c") == ["A4", "A5"],
		"Uno R3 I2C lives on A4/A5", str(BoardPins.interface_pins("arduino_uno_r3", "i2c")))
	t.check(BoardPins.interface_pins("arduino_uno_r3", "spi") == ["D10", "D11", "D12", "D13"],
		"Uno R3 SPI uses D10..D13")
	t.check(BoardPins.interface_pins("arduino_mega2560", "i2c") == ["D20", "D21"],
		"Mega2560 I2C lives on D20/D21")
	t.check(BoardPins.interface_pins("rp2040_pico", "i2c") == ["GP4", "GP5"],
		"Pico default I2C0 is GP4/GP5")
	t.check(BoardPins.interface_pins("stm32_bluepill_f103", "uart") == ["PA9", "PA10"],
		"Bluepill USART1 is PA9/PA10")
	t.check(BoardPins.interface_pins("seeeduino_xiao", "i2c") == ["D4", "D5"],
		"XIAO I2C is D4/D5")
	# Every interface pin must exist in the pinout (issues() enforces it too;
	# this spot check keeps the mapping itself honest for one classic board).
	for pn in BoardPins.interface_pins("arduino_uno_r3", "pwm"):
		t.check(BoardPins.first("arduino_uno_r3", pn).is_empty() == false,
			"Uno PWM pin %s exists" % pn)


## The capability split must stay honest: every board is "external" (its MCU is
## not a solver element), the backend field says whether firmware can execute,
## and only ATmega328P-class boards claim an avr8js FQBN.
func _run_backend_honesty(t) -> void:
	t.section("Boards - capability honesty")
	for id in BoardPins.all_boards():
		var s := BoardPins.summary(id)
		t.check(String(s.get("simulation_status", "")) == "external",
			"%s is honest about being external (terminal part)" % id,
			str(s.get("simulation_status")))
		var backend := String(s.get("simulation_backend", ""))
		t.check(backend == "firmware" or backend == "none",
			"%s declares a known backend kind" % id, backend)
		var fqbn: String = FirmwareBackend.board_fqbn(id)
		if backend == "firmware":
			t.check(fqbn != "", "%s claims firmware: the backend has an FQBN for it" % id)
			t.check(fqbn in FirmwareBackend.BOARDS,
				"%s FQBN is one the harness actually runs" % id, fqbn)
		else:
			t.check(fqbn == "", "%s claims no firmware: no backend FQBN may exist" % id)
	var cap: Dictionary = FirmwareBackend.capabilities()
	t.check((cap.get("board_types", {}) as Dictionary).size() == 3,
		"capabilities expose exactly the firmware-capable boards", str(cap.get("board_types")))


## Per-board electrical integration: every board's pins are real terminals in
## the netlist (pin_nets), a wired part shares the net, no solver element and
## no warning is produced, and the placement survives a project save/load.
func _run_electrical(t) -> void:
	t.section("Boards - electrical terminals (every board)")
	var builder = NetlistBuilder.new()
	var bb = Breadboard.new(30)
	for id in BoardPins.all_boards():
		var n: int = BoardPins.pinout(id).size()
		var holes: Array = []
		for i in n:
			holes.append("")
		holes[0] = "a1"   # pin 0 rides the a1..e1 column strip
		var r = builder.build(bb, [
			{"id": "J1", "type": id, "holes": holes, "params": {}, "rotation": 0.0, "position": [0, 0, 0]},
			{"id": "R1", "type": "resistor", "holes": ["b1", "c2"], "params": {}, "rotation": 0.0, "position": [0, 0, 0]},
		], [])
		var nets: Array = (r.pin_nets as Dictionary).get("J1", [])
		t.check(nets.size() == n, "%s: all %d pins map into the netlist" % [id, n], str(nets.size()))
		t.check(nets.size() == n and String(nets[0]) == "a1",
			"%s: wired pin shares its column net" % id, str(nets))
		t.check((r.warnings as Array).is_empty(),
			"%s: terminal integration raises no warning" % id, str(r.warnings))
		var element := false
		for e in r.circuit.elements:
			if e.id == "J1":
				element = true
		t.check(not element, "%s: no solver element for the MCU itself" % id)

	t.section("Boards - save/load round trip")
	var app = AppService.new()
	var uno_holes: Array = []
	for i in 29:
		uno_holes.append("")
	uno_holes[0] = "a1"
	uno_holes[8] = "e4"
	app.session.add_component("arduino_uno_r3", uno_holes, {}, "U1")
	app.session.add_component("led", ["c2", "TM1"], {}, "L1")
	var saved_ok: bool = app.session.save_project(ROUNDTRIP_PATH)
	t.check(saved_ok, "a project with a placed board saves")
	var app2 = AppService.new()
	var loaded: bool = app2.session.load_project(ROUNDTRIP_PATH)
	t.check(loaded, "a project with a placed board loads back")
	var c2 = app2.session.find_component("U1")
	t.check(c2 != null, "the board survives save/load")
	if c2 != null:
		var h2: Array = c2.holes
		t.check(h2.size() == 29 and String(h2[0]) == "a1" and String(h2[8]) == "e4",
			"board pin holes round-trip", str(h2))
	var built2: Dictionary = app2.session.build_circuit()
	var u2_nets: Array = (built2.pin_nets as Dictionary).get("U1", [])
	t.check(u2_nets.size() == 29 and String(u2_nets[0]) == "a1",
		"the reloaded board maps into the netlist identically", str(u2_nets))

	t.section("Boards - API surface (pinout + capabilities)")
	var api = AppService.new()
	var pin_r: Dictionary = api.get_board_pinout("arduino_uno_r3")
	t.check(bool(pin_r.get("success", false)), "the API exposes a board pinout")
	t.check(String(pin_r.get("firmware_fqbn", "x")) == "arduino:avr:uno",
		"the API joins the backend FQBN", str(pin_r.get("firmware_fqbn")))
	t.check((pin_r.get("board_info", {}) as Dictionary).get("mcu") == "ATmega328P",
		"the API exposes the documented identity")
	var esp_r: Dictionary = api.get_board_pinout("esp32_devkit_v1")
	t.check(bool(esp_r.get("success", false)) and String(esp_r.get("firmware_fqbn", "x")) == "",
		"a non-AVR board reports an empty (honest) FQBN", str(esp_r.get("firmware_fqbn")))
	var not_board: Dictionary = api.get_board_pinout("resistor")
	t.check((not not_board.get("success", true))
		and String((not_board.get("error", {}) as Dictionary).get("code", "")) == "NOT_A_BOARD",
		"a non-board type is rejected with NOT_A_BOARD")
	var caps_r: Dictionary = api.get_firmware_capabilities()
	t.check((caps_r.get("board_types", {}) as Dictionary).size() == 3,
		"the capabilities payload lists the firmware-capable boards", str(caps_r.get("board_types")))
