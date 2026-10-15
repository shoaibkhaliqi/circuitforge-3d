extends RefCounted
## Placement geometry tests.
##
## The breadboard's five-hole groups share one net, so a component's default
## pin placement must walk rows (not columns) or every pin would be shorted.

const BreadboardView = preload("res://scripts/breadboard/breadboard_view.gd")
const Breadboard = preload("res://scripts/breadboard/breadboard.gd")


func run(t) -> void:
	t.section("Placement - default holes never short a component")
	var view = BreadboardView.new()
	var bb = Breadboard.new(30)

	var r2 := view.default_holes("resistor", 2, "a5")
	t.check(r2.size() == 2, "resistor gets two holes", str(r2))
	t.check(bb.hole_net(r2[0]) != bb.hole_net(r2[1]),
		"resistor pins land on different nets", "%s vs %s" % [bb.hole_net(r2[0]), bb.hole_net(r2[1])])

	var g3 := view.default_holes("and", 3, "c10")
	t.check(g3.size() == 3, "3-pin gate gets three holes", str(g3))
	var nets := {}
	for h in g3:
		nets[bb.hole_net(h)] = true
	t.check(nets.size() == 3, "3-pin gate pins land on three distinct nets", str(nets.keys()))

	var rail := view.default_holes("resistor", 2, "TM1")
	t.check(bb.hole_net(rail[0]) != bb.hole_net(rail[1]),
		"rail-anchored part spans rail and terminal nets", "%s vs %s" % [bb.hole_net(rail[0]), bb.hole_net(rail[1])])

	t.section("Placement - near edge stays on the board")
	var edge := view.default_holes("resistor", 2, "a30")
	for h in edge:
		t.check(bb.is_valid_hole(h), "edge placement stays valid", h)

	t.section("Placement - ground is a single hole")
	var gnd := view.default_holes("ground", 1, "f7")
	t.check(gnd.size() == 1 and gnd[0] == "f7", "ground places on one hole", str(gnd))

	view.free()
	t.done()
