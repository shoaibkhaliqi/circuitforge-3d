extends RefCounted
## CircuitForge 3D - circuit simulation engine.
##
## Implements Modified Nodal Analysis (MNA):
##   * DC operating point (linear + Newton-Raphson nonlinear)
##   * Transient analysis with backward-Euler companion models
##   * Independent voltage/current sources, R, C, L, diode/LED/zener
##
## This module is intentionally free of any scene-tree dependency. It never
## fabricates a result: if a solve fails, a structured error is returned.

const LinAlg = preload("res://scripts/simulation/lin_alg.gd")
const MNA = preload("res://scripts/simulation/mna.gd")

# Thermal voltage at ~300 K.
const V_T := 0.025852
# Minimum conductance to ground added at every node to help nonlinear convergence.
const GMIN := 1e-9
# Guard on the exponential argument inside the diode model.
const EXP_LIMIT := 80.0

var node_tol := 1e-6
var max_newton := 200
var max_samples := 200000

var _last_iterations := 0
var _warnings: Array = []


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Solve the DC operating point. Returns a SolverResult dictionary.
func solve_dc(circuit) -> Dictionary:
	_last_iterations = 0
	_warnings = []
	var prep := _prepare(circuit)
	if not prep.ok:
		return _failure(prep.error)
	var result := _solve_operating_point(circuit, prep, false, 0.0, {}, 0.0)
	return result


## Run a transient simulation.
## options: {
##   "t_stop": float, "dt": float,
##   "probes": Array of {"kind":"node"|"current", "target":String},  (optional)
##   "initial": {"cap_v": {}, "ind_i": {}}                            (optional)
## }
## Returns {ok, error, warnings, samples:Array, node_voltages, element_currents, ...}
func solve_transient(circuit, options: Dictionary) -> Dictionary:
	_last_iterations = 0
	_warnings = []
	var t_stop: float = float(options.get("t_stop", 0.1))
	var dt: float = float(options.get("dt", 1e-4))
	if dt <= 0.0:
		return _failure("Transient time step dt must be positive (got %s)." % dt)
	if t_stop <= 0.0:
		return _failure("Transient stop time must be positive (got %s)." % t_stop)
	var nsteps := int(round(t_stop / dt))
	if nsteps > max_samples:
		return _failure("Requested %d steps exceeds the %d sample limit. Increase dt or shorten t_stop." % [nsteps, max_samples])

	var prep := _prepare(circuit)
	if not prep.ok:
		return _failure(prep.error)

	var state := {
		"cap_v": options.get("initial", {}).get("cap_v", {}).duplicate(),
		"ind_i": options.get("initial", {}).get("ind_i", {}).duplicate(),
	}
	var samples := []
	var probes: Array = options.get("probes", [])
	var result := {}

	var t := 0.0
	for step in range(nsteps + 1):
		result = _solve_operating_point(circuit, prep, true, t, state, dt)
		if not result.ok:
			result["error"] = "Transient failed at t=%s s: %s" % [str(t), result.error]
			result["samples"] = samples
			return result
		var sample := {"t": t, "probes": {}}
		for pr in probes:
			var kind := String(pr.get("kind", "node"))
			var target := String(pr.get("target", ""))
			if kind == "node":
				sample.probes[target] = result.node_voltages.get(target, 0.0)
			elif kind == "current":
				sample.probes[target] = result.element_currents.get(target, 0.0)
		samples.append(sample)
		_update_state(circuit, result, state)
		t += dt

	result["samples"] = samples
	if not result.ok:
		return result
	return result


## Convenience: return the analytic state dictionary a call would start from.
static func initial_state(circuit) -> Dictionary:
	var cap_v := {}
	var ind_i := {}
	for el in circuit.elements:
		if el.type == "capacitor":
			cap_v[el.id] = float(el.params.get("ic", 0.0))
		elif el.type == "inductor":
			ind_i[el.id] = float(el.params.get("ic", 0.0))
	return {"cap_v": cap_v, "ind_i": ind_i}


# ---------------------------------------------------------------------------
# Internal: setup
# ---------------------------------------------------------------------------

