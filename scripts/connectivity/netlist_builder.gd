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

## Default source voltage for catalogue parts whose instance parameters may omit
## `v`. Kept honest: these are the documented nominal values for the part.
const SOURCE_DEFAULTS := {
	"battery_aa": 1.5, "battery_aaa": 1.5, "battery_9v": 9.0,
	"battery_18650": 3.7, "coin_cell_cr2032": 3.0, "battery_aa_holder": 6.0,
	"lipo_1s": 3.7, "usb_power_5v": 5.0, "bench_psu": 5.0,
}


## Component types that have a real electrical model in the solver (see
## `_make_elements`). Used by the catalog honesty test so a part may never claim
## `full`/`partial` status without actually being mappable here.
const HANDLED_TYPES := [
	"resistor", "capacitor", "inductor", "potentiometer", "trimmer", "vsource",
	"isource", "led", "diode", "zener", "switch", "ground",
	"and", "or", "not", "nand", "nor", "xor", "buffer", "mcu_pin",
	"electrolytic_capacitor", "film_capacitor", "tantalum_capacitor", "supercapacitor",
	"ferrite_bead", "shunt_resistor", "polyfuse", "push_button", "reed_switch",
	"toggle_switch", "led_green", "led_blue", "led_ir", "rectifier_diode",
	"schottky_diode", "battery_aa", "battery_aaa", "battery_9v", "battery_18650",
	"coin_cell_cr2032", "battery_aa_holder", "lipo_1s", "usb_power_5v", "bench_psu",
	"ac_source", "breadboard_psu_5v",
	"thermistor_ntc", "photoresistor_ldr", "rtd_pt100",
	"dc_motor", "dc_gearmotor_tt", "fan_5v", "vibration_motor", "solenoid_12v",
]


