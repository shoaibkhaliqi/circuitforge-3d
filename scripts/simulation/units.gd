extends RefCounted
## CircuitForge 3D - engineering-notation helpers.
##
## All internal values are SI base units (ohms, farads, henries, volts, amps,
## seconds, hertz). These helpers parse and format human-facing strings.

# SI prefixes. Note: 'm' = milli and 'M' = mega are deliberately distinct.
const PREFIXES := {
	"G": 1e9,
	"M": 1e6,
	"k": 1e3,
	"K": 1e3,
	"": 1.0,
	"m": 1e-3,
	"u": 1e-6,
	"µ": 1e-6,
	"n": 1e-9,
	"p": 1e-12,
}


## Parse an engineering-notation string into an SI value.
## Examples: "100" -> 100, "1k" -> 1000, "10kOhm" -> 10000,
## "100nF" -> 1e-7, "10uF" -> 1e-5, "1mH" -> 1e-3, "5V" -> 5, "20mA" -> 0.02.
static func parse(text) -> float:
	if typeof(text) == TYPE_FLOAT or typeof(text) == TYPE_INT:
		return float(text)
	var s := String(text).strip_edges()
	if s == "":
		return 0.0
	var n := s.length()
	var i := 0
	var num_str := ""
	while i < n:
		var ch := s[i]
		if (ch >= "0" and ch <= "9") or ch == "." or ch == "-" or ch == "+":
			num_str += ch
			i += 1
		elif (ch == "e" or ch == "E") and num_str != "":
			# Scientific notation exponent.
			num_str += ch
			i += 1
		else:
			break
	var suffix := s.substr(i).strip_edges()
	var value := float(num_str)
	if suffix == "":
		return value
	# Check explicit "meg" first so it is not read as milli + unit.
	if suffix.to_lower().begins_with("meg"):
		return value * 1e6
	var first := suffix.substr(0, 1)
	if PREFIXES.has(first):
		# Only treat the first character as a prefix when it is a known prefix
		# and there is a unit remainder OR the remainder is empty.
		return value * float(PREFIXES[first])
	return value


## Format an SI value using engineering notation with an optional unit suffix.
## 1000 -> "1 k", 0.02 -> "20 m", 1e-7 -> "100 n".
static func format(value: float, unit: String = "") -> String:
	if value == 0.0:
		return "0 %s" % unit
	var a: float = abs(value)
	var table := [
		[1e9, "G"], [1e6, "M"], [1e3, "k"], [1.0, ""],
		[1e-3, "m"], [1e-6, "u"], [1e-9, "n"], [1e-12, "p"],
	]
	for row in table:
		if a >= float(row[0]) * 0.999:
			return "%s %s%s" % [_sig(value / float(row[0])), String(row[1]), unit]
	return "%s p%s" % [_sig(value / 1e-12), unit]


static func _sig(v: float) -> String:
	var s := "%.4f" % v
	if s.contains("."):
		s = s.rstrip("0")
		if s.ends_with("."):
			s = s.substr(0, s.length() - 1)
	return s