func _prepare(circuit) -> Dictionary:
	var names := []
	var seen := {}
	for el in circuit.elements:
		for n in el.nets:
			if typeof(n) == TYPE_STRING and n != "" and not seen.has(n):
				seen[n] = true
				names.append(n)
	if names.is_empty():
		return {"ok": false, "error": "Circuit has no connected elements to simulate."}
	if not seen.has(circuit.reference):
		return {"ok": false, "error": "No reference (ground) node. Connect the Ground component (net '0')."}
	names.erase(circuit.reference)
	names.sort()
	var nets := [circuit.reference]
	nets.append_array(names)

	var node_index := {}
	for i in nets.size():
		node_index[nets[i]] = i

	var branch_rows := {}
	var node_unknowns := nets.size() - 1
	var k := 0
	for el in circuit.elements:
		if el.type == "vsource" or el.type == "inductor" or el.type == "logic":
			branch_rows[el.id] = node_unknowns + k
			k += 1

	var mna = MNA.new()
	mna.setup(nets.size(), k)
	return {"ok": true, "mna": mna, "node_index": node_index, "branch_rows": branch_rows, "nets": nets}


func _solve_operating_point(circuit, prep, transient: bool, t: float, state: Dictionary, dt: float) -> Dictionary:
	var mna = prep.mna
	var node_index: Dictionary = prep.node_index
	var branch_rows: Dictionary = prep.branch_rows

	var ctx := {
		"t": t, "transient": transient, "dt": dt,
		"state": state, "ev": {}, "guess": {},
	}

	if _is_linear(circuit):
		mna.reset()
		_stamp_all(mna, circuit, node_index, branch_rows, ctx)
		var sol := LinAlg.solve(mna.a, mna.z)
		if not sol.ok:
			return _failure(sol.error)
		return _build_result(circuit, prep, sol.x, ctx)

	# Nonlinear: Newton-Raphson with SPICE-style junction voltage limiting.
	var guess := {}
	for net in prep.nets:
		guess[net] = 0.0
	var ev := {}
	for el in circuit.elements:
		if _is_nonlinear(el.type):
			ev[el.id] = 0.0
	ctx.ev = ev

	var iterations := 0
	var x: Array = []
	for it in range(max_newton):
		ctx.guess = guess
		mna.reset()
		_stamp_all(mna, circuit, node_index, branch_rows, ctx)
		_add_gmin(mna, node_index)
		var sol := LinAlg.solve(mna.a, mna.z)
		if not sol.ok:
			return _failure(sol.error)
		x = sol.x
		var newv := _extract_node_v(node_index, x)
		var maxd := 0.0
		for net in newv:
			maxd = max(maxd, abs(newv[net] - guess[net]))
		# Update limited evaluation voltages for nonlinear devices, and require the
		# limiting state to settle before declaring convergence (otherwise Newton
		# can stop while a junction is still being pulled into conduction).
		var ev_delta := _update_ev(circuit, newv, ctx)
		guess = newv
		iterations += 1
		if maxd < node_tol and ev_delta < node_tol:
			_last_iterations = iterations
			var res := _build_result(circuit, prep, x, ctx)
			res["iterations"] = iterations
			return res
	return _failure("Nonlinear solver did not converge after %d iterations. Check device parameters and source values." % max_newton)


func _update_ev(circuit, guess: Dictionary, ctx: Dictionary) -> float:
	var max_delta := 0.0
	for el in circuit.elements:
		if not _is_nonlinear(el.type):
			continue
		var vp: float = guess.get(el.nets[0], 0.0)
		var vn: float = guess.get(el.nets[1], 0.0)
		var vnew := vp - vn
		var n_ideal: float = float(el.params.get("n", 1.8))
		var isat: float = float(el.params.get("is", 1e-19))
		var vte: float = n_ideal * V_T
		var vcrit: float = vte * log(vte / (sqrt(2.0) * isat))
		var old: float = float(ctx.ev.get(el.id, 0.0))
		var limited := _pnjlim(vnew, old, vte, vcrit)
		ctx.ev[el.id] = limited
		max_delta = max(max_delta, abs(limited - old))
	return max_delta


