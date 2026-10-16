extends RefCounted
## Component schema (v2) tests - normalisation, validation, status vocabulary.

const Schema = preload("res://scripts/components/component_schema.gd")


func run(t) -> void:
	_test_normalize(t)
	_test_validate(t)
	_test_status(t)
	_test_catalog_validation(t)
	t.done()


func _test_normalize(t) -> void:
	t.section("Schema - normalisation")

	var d := Schema.normalize({"id": "x", "name": "X", "category": "Test", "pins": ["a", "b"]})
	t.check(d.has("schema_version"), "schema_version present")
	t.check(int(d["schema_version"]) == Schema.SCHEMA_VERSION, "schema_version is current")
	t.check(String(d["simulation_status"]) == "full", "default status is 'full'")
	t.check((d["pins"] as Array).size() == 2, "two pins kept")
	t.check(String(d["pins"][0]["id"]) == "a", "string pin becomes object with id")
	t.check(String(d["pins"][0]["type"]) == "passive", "string pin defaults to passive")
	t.check(int(d["pins"][1]["number"]) == 2, "pin numbers are positional")
	t.check((d["keywords"] as Array).is_empty(), "keywords defaults to empty array")
	t.check(d.has("model") and d.has("params") and d.has("references"), "all optional keys exist")

	var d2 := Schema.normalize({"id": "y", "name": "Y", "category": "Test", "pins": [{"name": "A", "type": "power"}]})
	t.check(String(d2["pins"][0]["id"]) == "1", "dict pin without id gets positional id")
	t.check(String(d2["pins"][0]["name"]) == "A", "dict pin keeps name")
	t.check(String(d2["pins"][0]["type"]) == "power", "dict pin keeps type")

	var d3 := Schema.normalize({"id": "z", "name": "Z", "category": "Test", "pins": ["1"],
		"params": {"r": {"default": 1000.0, "unit": "Ohm", "label": "Resistance"}}})
	var rp: Dictionary = d3["params"]["r"]
	t.check(rp.has("default") and rp.has("unit") and rp.has("label"), "param spec normalised")


func _test_validate(t) -> void:
	t.section("Schema - validation")

	var ok := Schema.normalize({"id": "a", "name": "A", "category": "Test", "pins": ["1", "2"]})
	t.check((Schema.validate(ok) as Array).is_empty(), "valid definition has no errors", str(Schema.validate(ok)))

	t.check(not (Schema.validate(Schema.normalize({"name": "A", "category": "Test", "pins": ["1"]})) as Array).is_empty(), "missing id rejected")
	# name/category have defaults during normalisation, so validate the raw shape:
	t.check(not (Schema.validate({"id": "a", "category": "Test", "pins": [{"id": "1"}]}) as Array).is_empty(), "missing name rejected")
	t.check(not (Schema.validate({"id": "a", "name": "A", "pins": [{"id": "1"}]}) as Array).is_empty(), "missing category rejected")
	t.check(not (Schema.validate(Schema.normalize({"id": "a", "name": "A", "category": "Test", "pins": []})) as Array).is_empty(), "empty pins rejected")

	var dup := Schema.normalize({"id": "a", "name": "A", "category": "Test",
		"pins": [{"id": "p", "type": "passive"}, {"id": "p", "type": "passive"}]})
	t.check(not (Schema.validate(dup) as Array).is_empty(), "duplicate pin id rejected")

	var badtype := Schema.normalize({"id": "a", "name": "A", "category": "Test",
		"pins": [{"id": "p", "type": "banana"}]})
	t.check(not (Schema.validate(badtype) as Array).is_empty(), "unknown pin type rejected")

	var badstatus := Schema.normalize({"id": "a", "name": "A", "category": "Test",
		"pins": ["1"], "simulation_status": "sometimes"})
	t.check(not (Schema.validate(badstatus) as Array).is_empty(), "invalid simulation_status rejected")


func _test_status(t) -> void:
	t.section("Schema - status vocabulary")
	t.check(Schema.is_simulatable("full"), "full is simulatable")
	t.check(Schema.is_simulatable("partial"), "partial is simulatable")
	t.check(not Schema.is_simulatable("visual"), "visual is not simulatable")
	t.check(not Schema.is_simulatable("external"), "external is not simulatable")
	t.check(not Schema.is_simulatable("planned"), "planned is not simulatable")
	t.check(Schema.status_label("planned") == "Not yet implemented", "planned label")
	t.check(Schema.status_label("full") == "Fully simulated", "full label")


func _test_catalog_validation(t) -> void:
	t.section("Schema - catalog validation")
	var defs := {
		"a": Schema.normalize({"id": "a", "name": "A", "category": "T", "pins": ["1"]}),
		"b": Schema.normalize({"id": "WRONG", "name": "B", "category": "T", "pins": ["1"]}),
	}
	var errs := Schema.validate_catalog(defs)
	t.check(not errs.is_empty(), "catalog validation flags key/id mismatch")
