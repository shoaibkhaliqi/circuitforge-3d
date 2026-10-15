extends RefCounted
## Unit tests for the linear algebra helpers.

const LinAlg = preload("res://scripts/simulation/lin_alg.gd")


func run(t) -> void:
	t.section("LinAlg - linear solve")
	var r = LinAlg.solve([[2.0, 1.0], [1.0, 3.0]], [5.0, 10.0])
	t.check(r.ok, "2x2 solve succeeds")
	# 2x + y = 5 ; x + 3y = 10  -> x = 1, y = 3
	t.near(r.x[0], 1.0, "2x2 solution x=1")
	t.near(r.x[1], 3.0, "2x2 solution y=3")

	var r2 = LinAlg.solve([[0.0, 1.0], [1.0, 0.0]], [4.0, 7.0])
	t.check(r2.ok, "pivoting required but succeeds")
	t.near(r2.x[0], 7.0, "pivoted x=7")
	t.near(r2.x[1], 4.0, "pivoted y=4")

	var r3 = LinAlg.solve([[1.0, 2.0], [2.0, 4.0]], [3.0, 6.0])
	t.check(not r3.ok, "singular matrix is detected", r3.get("error", ""))

	var r4 = LinAlg.solve([[3.0]], [9.0])
	t.near(r4.x[0], 3.0, "1x1 solve")
	t.done()