func _pnjlim(vnew: float, vold: float, vte: float, vcrit: float) -> float:
	if vnew > vcrit and abs(vnew - vold) > 2.0 * vte:
		var arg: float = 1.0 + (vnew - vold) / vte
		if arg > 0.0:
			vnew = vold + vte * log(arg)
		else:
			vnew = vcrit
	elif vnew < 0.0 and abs(vnew - vold) > 2.0 * vte and vold < 0.0:
		# Reverse-bias limiting.
		var arg2: float = 1.0 - (vnew - vold) / vte
		vnew = vold - vte * log(arg2) if arg2 > 0.0 else vnew
	return vnew


func _add_gmin(mna, node_index: Dictionary) -> void:
	for net in node_index:
		var idx: int = node_index[net]
		if idx > 0:
			mna.add_shunt(idx, GMIN)


# ---------------------------------------------------------------------------
# Internal: stamping
# ---------------------------------------------------------------------------

func _stamp_all(mna, circuit, node_index: Dictionary, branch_rows: Dictionary, ctx: Dictionary) -> void:
	for el in circuit.elements:
		_stamp_element(mna, el, node_index, branch_rows, ctx)


func _stamp_element(mna, el, node_index: Dictionary, branch_rows: Dictionary, ctx: Dictionary) -> void:
	if el.nets.size() < 2:
		_warn("Component '%s' has fewer than 2 terminals; ignored." % el.id)
		return
	var p: int = node_index.get(el.nets[0], -1)
	var n: int = node_index.get(el.nets[1], -1)
	if p < 0 or n < 0:
		_warn("Component '%s' has an unconnected terminal; ignored." % el.id)
		return

	match el.type:
		"resistor", "potentiometer":
			var g: float = 1.0 / max(1e-9, float(el.params.get("r", 1000.0)))
			mna.add_g(p, n, g)
		"vsource":
			var row: int = branch_rows[el.id]
			mna.add_branch(p, n, row)
			mna.z[row] = _source_value(el, ctx.t)
		"isource":
			var i := _source_value(el, ctx.t)
			mna.add_i(n, p, i)  # pushes current from pin1 into pin0
		"capacitor":
			if ctx.transient:
				var c: float = float(el.params.get("c", 1e-6))
				var geq: float = c / ctx.dt
				var vprev: float = float(ctx.state.cap_v.get(el.id, float(el.params.get("ic", 0.0))))
				mna.add_g(p, n, geq)
				mna.add_i(p, n, geq * vprev)
			# DC: open circuit, no stamp.
		"inductor":
			var row2: int = branch_rows[el.id]
			mna.add_branch(p, n, row2)
			if ctx.transient:
				var l: float = float(el.params.get("l", 1e-3))
				var coeff: float = -(l / ctx.dt)
				var iprev: float = float(ctx.state.ind_i.get(el.id, float(el.params.get("ic", 0.0))))
				mna.branch_extra(row2, coeff, coeff * iprev)
			# DC: ideal 0 V source (short circuit).
		"diode", "led", "zener":
			var ev: float = float(ctx.ev.get(el.id, 0.0))
			var d := _diode_eval(el, ev)
			mna.add_g(p, n, d.g)
			mna.add_i(p, n, d.g * ev - d.i)
		"logic":
			var row: int = branch_rows[el.id]
			var out_net: String = String(el.nets[el.nets.size() - 1])
			var outp: int = node_index.get(out_net, -1)
			if outp < 0:
				_warn("Logic gate '%s' has an unconnected output; ignored." % el.id)
				return
			var vout: float = _logic_eval(el, node_index, ctx)
			var rout: float = max(0.0, float(el.params.get("rout", 1.0)))
			mna.add_branch(outp, 0, row)
			mna.branch_extra(row, -rout, vout)
		"gpio":
			# Stage A pin driver: a Thevenin source (vout, rout) stamped as its
			# Norton equivalent so no branch unknown is needed. Level -1 is
			# high-impedance, modelled as a very weak pull to the pin's reference.
			var level: float = float(el.params.get("level", 1.0))
			var vlogic: float = float(el.params.get("vlogic", 5.0))
			var r: float = max(0.1, float(el.params.get("rout", 25.0)))
			var vdrv := 0.0
			if level >= 0.5:
				vdrv = vlogic
			elif level <= -0.5:
				r = 1e8  # input / high-Z
				vdrv = 0.0
			var gg: float = 1.0 / r
			mna.add_g(p, n, gg)
			mna.add_i(p, n, gg * vdrv)
		"vout":
			# Analog output (e.g. a PWM pin's average): a linear Thevenin source
			# `voltage` in series with `rout`, stamped as its Norton equivalent.
			var vset: float = float(el.params.get("voltage", 0.0))
			var rp: float = max(0.1, float(el.params.get("rout", 25.0)))
			var gp: float = 1.0 / rp
			mna.add_g(p, n, gp)
			mna.add_i(p, n, gp * vset)
		"wire":
			# Wires are handled by net merging in the connectivity layer.
			pass
		_:
			_warn("Unknown element type '%s' for '%s'; ignored." % [el.type, el.id])


