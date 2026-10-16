extends RefCounted
## Component catalog tests - loading, validation, search, facets, status accuracy.

const Catalog = preload("res://scripts/components/component_catalog.gd")
const Schema = preload("res://scripts/components/component_schema.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")

const CORE_SOLVABLE := [
	"resistor", "capacitor", "inductor", "potentiometer", "vsource", "isource",
	"ground", "switch", "led", "diode", "zener",
	"and", "or", "not", "nand", "nor", "xor", "buffer",
]


func run(t) -> void:
	Catalog.reset()
	Catalog.load_all(true)

	_test_load(t)
	_test_validation(t)
	_test_core_types(t)
	_test_search(t)
	_test_facets(t)
	_test_facade(t)
	t.done()


func _test_load(t) -> void:
	t.section("Catalog - loading")
	var errs := Catalog.errors()
	t.check(errs.is_empty(), "catalog loads without errors", ", ".join(errs))
	t.check(Catalog.count() > 200, "catalog has a substantial number of components (%d)" % Catalog.count())
	t.check(Catalog.has("resistor"), "resistor present")
	t.check(not Catalog.has("no_such_part_xyz"), "unknown id absent")


func _test_validation(t) -> void:
	t.section("Catalog - every definition validates")
	var defs := Catalog.defs()
	var bad := []
	for id in defs.keys():
		var e := Schema.validate(defs[id])
		if not e.is_empty():
			bad.append("%s: %s" % [id, ", ".join(e)])
	t.check(bad.is_empty(), "all %d definitions valid" % defs.size(), ", ".join(bad))
	var all_have_pins := true
	for id in defs.keys():
		if (defs[id]["pins"] as Array).is_empty():
			all_have_pins = false
	t.check(all_have_pins, "every definition has at least one pin")


func _test_core_types(t) -> void:
	t.section("Catalog - core solvable types are marked 'full'")
	for type in CORE_SOLVABLE:
		var d = Catalog.get_def(type)
		if d.is_empty():
			t.check(false, "%s present" % type)
			continue
		var st := String(d["simulation_status"])
		t.check(st == "full", "%s simulation_status is full (got '%s')" % [type, st])


func _test_search(t) -> void:
	t.section("Catalog - search")

	var r := Catalog.search("resistor")
	t.check(bool(r["items"].has("resistor")), "search 'resistor' finds resistor")

	var by_part := Catalog.search("atmega328")
	t.check(by_part["count"] >= 1, "search by chip name finds a board/part")

	var filtered := Catalog.search("", {"category": "Passive"})
	t.check(bool(filtered["items"].has("resistor")), "category filter keeps resistor")
	var all_passive := true
	for id in filtered["items"]:
		if String(Catalog.get_def(id)["category"]) != "Passive":
			all_passive = false
	t.check(all_passive, "category filter excludes other categories")

	var sim := Catalog.search("", {"simulatable_only": true})
	t.check(not bool(sim["items"].has("arduino_uno_r3")), "simulatable_only excludes planned board")
	t.check(bool(sim["items"].has("resistor")), "simulatable_only keeps resistor")

	var limited := Catalog.search("", {"limit": 5})
	t.check((limited["items"] as Array).size() == 5, "limit caps the page size")
	t.check(int(limited["count"]) > 5, "count reports the full match total, not the page")

	var none := Catalog.search("zzzznotathing")
	t.check(int(none["count"]) == 0, "nonsense query returns nothing")


func _test_facets(t) -> void:
	t.section("Catalog - facets")
	var f := Catalog.facets()
	t.check(bool((f["categories"] as Array).has("Passive")), "facets include Passive")
	t.check(bool((f["categories"] as Array).has("Board")), "facets include Board")
	t.check(bool((f["statuses"] as Array).has("full")), "facets include status 'full'")
	t.check(bool((f["protocols"] as Array).has("I2C")), "facets include protocol I2C")


func _test_facade(t) -> void:
	t.section("Catalog - ComponentDB facade")
	t.check(ComponentDB.exists("resistor"), "exists(resistor)")
	t.check(ComponentDB.status_of("resistor") == "full", "status_of(resistor) = full")
	t.check(ComponentDB.is_simulatable("resistor"), "resistor is simulatable")
	t.check(not ComponentDB.is_simulatable("arduino_uno_r3"), "planned board is not simulatable")
	t.check(ComponentDB.status_label("arduino_uno_r3") == "Not yet implemented", "status label for planned board")
	t.check(ComponentDB.categories().size() > 5, "facade reports multiple categories")
	t.check(ComponentDB.pin_count("resistor") == 2, "pin_count(resistor) = 2")
	t.check(ComponentDB.pin_count("arduino_mega2560") > 60, "pin_count(mega) is large")
