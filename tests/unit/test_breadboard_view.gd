extends RefCounted
## Breadboard view (3D) tests.
##
## The hole MultiMesh carries one colour per hole: that is how the pointer's
## electrical-net highlight works. These tests verify the colour contract so a
## highlight bug can never silently show the wrong net.

const BBV = preload("res://scripts/breadboard/breadboard_view.gd")


func run(t) -> void:
	t.section("Breadboard view - per-hole colour highlight")
	var bb = BBV.new()
	bb.rows = 10
	bb.build(10, false)
	t.check(bb._mm != null, "the hole instancer exists after build")
	t.check(bb.hole_positions.has("a1") and bb.hole_positions.has("j10"),
		"holePositions cover the whole board")

	# a1..e1 form one terminal strip: highlight it all, with c1 as the pointed hole.
	var strip := []
	for c in ["a", "b", "c", "d", "e"]:
		strip.append(c + "1")
	bb.set_highlight(strip, ["c1"])
	var idx_a1: int = bb._hole_order.find("a1")
	var idx_a2: int = bb._hole_order.find("a2")
	var idx_c1: int = bb._hole_order.find("c1")
	var idx_f1: int = bb._hole_order.find("f1")
	t.check(bb.instance_colors[idx_a1] == BBV.HOLE_ACCENT,
		"holes in the highlighted net get the accent colour")
	t.check(bb.instance_colors[idx_f1] == BBV.HOLE_COLOR,
		"holes outside the net (other half) keep the base colour")
	t.check(bb.instance_colors[idx_c1] == BBV.HOLE_STRONG,
		"the pointed hole itself gets the strong colour")

	bb.set_highlight([], [])
	t.check(bb.instance_colors[idx_a2] == BBV.HOLE_COLOR,
		"a reset restores the plain board look")

	bb.free()
	t.done()
