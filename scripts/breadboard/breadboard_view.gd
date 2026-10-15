extends Node3D
## CircuitForge 3D - visual breadboard with real hole positions.
##
## The geometry here is the single source of truth for where a hole is in space.
## The electrical topology lives in scripts/breadboard/breadboard.gd; the two must
## use the same hole ids (a1..j30, rail holes TP<row> etc.).

const PITCH := 0.1
const COLUMNS := ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
const RAIL_X := {"TP": -0.72, "TM": -0.88, "BP": 0.72, "BM": 0.88}

var rows := 30
var rail_split := false
var hole_positions: Dictionary = {}     # hole id -> local Vector3
var _hole_order: Array = []


func _ready() -> void:
	build(rows, rail_split)


func col_x(i: int) -> float:
	var x := (float(i) - 4.5) * PITCH
	if i >= 5:
		x += PITCH
	return x


func row_z(r: int) -> float:
	return (float(r - 1) - float(rows - 1) * 0.5) * PITCH


func build(p_rows: int = 30, p_split: bool = false) -> void:
	rows = p_rows
	rail_split = p_split
	for c in get_children():
		c.queue_free()
	hole_positions.clear()
	_hole_order.clear()
	_compute_holes()
	_build_base()
	_build_holes()


func _compute_holes() -> void:
	for r in range(1, rows + 1):
		for i in COLUMNS.size():
			var h := "%s%d" % [COLUMNS[i], r]
			hole_positions[h] = Vector3(col_x(i), 0.0, row_z(r))
			_hole_order.append(h)
	for p in RAIL_X.keys():
		for r in range(1, rows + 1):
			var h := "%s%d" % [p, r]
			hole_positions[h] = Vector3(RAIL_X[p], 0.0, row_z(r))
			_hole_order.append(h)


func _build_base() -> void:
	var width := 1.9
	var length := float(rows) * PITCH + 0.3
	var base := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, 0.12, length)
	base.mesh = box
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.78, 0.76, 0.70)
	m.roughness = 0.9
	base.material_override = m
	base.position = Vector3(0, -0.06, 0)
	add_child(base)

	# Centre channel groove.
	var groove := MeshInstance3D.new()
	var g := BoxMesh.new()
	g.size = Vector3(0.06, 0.02, length - 0.2)
	groove.mesh = g
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.45, 0.44, 0.42)
	groove.material_override = gm
	groove.position = Vector3(0.05, 0.005, 0)
	add_child(groove)

	# Rail colour strips: red = positive, blue = negative.
	var strip_colors := {"TP": Color(0.75, 0.2, 0.2), "BP": Color(0.75, 0.2, 0.2), "TM": Color(0.2, 0.3, 0.75), "BM": Color(0.2, 0.3, 0.75)}
	for p in RAIL_X.keys():
		var strip := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.05, 0.02, length - 0.2)
		strip.mesh = sb
		var sm := StandardMaterial3D.new()
		sm.albedo_color = strip_colors[p]
		strip.material_override = sm
		strip.position = Vector3(RAIL_X[p], 0.005, 0)
		add_child(strip)


func _build_holes() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.016
	cyl.bottom_radius = 0.016
	cyl.height = 0.03
	mm.mesh = cyl
	mm.instance_count = _hole_order.size()
	for i in _hole_order.size():
		var pos: Vector3 = hole_positions[_hole_order[i]]
		mm.set_instance_transform(i, Transform3D(Basis(), pos + Vector3(0, 0.015, 0)))
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	var hm := StandardMaterial3D.new()
	hm.albedo_color = Color(0.12, 0.12, 0.13)
	node.material_override = hm
	add_child(node)


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func hole_world(hole: String) -> Vector3:
	if not hole_positions.has(hole):
		return Vector3.ZERO
	return to_global(hole_positions[hole])


func hole_ids() -> Array:
	return _hole_order.duplicate()


func nearest_hole(world_point: Vector3, max_dist: float = 0.05) -> String:
	var best := ""
	var best_d := max_dist
	for h in _hole_order:
		var d := hole_world(h).distance_to(world_point)
		if d < best_d:
			best_d = d
			best = h
	return best


## Nearest hole to a ray (origin, direction). Returns "" if beyond max_hit.
func ray_nearest_hole(origin: Vector3, direction: Vector3, max_hit: float = 6.0) -> String:
	var d := direction.normalized()
	var best := ""
	var best_d := max_hit
	for h in _hole_order:
		var p := hole_world(h)
		var t := (p - origin).dot(d)
		if t < 0.0:
			continue
		var closest := origin + d * t
		var dist := closest.distance_to(p)
		if dist < best_d:
			best_d = dist
			best = h
	return best


## Next terminal hole in the same half-row, `steps` columns away.
func column_neighbor(hole: String, steps: int) -> String:
	if hole == "" or hole.length() < 2:
		return ""
	var col := hole.substr(0, 1)
	var row := hole.substr(1)
	var idx := COLUMNS.find(col)
	if idx < 0:
		return ""
	var ni := idx + steps
	if ni < 0 or ni >= COLUMNS.size():
		return ""
	# Stay within the same half across the centre channel.
	if idx < 5 and ni >= 5:
		return ""
	if idx >= 5 and ni < 5:
		return ""
	return "%s%s" % [COLUMNS[ni], row]


## Default holes for a component pinned at `anchor`, spread horizontally.
func default_holes(type: String, pin_count: int, anchor: String) -> Array:
	var out := []
	if type == "ground" or pin_count <= 1:
		return [anchor]
	# Place pins on successive columns, walking away from the centre channel.
	var dir := -1
	var col := anchor.substr(0, 1)
	var idx := COLUMNS.find(col)
	if idx >= 5:
		dir = 1
	var cur := anchor
	out.append(cur)
	for i in range(1, pin_count):
		var nxt := column_neighbor(cur, dir)
		if nxt == "":
			nxt = column_neighbor(anchor, -dir * i)
		if nxt == "":
			nxt = cur
		out.append(nxt)
		cur = nxt
	return out
