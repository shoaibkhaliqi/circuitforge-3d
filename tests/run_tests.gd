extends SceneTree
## CircuitForge 3D - headless test entry point.
##
## Run with:
##   godot --headless --path <project> --script res://tests/run_tests.gd
##
## Exit code 0 = all tests passed, 1 = at least one failure.

const TEST_FILES := [
	"res://tests/unit/test_linalg.gd",
	"res://tests/solver/test_dc.gd",
	"res://tests/solver/test_transient.gd",
	"res://tests/solver/test_nonlinear.gd",
	"res://tests/solver/test_invalid.gd",
	"res://tests/connectivity/test_breadboard.gd",
	"res://tests/persistence/test_persistence.gd",
	"res://tests/unit/test_units.gd",
]


func _initialize() -> void:
	var Runner = load("res://tests/support/test_runner.gd")
	var t = Runner.new()

	print("CircuitForge 3D test run - Godot %s" % Engine.get_version_info().string)

	for path in TEST_FILES:
		if not ResourceLoader.exists(path):
			print("  SKIP (not implemented yet): %s" % path)
			continue
		var script = load(path)
		if script == null:
			t.section("Test discovery")
			t.check(false, "could not load test file: %s" % path)
			continue
		var inst = script.new()
		inst.run(t)

	print(t.report())
	quit(0 if t.all_passed() else 1)
