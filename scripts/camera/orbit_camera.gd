extends Camera3D
## CircuitForge 3D - orbit / pan / zoom camera.
##
## Exposes explicit orbit/pan/zoom methods so the behaviour can be unit-tested
## without synthesising input events.

var target := Vector3.ZERO
var distance := 2.4
var yaw := deg_to_rad(-35.0)
var pitch := deg_to_rad(32.0)
var min_distance := 0.6
var max_distance := 20.0

var _rotating := false
var _panning := false


func _ready() -> void:
	fov = 55.0
	_update_transform()


func orbit(dx: float, dy: float) -> void:
	yaw -= dx * 0.01
	pitch = clampf(pitch + dy * 0.01, deg_to_rad(-85.0), deg_to_rad(85.0))
	_update_transform()


func pan(dx: float, dy: float) -> void:
	var forward := (target - position).normalized()
	var right := forward.cross(Vector3.UP)
	if right.length() < 1e-6:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := right.cross(forward).normalized()
	var s := distance * 0.0016
	target += (-right * dx + up * dy) * s
	_update_transform()


func zoom(factor: float) -> void:
	distance = clampf(distance * factor, min_distance, max_distance)
	_update_transform()


func focus_on(point: Vector3, new_distance: float = -1.0) -> void:
	target = point
	if new_distance > 0.0:
		distance = clampf(new_distance, min_distance, max_distance)
	_update_transform()


## Snap to a named preset view. Keeps the current target and distance.
func set_preset(preset: String) -> void:
	match preset:
		"top":
			yaw = 0.0
			pitch = deg_to_rad(89.0)
		"front":
			yaw = 0.0
			pitch = 0.0
		"side":
			yaw = deg_to_rad(90.0)
			pitch = 0.0
		"iso":
			yaw = deg_to_rad(-35.0)
			pitch = deg_to_rad(32.0)
	_update_transform()


## Frame a bounding box (min/max in world space) with a small margin.
func frame_box(min_pt: Vector3, max_pt: Vector3) -> void:
	target = (min_pt + max_pt) * 0.5
	var extent := (max_pt - min_pt).length()
	distance = clampf(extent * 1.35 + 0.4, min_distance, max_distance)
	_update_transform()


func _update_transform() -> void:
	var dir := Vector3(
		cos(pitch) * sin(yaw),
		sin(pitch),
		cos(pitch) * cos(yaw)
	)
	# look_at_from_position works whether or not the node is inside the tree,
	# which keeps the controller unit-testable.
	look_at_from_position(target + dir * distance, target, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			zoom(0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			zoom(1.1)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_rotating = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _rotating:
			orbit(mm.relative.x, mm.relative.y)
		elif _panning:
			pan(mm.relative.x, mm.relative.y)