func _source_value(el, t: float) -> float:
	var wf = el.params.get("waveform", null)
	if typeof(wf) != TYPE_DICTIONARY:
		return float(el.params.get("v", el.params.get("i", 0.0)))
	var type := String(wf.get("type", "dc"))
	match type:
		"sine":
			var a: float = float(wf.get("amplitude", el.params.get("v", 1.0)))
			var f: float = float(wf.get("frequency", 1.0))
			var off: float = float(wf.get("offset", 0.0))
			var ph: float = float(wf.get("phase", 0.0))
			return off + a * sin(TAU * f * t + ph)
		"pulse", "square":
			var v1: float = float(wf.get("v1", 0.0))
			var v2: float = float(wf.get("v2", el.params.get("v", 5.0)))
			var delay: float = float(wf.get("delay", 0.0))
			var period: float = max(1e-12, float(wf.get("period", 1.0)))
			var duty: float = clampf(float(wf.get("duty", 0.5)), 0.0, 1.0)
			if t < delay:
				return v1
			var phase: float = fmod(t - delay, period) / period
			return v2 if phase < duty else v1
		_:
			return float(wf.get("value", el.params.get("v", el.params.get("i", 0.0))))


func _logic_eval(el, node_index: Dictionary, ctx: Dictionary) -> float:
	var guess: Dictionary = ctx.get("guess", {})
	var vdd: float = float(el.params.get("vdd", 5.0))
	var vth: float = float(el.params.get("vth", vdd * 0.5))
	var fn: String = String(el.params.get("fn", "and"))
	var a: bool = _logic_level(el.nets[0], node_index, guess, vth)
	var b: bool = true
	if el.nets.size() >= 3:
		b = _logic_level(el.nets[1], node_index, guess, vth)
	return vdd if _apply_logic(fn, a, b) else 0.0


func _logic_level(net, node_index: Dictionary, guess: Dictionary, vth: float) -> bool:
	var n := String(net)
	if not node_index.has(n):
		return false
	return float(guess.get(n, 0.0)) > vth


func _apply_logic(fn: String, a: bool, b: bool) -> bool:
	match fn:
		"and": return a and b
		"or": return a or b
		"not": return not a
		"nand": return not (a and b)
		"nor": return not (a or b)
		"xor": return a != b
		"buffer", "buf": return a
		_: return false


func _diode_eval(el, vd: float) -> Dictionary:
	var n_ideal: float = float(el.params.get("n", 1.8))
	var isat: float = float(el.params.get("is", 1e-19))
	var vte: float = n_ideal * V_T
	var x: float = vd / vte
	if x > EXP_LIMIT:
		x = EXP_LIMIT
	var ex: float = exp(x)
	var i: float = isat * (ex - 1.0)
	var g: float = isat * ex / vte
	# Zener reverse breakdown term.
	if el.type == "zener":
		var vz: float = float(el.params.get("vz", 5.1))
		var nz: float = float(el.params.get("nz", 1.0))
		var vtez: float = nz * V_T
		var xz: float = (-vd - vz) / vtez
		if xz > EXP_LIMIT:
			xz = EXP_LIMIT
		var exz: float = exp(xz)
		var isz: float = float(el.params.get("isz", isat))
		i -= isz * (exz - 1.0)
		g += isz * exz / vtez
	if g < 1e-18:
		g = 1e-18
	return {"i": i, "g": g}


