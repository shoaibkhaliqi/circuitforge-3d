extends RefCounted
## Unit parsing / formatting tests.

const Units = preload("res://scripts/simulation/units.gd")


func run(t) -> void:
	t.section("Units - engineering notation parsing")
	t.near(Units.parse("100"), 100.0, "plain number")
	t.near(Units.parse("1k"), 1000.0, "1k = 1000")
	t.near(Units.parse("10k"), 10000.0, "10k = 10000")
	t.near(Units.parse("100kOhm"), 100000.0, "100kOhm = 100000")
	t.near(Units.parse("100nF"), 1e-7, "100nF = 1e-7 F")
	t.near(Units.parse("10uF"), 1e-5, "10uF = 1e-5 F")
	t.near(Units.parse("1mH"), 1e-3, "1mH = 1e-3 H")
	t.near(Units.parse("5V"), 5.0, "5V = 5")
	t.near(Units.parse("20mA"), 0.02, "20mA = 0.02 A")
	t.near(Units.parse("2.2meg"), 2.2e6, "2.2meg = 2.2e6")
	t.near(Units.parse("-3.3V"), -3.3, "negative voltage")

	t.section("Units - milli vs mega distinct")
	t.near(Units.parse("1m"), 1e-3, "1m (milli) = 1e-3")
	t.near(Units.parse("1M"), 1e6, "1M (mega) = 1e6")
	t.check(Units.parse("1m") != Units.parse("1M"), "milli and mega are not equal")

	t.section("Units - formatting")
	t.check(Units.format(1000.0, "Ohm") == "1 kOhm", "1000 -> '1 kOhm'", Units.format(1000.0, "Ohm"))
	t.check(Units.format(0.02, "A").begins_with("20 m"), "0.02 -> '20 m'", Units.format(0.02, "A"))
	t.check(Units.format(5.0, "V").begins_with("5 "), "5 -> '5 '", Units.format(5.0, "V"))
