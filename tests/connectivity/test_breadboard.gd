extends RefCounted
## Connectivity tests. These inspect the electrical graph, not the appearance.

const Breadboard = preload("res://scripts/breadboard/breadboard.gd")
const NetlistBuilder = preload("res://scripts/connectivity/netlist_builder.gd")
const CircuitSolver = preload("res://scripts/simulation/solver.gd")


func _place(id: String, type: String, holes: Array, params: Dictionary = {}, rot: float = 0.0) -> Dictionary:
	return {"id": id, "type": type, "holes": holes, "params": params, "rotation": rot, "position": [0, 0, 0]}


func _wire(id: String, a: Dictionary, b: Dictionary) -> Dictionary:
	return {"id": id, "a": a, "b": b}


func _hole(id: String) -> Dictionary:
	return {"kind": "hole", "id": id}


func run(t) -> void:
	var builder = NetlistBuilder.new()

	# ---- Five-hole terminal groups ----------------------------------------
	t.section("Breadboard - five-hole terminal groups")
	var bb = Breadboard.new(30)
	var r = builder.build(bb, [], [])
	var uf = r.uf
	t.check(uf.connected("a1", "b1") and uf.connected("a1", "c1") and uf.connected("a1", "d1") and uf.connected("a1", "e1"),
		"row 1 top half a-e are all connected")
	t.check(uf.connected("f7", "j7"), "row 7 bottom half f-j are connected")
	t.check(not uf.connected("f7", "e7"), "the centre channel separates e7 from f7")

	# ---- Separate groups isolated -----------------------------------------
	t.section("Breadboard - separate groups stay isolated")
	t.check(not uf.connected("a1", "a2"), "row 1 and row 2 are isolated")
	t.check(not uf.connected("a1", "f1"), "top and bottom halves of a row are isolated")
	t.check(not uf.connected("a1", "b2"), "diagonal holes are isolated")

	# ---- Power rails ------------------------------------------------------
	t.section("Breadboard - power rails")
	t.check(uf.connected("TP1", "TP30"), "top + rail is continuous")
	t.check(uf.connected("TM5", "TM15"), "top - rail is continuous")
	t.check(not uf.connected("TP1", "BP1"), "top + and bottom + rails are separate")
	t.check(not uf.connected("TM1", "BM1"), "top - and bottom - rails are separate")
	t.check(not uf.connected("TP1", "TM1"), "+ and - rails are separate")

	t.section("Breadboard - split rail option")
	var bbs = Breadboard.new(30, true)
	var rs = builder.build(bbs, [], [])
	t.check(rs.uf.connected("TP1", "TP15"), "split rail: first half connected")
	t.check(not rs.uf.connected("TP1", "TP16"), "split rail: second half isolated")
	t.check(not rs.uf.connected("TP1", "TP30"), "split rail: ends isolated")

	# ---- Wire joins exactly its endpoints ---------------------------------
	t.section("Breadboard - wire joins endpoints")
	var placements = [
		_place("R1", "resistor", ["a1", "a5"], {"r": 1000.0}),
		_place("R2", "resistor", ["a2", "a5"], {"r": 1000.0}),
	]
	var r0 = builder.build(bb, placements, [])
	t.check(r0.pin_nets["R1"][0] != r0.pin_nets["R2"][0], "a1 and a2 start on different nets")
	var wires = [_wire("W1", _hole("a1"), _hole("a2"))]
	var r1 = builder.build(bb, placements, wires)
	t.check(r1.pin_nets["R1"][0] == r1.pin_nets["R2"][0], "wire a1-a2 merges the two nets")
	t.check(r1.uf.connected("a1", "a2"), "a1 and a2 connected after wire")
	t.check(not r1.uf.connected("a1", "a3"), "wire does not connect unintended holes")

	# ---- Junction connects all branches -----------------------------------
	t.section("Breadboard - junction connects all branches")
	var jwires = [
		_wire("W1", _hole("a1"), _hole("b3")),
		_wire("W2", _hole("b3"), _hole("c1")),
		_wire("W3", _hole("b3"), _hole("d3")),
	]
	var rj = builder.build(bb, [], jwires)
	t.check(rj.uf.connected("a1", "c1") and rj.uf.connected("a1", "d3") and rj.uf.connected("c1", "d3"),
		"three wires meeting at one hole connect all branches")

	# ---- Component pins share a hole --------------------------------------
	t.section("Breadboard - shared hole connects pins")
	var rp = builder.build(bb, [
		_place("R1", "resistor", ["a1", "a5"], {"r": 1000.0}),
		_place("R2", "resistor", ["a1", "a6"], {"r": 1000.0}),
	], [])
	t.check(rp.pin_nets["R1"][0] == rp.pin_nets["R2"][0], "two pins in hole a1 share a net")

	# ---- Removing a component removes its branches ------------------------
	t.section("Breadboard - removing a component removes its branches")
	var rboth = builder.build(bb, placements, [])
	t.check(rboth.circuit.elements.size() == 2, "two resistors -> two elements")
	var ronly = builder.build(bb, [placements[0]], [])
	t.check(ronly.circuit.elements.size() == 1, "removing R2 leaves one element")
	t.check(not ronly.pin_nets.has("R2"), "R2 no longer appears")

	# ---- Moving a component does not silently connect the wrong node ------
	t.section("Breadboard - moving a component")
	var rmove = builder.build(bb, [_place("R1", "resistor", ["a1", "b1"], {"r": 1000.0})], [])
	t.check(rmove.pin_nets["R1"][0] == rmove.pin_nets["R1"][1], "both pins in row 1 share the net")
	t.check(rmove.uf.connected("P:R1:1", "b1"), "pin 2 now sits in b1")
	t.check(not rmove.uf.connected("P:R1:1", "a5"), "pin 2 is no longer connected to the old hole a5")

	# ---- Rotating preserves pin identity ----------------------------------
	t.section("Breadboard - rotation preserves pin identity")
	var rrot = builder.build(bb, [_place("R1", "resistor", ["a1", "a5"], {"r": 1000.0}, 1.5707963)], [])
	t.check(rrot.pin_nets["R1"][0] == "a1" and rrot.pin_nets["R1"][1] == "a5",
		"rotation does not change the pin-to-net mapping")

	# ---- Save/load preserves the graph ------------------------------------
	t.section("Breadboard - graph survives a JSON round-trip")
	var snapshot = {"placements": placements, "wires": wires}
	var json_text = JSON.stringify(snapshot)
	var parsed = JSON.parse_string(json_text)
	var rload = builder.build(bb, parsed.placements, parsed.wires)
	t.check(rload.pin_nets == r1.pin_nets, "pin nets identical after round-trip")

	# ---- End-to-end: build a circuit and solve it -------------------------
	t.section("Breadboard - build a real circuit and solve it")
	var ex = [
		_place("V1", "vsource", ["TP1", "TM1"], {"v": 5.0}),
		_place("R1", "resistor", ["TP5", "a5"], {"r": 1000.0}),
		_place("GND", "ground", ["TM1"], {}),
	]
	# Tie a5 to the negative rail with a wire so current can flow.
	var exwires = [_wire("W1", _hole("a5"), _hole("TM5"))]
	var rb = builder.build(bb, ex, exwires)
	var solver = CircuitSolver.new()
	var res = solver.solve_dc(rb.circuit)
	t.check(res.ok, "breadboard circuit solves", res.get("error", ""))
	if res.ok:
		t.near(res.element_currents["R1"], 0.005, "resistor current is 5 mA", 1e-3)
	t.done()