# ---------------------------------------------------------------------------
# Internal: results
# ---------------------------------------------------------------------------

func _build_result(circuit, prep, x: Array, ctx: Dictionary) -> Dictionary:
	var node_index: Dictionary = prep.node_index
	var branch_rows: Dictionary = prep.branch_rows
	var V := _extract_node_v(node_index, x)
	var ev: Dictionary = {}
	var iout := {}
	var vout := {}
	for el in circuit.elements:
		if el.nets.size() < 2:
			continue
		if not node_index.has(el.nets[0]) or not node_index.has(el.nets[1]):
			continue
		vout[el.id] = V.get(el.nets[0], 0.0) - V.get(el.nets[1], 0.0)
		iout[el.id] = _element_current(el, V, branch_rows, x, ctx)
	var res := {
		"ok": true,
		"error": "",
		"warnings": _warnings.duplicate(),
		"node_voltages": V,
		"element_voltages": vout,
		"element_currents": iout,
		"iterations": _last_iterations,
		"reference": circuit.reference,
		"time": ctx.t,
	}
	return res


func _extract_node_v(node_index: Dictionary, x: Array) -> Dictionary:
	var V := {}
	for net in node_index:
		var idx: int = node_index[net]
		V[net] = 0.0 if idx == 0 else x[idx - 1]
	return V


func _element_current(el, V: Dictionary, branch_rows: Dictionary, x: Array, ctx: Dictionary) -> float:
	var v: float = V.get(el.nets[0], 0.0) - V.get(el.nets[1], 0.0)
	match el.type:
		"resistor", "potentiometer":
			return v / max(1e-9, float(el.params.get("r", 1000.0)))
		"vsource", "inductor":
			if branch_rows.has(el.id):
				return x[branch_rows[el.id]]
			return 0.0
		"logic":
			if branch_rows.has(el.id):
				return x[branch_rows[el.id]]
			return 0.0
		"isource":
			return _source_value(el, ctx.t)
		"capacitor":
			if ctx.transient:
				var c: float = float(el.params.get("c", 1e-6))
				var vprev: float = float(ctx.state.cap_v.get(el.id, float(el.params.get("ic", 0.0))))
				return (c / ctx.dt) * (v - vprev)
			return 0.0
		"diode", "led", "zener":
			return _diode_eval(el, v).i
		"gpio":
			var level: float = float(el.params.get("level", 1.0))
			var vlogic: float = float(el.params.get("vlogic", 5.0))
			var r: float = max(0.1, float(el.params.get("rout", 25.0)))
			var vdrv := 0.0
			if level >= 0.5:
				vdrv = vlogic
			elif level <= -0.5:
				r = 1e8
			return (v - vdrv) / r
		"vout":
			var vset: float = float(el.params.get("voltage", 0.0))
			var rp: float = max(0.1, float(el.params.get("rout", 25.0)))
			return (v - vset) / rp
		_:
			return 0.0


func _update_state(circuit, result: Dictionary, state: Dictionary) -> void:
	for el in circuit.elements:
		if el.type == "capacitor":
			state.cap_v[el.id] = result.element_voltages.get(el.id, 0.0)
		elif el.type == "inductor":
			state.ind_i[el.id] = result.element_currents.get(el.id, 0.0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _is_linear(circuit) -> bool:
	for el in circuit.elements:
		if _is_nonlinear(el.type):
			return false
	return true


func _is_nonlinear(t: String) -> bool:
	return t == "diode" or t == "led" or t == "zener" or t == "logic"


func _warn(msg: String) -> void:
	if not _warnings.has(msg):
		_warnings.append(msg)


func _failure(msg: String) -> Dictionary:
	return {
		"ok": false,
		"error": msg,
		"warnings": _warnings.duplicate(),
		"node_voltages": {},
		"element_voltages": {},
		"element_currents": {},
		"iterations": _last_iterations,
	}
