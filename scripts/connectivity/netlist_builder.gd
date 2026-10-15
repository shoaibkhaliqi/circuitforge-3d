extends RefCounted
## CircuitForge 3D - builds a simulation Circuit from the breadboard graph.
##
## Inputs are pure data (no scene nodes):
##   breadboard : Breadboard instance
##   placements : Array of {
##       "id": String, "type": String,
##       "holes": Array[String]  (one entry per pin, "" = not placed),
##       "params": Dictionary, "rotation": float, "position": Array
##   }
##   wires      : Array of {"id":String, "a":endpoint, "b":endpoint}
##                endpoint = {"kind":"hole","id":"a1"}
##                         | {"kind":"pin","component":"R1","pin":0}
##
## Returns a dictionary: {ok, circuit, warnings, pin_nets, net_names, uf, code}

const SimElement = preload("res://scripts/simulation/element.gd")
const Circuit = preload("res://scripts/simulation/circuit.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")
const UnionFind = preload("res://scripts/connectivity/union_find.gd")


func build(breadboard, placements: Array, wires: Array) -> Dictionary:
	var uf = UnionFind.new()
	var warnings := []

	# 1. Breadboard holes, pre-unioned within their physical groups.
	for h in breadboard.all_holes():
		uf.add(h)
	for group in breadboard.net_groups().values():
		for i in range(1, group.size()):
			uf.union(group[0], group[i])

	# 2. Component pins; each pin is unioned with the hole it sits in.
	var pin_node := {}   # "cid:idx" -> uf node id
	for p in placements:
		var cid := String(p.get("id", ""))
		var type := String(p.get("type", ""))
		var def := ComponentDB.get_def(type)
		if def.is_empty():
			warnings.append("Unknown component type '%s' (id %s)." % [type, cid])
			continue
		var holes: Array = p.get("holes", [])
		for i in def.pins.size():
			var node := "P:%s:%d" % [cid, i]
			pin_node["%s:%d" % [cid, i]] = node
			uf.add(node)
			var hole := String(holes[i]) if i < holes.size() else ""
			if hole == "":
				continue
			if breadboard.is_valid_hole(hole):
				uf.union(node, hole)
			else:
				warnings.append("Component %s pin %d is at invalid hole '%s'." % [cid, i + 1, hole])

	# 3. Wires merge whatever they touch (this is the ONLY way to connect groups).
	for w in wires:
		var a := _endpoint_node(w.get("a", {}), uf)
		var b := _endpoint_node(w.get("b", {}), uf)
		if a == "" or b == "":
			warnings.append("Wire %s has an invalid endpoint." % String(w.get("id", "?")))
			continue
		uf.union(a, b)

	# 4. Reference: the ground component's net becomes "0".
	var ground_root := ""
	for p in placements:
		if String(p.get("type", "")) == "ground":
			var cid := String(p.get("id", ""))
			ground_root = uf.find("P:%s:0" % cid)
			break

	# 5. Stable net names: prefer the smallest breadboard hole in each net.
	var members := uf.groups()
	var names := {}
	for r in members:
		if r == ground_root:
			names[r] = "0"
			continue
		var best := ""
		for m in members[r]:
			if String(m).begins_with("P:"):
				continue
			if best == "" or String(m) < best:
				best = String(m)
		if best == "":
			for m in members[r]:
				if best == "" or String(m) < best:
					best = String(m)
		names[r] = best

	# 6. Emit simulation elements.
	var circuit = Circuit.new()
	circuit.reference = "0"
	var pin_nets := {}
	for p in placements:
		var cid := String(p.get("id", ""))
		var type := String(p.get("type", ""))
		var def := ComponentDB.get_def(type)
		if def.is_empty():
			continue
		var nets := []
		var pnets := []
		for i in def.pins.size():
			var r: String = uf.find("P:%s:%d" % [cid, i])
			var nm: String = names.get(r, r)
			nets.append(nm)
			pnets.append(nm)
		pin_nets[cid] = pnets
		if type == "ground":
			continue  # Ground only defines the reference node.
		var els := _make_elements(cid, type, nets, p.get("params", {}), warnings)
		for e in els:
			circuit.add_element(e)

	return {
		"ok": true,
		"circuit": circuit,
		"warnings": warnings,
		"pin_nets": pin_nets,
		"net_names": names.values(),
		"uf": uf,
		"ground_net": "0" if ground_root != "" else "",
	}


func _endpoint_node(ep: Dictionary, uf) -> String:
	var kind := String(ep.get("kind", "hole"))
	if kind == "pin":
		return "P:%s:%d" % [String(ep.get("component", "")), int(ep.get("pin", 0))]
	var hid := String(ep.get("id", ""))
	if hid == "":
		return ""
	uf.add(hid)
	return hid


func _make_elements(cid: String, type: String, nets: Array, params: Dictionary, warnings: Array) -> Array:
	var out := []
	match type:
		"resistor":
			out.append(_el(cid, "resistor", nets, {"r": float(params.get("r", 1000.0))}))
		"capacitor":
			out.append(_el(cid, "capacitor", nets, {"c": float(params.get("c", 1e-6)), "ic": float(params.get("ic", 0.0))}))
		"inductor":
			out.append(_el(cid, "inductor", nets, {"l": float(params.get("l", 1e-3)), "ic": float(params.get("ic", 0.0))}))
		"vsource":
			var vp := {"v": float(params.get("v", 5.0))}
			if params.has("waveform"):
				vp["waveform"] = params["waveform"]
			out.append(_el(cid, "vsource", nets, vp))
		"isource":
			out.append(_el(cid, "isource", nets, {"i": float(params.get("i", 0.01))}))
		"led", "diode", "zener":
			out.append(_el(cid, type, nets, {
				"is": float(params.get("is", 1e-14)),
				"n": float(params.get("n", 1.0)),
				"vz": float(params.get("vz", 5.1)),
			}))
		"switch":
			var r := 0.001 if bool(params.get("closed", false)) else 1e9
			out.append(_el(cid, "resistor", nets, {"r": r}))
		"and", "or", "not", "nand", "nor", "xor", "buffer":
			var def := ComponentDB.get_def(type)
			out.append(_el(cid, "logic", nets, {
				"fn": String(def.get("logic_fn", "and")),
				"vdd": float(params.get("vdd", 5.0)),
				"vth": float(params.get("vth", 2.5)),
				"rout": float(params.get("rout", 1.0)),
			}))
		"potentiometer":
			var rt: float = max(1.0, float(params.get("r", 10000.0)))
			var pos: float = clampf(float(params.get("position", 0.5)), 0.0, 1.0)
			var rupper: float = max(0.001, pos * rt)
			var rlower: float = max(0.001, (1.0 - pos) * rt)
			# First half keeps the component id so per-component readouts work;
			# the second half gets a suffixed internal id.
			out.append(_el(cid, "resistor", [nets[0], nets[1]], {"r": rupper}))
			out.append(_el(cid + "#2", "resistor", [nets[1], nets[2]], {"r": rlower}))
		_:
			warnings.append("Component type '%s' is not yet simulatable; skipped." % type)
	return out


func _el(id: String, type: String, nets: Array, params: Dictionary):
	var e = SimElement.new()
	e.id = id
	e.type = type
	e.nets = nets
	e.params = params
	return e
