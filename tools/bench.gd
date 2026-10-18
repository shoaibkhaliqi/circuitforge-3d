extends SceneTree
## M10 component-count / performance pass.
##
## Times the two paths that grow with a project, so an accidental complexity regression shows
## up as a number instead of a hunch:
##
##   * the solver on a synthetic resistor ladder (nodes are the variable), and
##   * the whole pipeline on a dense breadboard project -- catalogue components through the
##     netlist builder into a DC solve (component count is the variable).
##
## Run:
##   godot --headless --path <project> --script res://tools/bench.gd
##
## This prints measurements; it does not judge them, and it always exits 0. The regression
## guard lives in `tests/solver/test_scale.gd`, at a budget generous enough for a slow
## machine. See `docs/plan/m10_performance.md` for recorded numbers.

const Session = preload("res://scripts/app/session.gd")
const CircuitSolver = preload("res://scripts/simulation/solver.gd")
const SimElement = preload("res://scripts/simulation/element.gd")
const Circuit = preload("res://scripts/simulation/circuit.gd")

const LADDER_NODES := [200, 400, 800]
const DENSE_BRANCHES := [25, 50, 100, 200]


func _element(id: String, type: String, nets: Array, params: Dictionary = {}):
	var e = SimElement.new()
	e.id = id
	e.type = type
	e.nets = nets
	e.params = params
	return e


## A source, n series resistors and a load: n + 1 nodes, n + 2 elements.
func _ladder(n: int):
	var c = Circuit.new()
	c.add_element(_element("V1", "vsource", ["n0", "0"], {"v": 10.0}))
	for i in n:
		c.add_element(_element("R%d" % i, "resistor", ["n%d" % i, "n%d" % (i + 1)], {"r": 100.0}))
	c.add_element(_element("Rload", "resistor", ["n%d" % n, "0"], {"r": 100.0}))
	return c


## `branches` parallel LED+resistor branches across the rails of a real breadboard project:
## branch i is a resistor from the supply rail (every TP* is the same net) to its own column
## `a{i}`, and a LED from that column to ground (every TM* is the same net). Components =
## 2*branches + 2 (ground + source). The LEDs make it a nonlinear solve, as a real project is.
func _dense_project(branches: int):
	var s = Session.new()
	s.project.breadboard["rows"] = maxi(30, branches)
	s.add_component("ground", ["TM1"])
	s.add_component("vsource", ["TP1", "TM1"], {"v": 5.0})
	for i in range(1, branches + 1):
		s.add_component("resistor", ["TP%d" % i, "a%d" % i], {"r": 220.0})
		s.add_component("led", ["a%d" % i, "TM%d" % i])
	return s


func _bench_ladder(t) -> void:
	for n in LADDER_NODES:
		var c = _ladder(n)
		var solver = CircuitSolver.new()
		var t0 := Time.get_ticks_usec()
		var r = solver.solve_dc(c)
		var us := Time.get_ticks_usec() - t0
		print("  ladder   %4d nodes %4d elements  %7.1f ms  ok=%s" % [
			n, n + 2, us / 1000.0, r.get("ok", false)])
		if not r.get("ok", false):
			print("    ERROR: %s" % r.get("error", ""))


func _bench_dense() -> void:
	for branches in DENSE_BRANCHES:
		var s = _dense_project(branches)
		var components: int = s.project.components.size()
		var t0 := Time.get_ticks_usec()
		var built: Dictionary = s.build_circuit()
		var build_us := Time.get_ticks_usec() - t0
		var solver = CircuitSolver.new()
		var t1 := Time.get_ticks_usec()
		var r = solver.solve_dc(built.circuit)
		var solve_us := Time.get_ticks_usec() - t1
		print("  dense    %4d branches %4d components  build %7.1f ms  solve %7.1f ms  ok=%s" % [
			branches, components, build_us / 1000.0, solve_us / 1000.0, r.get("ok", false)])
		if not r.get("ok", false):
			print("    ERROR: %s" % r.get("error", ""))


func _initialize() -> void:
	print("CircuitForge 3D performance pass")
	print("solver-only resistor ladders (nodes are the variable):")
	_bench_ladder(null)
	print("dense breadboard projects (catalogue -> netlist -> DC solve):")
	_bench_dense()
	quit()
