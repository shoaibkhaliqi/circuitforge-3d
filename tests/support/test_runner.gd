extends RefCounted
## CircuitForge 3D - minimal headless test runner.
##
## Not a general framework: a tiny collector used by tests/run_tests.gd so the
## numerical suite can run without a display.

var results: Array = []
var current_section := ""
var tree = null
var _done_marker := false


func done() -> void:
	_done_marker = true


func begin_file() -> void:
	_done_marker = false


func finish_file(path: String) -> void:
	if not _done_marker:
		check(false, "test file did not run to completion (runtime error?): %s" % path)


func section(name: String) -> void:
	current_section = name


func check(cond: bool, name: String, detail: String = "") -> bool:
	results.append({
		"section": current_section,
		"name": name,
		"passed": cond,
		"detail": detail,
	})
	return cond


func near(actual: float, expected: float, name: String, rel: float = 1e-4, abs_tol: float = 1e-9) -> bool:
	var err: float = abs(actual - expected)
	var denom: float = max(abs(expected), 1e-12)
	var thr: float = max(abs_tol, rel * denom)
	var ok := err <= thr
	var detail := "actual=%s expected=%s abs_err=%s rel_err=%s thr=%s" % [
		str(actual), str(expected), str(err), str(err / denom), str(thr),
	]
	return check(ok, name, detail)


func all_passed() -> bool:
	for r in results:
		if not r.passed:
			return false
	return true


func pass_count() -> int:
	var n := 0
	for r in results:
		if r.passed:
			n += 1
	return n


func report() -> String:
	var lines := []
	lines.append("======================================================================")
	lines.append(" CircuitForge 3D - Automated Test Report")
	lines.append("======================================================================")
	var last := ""
	for r in results:
		if r.section != last:
			last = r.section
			lines.append("")
			lines.append("[%s]" % last)
		var tag := "PASS" if r.passed else "FAIL"
		var line := "  %-4s %s" % [tag, r.name]
		if not r.passed and r.detail != "":
			line += "  <-- " + r.detail
		lines.append(line)
	lines.append("")
	lines.append("----------------------------------------------------------------------")
	lines.append(" RESULT: %d / %d passed" % [pass_count(), results.size()])
	lines.append(" STATUS: %s" % ("ALL TESTS PASSED" if all_passed() else "FAILURES PRESENT"))
	lines.append("======================================================================")
	return "\n".join(lines)


## Build a two-terminal-or-more element for tests.
func make_element(id: String, type: String, nets: Array, params: Dictionary = {}):
	var SimElement = load("res://scripts/simulation/element.gd")
	var e = SimElement.new()
	e.id = id
	e.type = type
	e.nets = nets
	e.params = params
	return e


func make_circuit(elements: Array):
	var Circuit = load("res://scripts/simulation/circuit.gd")
	var c = Circuit.new()
	for e in elements:
		c.add_element(e)
	return c
