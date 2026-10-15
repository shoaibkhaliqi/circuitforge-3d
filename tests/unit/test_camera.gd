extends RefCounted
## Camera interaction tests (orbit / pan / zoom) at the logic level.

const OrbitCamera = preload("res://scripts/camera/orbit_camera.gd")


func run(t) -> void:
	t.section("Camera - orbit / pan / zoom")
	var cam = OrbitCamera.new()
	if t.tree != null:
		t.tree.get_root().add_child(cam)
	cam.orbit(0.0, 0.0)
	var p0: Vector3 = cam.position
	var d0: float = cam.distance

	cam.orbit(60.0, 0.0)
	t.check(cam.position.distance_to(p0) > 1e-4, "orbit moves the camera")
	t.near(cam.distance, d0, "orbit preserves distance from target")

	cam.zoom(0.5)
	t.check(absf(cam.distance - d0 * 0.5) < 1e-6, "zoom(0.5) halves the distance", str(cam.distance))

	var tg0: Vector3 = cam.target
	cam.pan(50.0, 0.0)
	t.check(cam.target.distance_to(tg0) > 1e-4, "pan moves the target")

	cam.zoom(0.00001)
	t.check(cam.distance >= cam.min_distance - 1e-9, "zoom clamps to minimum distance", str(cam.distance))
	cam.zoom(100000.0)
	t.check(cam.distance <= cam.max_distance + 1e-9, "zoom clamps to maximum distance", str(cam.distance))

	cam.focus_on(Vector3(1, 0, 1), 2.0)
	t.check(cam.target.is_equal_approx(Vector3(1, 0, 1)), "focus_on sets the target")
	t.near(cam.distance, 2.0, "focus_on sets the distance")

	if t.tree != null and cam.is_inside_tree():
		cam.queue_free()
	t.done()
