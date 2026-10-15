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
	_build_labels()


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
	var surf := 0.0                       # top surface height
	var plate_h := 0.012

	# Bottom foot, slightly larger and darker: reads as a bevel + shadow.
	_add_box(Vector3(width + 0.04, 0.02, length + 0.04), Vector3(0, -0.12, 0),
			Color(0.50, 0.48, 0.44), 0.95)

	# Main body (top just under the plates).
	_add_box(Vector3(width, 0.1, length), Vector3(0, surf - plate_h - 0.05, 0),
			Color(0.80, 0.78, 0.72), 0.9)

	# Recessed centre channel: a dark floor sitting below the surface.
	var chan_x := 0.05
	var chan_w := 0.16
	_add_box(Vector3(chan_w, 0.03, length - 0.2), Vector3(chan_x, surf - 0.02, 0),
			Color(0.40, 0.39, 0.37), 0.95)

	# Two top plates with a chamfered (inset) rim, split by the centre channel.
	var edge := width * 0.5 - 0.025
	var chan_l := chan_x - chan_w * 0.5
	var chan_r := chan_x + chan_w * 0.5
	var lx := (-edge + chan_l) * 0.5
	var lw := chan_l + edge
	_add_box(Vector3(lw, plate_h, length - 0.05), Vector3(lx, surf - plate_h * 0.5, 0),
			Color(0.86, 0.84, 0.78), 0.85)
	var rx := (chan_r + edge) * 0.5
	var rw := edge - chan_r
	_add_box(Vector3(rw, plate_h, length - 0.05), Vector3(rx, surf - plate_h * 0.5, 0),
			Color(0.86, 0.84, 0.78), 0.85)

	# Rail colour strips printed just above the surface: red = positive, blue = negative.
	var strip_colors := {"TP": Color(0.78, 0.20, 0.20), "BP": Color(0.78, 0.20, 0.20),
			"TM": Color(0.20, 0.32, 0.78), "BM": Color(0.20, 0.32, 0.78)}
	for p in RAIL_X.keys():
		_add_box(Vector3(0.042, 0.004, length - 0.2), Vector3(RAIL_X[p], surf + 0.002, 0),
				strip_colors[p], 0.7)


func _add_box(size: Vector3, pos: Vector3, color: Color, rough: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = _mat(color, rough)
	mi.position = pos
	add_child(mi)
	return mi


func _mat(color: Color, rough: float = 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m


func _build_labels() -> void:
	var surf := 0.0
	var letter_col := Color(0.30, 0.30, 0.32)
	for i in COLUMNS.size():
		var x := col_x(i)
		# column letters just past each end
		_add_label(COLUMNS[i], Vector3(x, surf + 0.004, row_z(1) - 0.11), 0.0011, letter_col)
		_add_label(COLUMNS[i], Vector3(x, surf + 0.004, row_z(rows) + 0.11), 0.0011, letter_col)
	# row numbers every five rows, on both sides
	var r := 5
	while r <= rows:
		_add_label(str(r), Vector3(-0.97, surf + 0.004, row_z(r)), 0.0011, letter_col)
		_add_label(str(r), Vector3(0.97, surf + 0.004, row_z(r)), 0.0011, letter_col)
		r += 5
	# rail polarity marks
	_add_label("+", Vector3(RAIL_X["TP"], surf + 0.004, row_z(1) - 0.11), 0.0016, Color(0.75, 0.20, 0.20))
	_add_label("-", Vector3(RAIL_X["TM"], surf + 0.004, row_z(1) - 0.11), 0.0016, Color(0.20, 0.32, 0.78))
	_add_label("+", Vector3(RAIL_X["BP"], surf + 0.004, row_z(rows) + 0.11), 0.0016, Color(0.75, 0.20, 0.20))
	_add_label("-", Vector3(RAIL_X["BM"], surf + 0.004, row_z(rows) + 0.11), 0.0016, Color(0.20, 0.32, 0.78))


func _add_label(text: String, pos: Vector3, px: float, color: Color) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = 48
	lbl.pixel_size = px
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	lbl.rotation_degrees = Vector3(-90, 0, 0)
	lbl.modulate = color
	lbl.outline_size = 0
	lbl.position = pos
	add_child(lbl)


func _build_holes() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.016
	cyl.bottom_radius = 0.016
	cyl.height = 0.03
	cyl.radial_segments = 14
	mm.mesh = cyl
	mm.instance_count = _hole_order.size()
	for i in _hole_order.size():
		var pos: Vector3 = hole_positions[_hole_order[i]]
		# Recessed: the dark cylinder's top sits flush with the board surface.
		mm.set_instance_transform(i, Transform3D(Basis(), pos + Vector3(0, -0.015, 0)))
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	var hm := StandardMaterial3D.new()
	hm.albedo_color = Color(0.09, 0.09, 0.10)
	hm.roughness = 0.95
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


## Default holes for a component pinned at `anchor`.
##
## Pins are placed in successive ROWS of the same column, because the five holes
## of one row-half (a-e of f-j) all share one net. Placing the pins across
## columns would put every pin on the same net and short the component.
func default_holes(type: String, pin_count: int, anchor: String) -> Array:
	var out := []
	if type == "ground" or pin_count <= 1:
		return [anchor]
	var prefix := anchor.substr(0, 2)
	var is_rail: bool = RAIL_X.has(prefix)
	var col := "a"
	var start_row := 1
	if is_rail:
		start_row = int(anchor.substr(2))
	else:
		col = anchor.substr(0, 1)
		start_row = int(anchor.substr(1))
	out.append(anchor)
	for i in range(1, pin_count):
		var r := start_row + i
		if r > rows:
			r = start_row - i
		if r < 1:
			r = start_row
		out.append("%s%d" % [col, r])
	return out