static func handles(type: String) -> bool:
	return HANDLED_TYPES.has(type)


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
		"resistor", "shunt_resistor", "polyfuse":
			var r_default := 0.5 if type == "polyfuse" else (0.1 if type == "shunt_resistor" else 1000.0)
			out.append(_el(cid, "resistor", nets, {"r": float(params.get("r", r_default))}))
		"capacitor", "electrolytic_capacitor", "film_capacitor", "tantalum_capacitor", "supercapacitor":
			out.append(_el(cid, "capacitor", nets, {"c": float(params.get("c", 1e-6)), "ic": float(params.get("ic", 0.0))}))
		"inductor", "ferrite_bead":
			var l_default := 1e-6 if type == "ferrite_bead" else 1e-3
			out.append(_el(cid, "inductor", nets, {"l": float(params.get("l", l_default)), "ic": float(params.get("ic", 0.0))}))
		"vsource":
			var vp := {"v": float(params.get("v", 5.0))}
			if params.has("waveform"):
				vp["waveform"] = params["waveform"]
			out.append(_el(cid, "vsource", nets, vp))
		"isource":
			out.append(_el(cid, "isource", nets, {"i": float(params.get("i", 0.01))}))
		"led", "led_green", "led_blue", "led_ir", "diode", "rectifier_diode", "schottky_diode", "zener":
			var el_type := "zener" if type == "zener" else ("led" if type.begins_with("led") else "diode")
			out.append(_el(cid, el_type, nets, {
				"is": float(params.get("is", 1e-14)),
				"n": float(params.get("n", 1.0)),
				"vz": float(params.get("vz", 5.1)),
			}))
		"switch", "push_button", "reed_switch":
			var r := 0.001 if bool(params.get("closed", false)) else 1e9
			out.append(_el(cid, "resistor", nets, {"r": r}))
		"toggle_switch":
			var tpos: float = clampf(float(params.get("position", 0.0)), 0.0, 1.0)
			out.append(_el(cid, "resistor", [nets[0], nets[1]], {"r": 0.001 if tpos >= 0.5 else 1e9}))
			out.append(_el(cid + "#2", "resistor", [nets[0], nets[2]], {"r": 1e9 if tpos >= 0.5 else 0.001}))
		"and", "or", "not", "nand", "nor", "xor", "buffer":
			var def := ComponentDB.get_def(type)
			out.append(_el(cid, "logic", nets, {
				"fn": String(def.get("logic_fn", "and")),
				"vdd": float(params.get("vdd", 5.0)),
				"vth": float(params.get("vth", 2.5)),
				"rout": float(params.get("rout", 1.0)),
			}))
		"mcu_pin":
			# Stage A pin driver: an ideal Thevenin source (level, vlogic, rout).
			out.append(_el(cid, "gpio", nets, {
				"level": float(params.get("level", 1.0)),
				"vlogic": float(params.get("vlogic", 5.0)),
				"rout": float(params.get("rout", 25.0)),
			}))
		"battery_aa", "battery_aaa", "battery_9v", "battery_18650", "coin_cell_cr2032", "battery_aa_holder", "lipo_1s", "usb_power_5v", "bench_psu":
			var v_def: float = float(SOURCE_DEFAULTS.get(type, 5.0))
			var v_val: float = float(params.get("v", params.get("voltage", v_def)))
			var rr: float = float(params.get("r_internal", params.get("r_int", 0.0)))
			_source_with_series(cid, nets[0], nets[1], v_val, rr, out)
		"ac_source":
			var amp: float = float(params.get("amplitude", 5.0))
			var frq: float = float(params.get("frequency", 50.0))
			out.append(_el(cid, "vsource", nets, {
				"v": amp, "waveform": {"type": "sine", "amplitude": amp, "frequency": frq, "offset": 0.0},
			}))
		"breadboard_psu_5v":
			out.append(_el(cid, "vsource", [nets[2], nets[1]], {"v": 5.0}))
			out.append(_el(cid + "#3v3", "vsource", [nets[3], nets[1]], {"v": 3.3}))
		"potentiometer", "trimmer":
			var rt: float = max(1.0, float(params.get("r", 10000.0)))
			var pos: float = clampf(float(params.get("position", 0.5)), 0.0, 1.0)
			var rupper: float = max(0.001, pos * rt)
			var rlower: float = max(0.001, (1.0 - pos) * rt)
			# First half keeps the component id so per-component readouts work;
			# the second half gets a suffixed internal id.
			out.append(_el(cid, "resistor", [nets[0], nets[1]], {"r": rupper}))
			out.append(_el(cid + "#2", "resistor", [nets[1], nets[2]], {"r": rlower}))
		"thermistor_ntc":
			# Beta-equation NTC: R = R25 * exp(B * (1/T - 1/T25)), T in kelvin.
			var r25: float = max(1.0, float(params.get("r25", 10000.0)))
			var beta: float = max(1.0, float(params.get("beta", 3950.0)))
			var t_c: float = float(params.get("temperature", 25.0))
			var t_k: float = t_c + 273.15
			var r_ntc: float = r25 * exp(beta * (1.0 / t_k - 1.0 / 298.15))
			out.append(_el(cid, "resistor", nets, {"r": clampf(r_ntc, 1.0, 1e12)}))
		"photoresistor_ldr":
			# Log-linear interpolation between dark and bright resistance from a
			# 0-1 light level: R = R_dark * (R_light/R_dark)^light.
			var r_dark: float = max(1.0, float(params.get("r_dark", 1000000.0)))
			var r_light: float = max(1.0, float(params.get("r_light", 1000.0)))
			var light_lvl: float = clampf(float(params.get("light", 0.5)), 0.0, 1.0)
			out.append(_el(cid, "resistor", nets, {"r": clampf(r_dark * pow(r_light / r_dark, light_lvl), 1.0, 1e12)}))
		"rtd_pt100":
			# Callendar-style linear RTD: R = R0 * (1 + 0.00385 * T_degC).
			var t_rtd: float = float(params.get("temperature", 0.0))
			var r0_rtd: float = max(1.0, float(params.get("r0", 100.0)))
			out.append(_el(cid, "resistor", nets, {"r": clampf(r0_rtd * (1.0 + 0.00385 * t_rtd), 1.0, 1e12)}))
		"dc_motor", "dc_gearmotor_tt", "fan_5v", "vibration_motor":
			# Steady-state brushed motor: winding resistance plus an assumed
			# back-EMF the user supplies (0 V = stalled). No speed dynamics.
			var rm: float = max(0.1, float(params.get("r", 10.0)))
			var vemf: float = float(params.get("back_emf", 0.0))
			if absf(vemf) > 1e-9:
				var mmid := cid + "#m"
				out.append(_el(cid, "resistor", [nets[0], mmid], {"r": rm}))
				out.append(_el(cid + "#emf", "vsource", [mmid, nets[1]], {"v": vemf}))
			else:
				out.append(_el(cid, "resistor", nets, {"r": rm}))
		"solenoid_12v":
			# Coil: inductance in series with winding resistance.
			var rl: float = max(0.1, float(params.get("r", 30.0)))
			var lc: float = max(0.0, float(params.get("l", 0.05)))
			var lmid := cid + "#m"
			out.append(_el(cid, "inductor", [nets[0], lmid], {"l": lc, "ic": 0.0}))
			out.append(_el(cid + "#r", "resistor", [lmid, nets[1]], {"r": rl}))
		_:
			warnings.append("Component type '%s' is not yet simulatable; skipped." % type)
	return out


## An ideal voltage source, optionally with a series internal resistance. When
## rin > 0 the source and resistor are split over a private internal node so the
## terminal current still equals the source current under the component id.
func _source_with_series(cid: String, a: String, b: String, v: float, rin: float, out: Array) -> void:
	if rin > 1e-9:
		var mid := cid + "#m"
		out.append(_el(cid, "vsource", [a, mid], {"v": v}))
		out.append(_el(cid + "#r", "resistor", [mid, b], {"r": rin}))
	else:
		out.append(_el(cid, "vsource", [a, b], {"v": v}))


func _el(id: String, type: String, nets: Array, params: Dictionary):
	var e = SimElement.new()
	e.id = id
	e.type = type
	e.nets = nets
	e.params = params
	return e
