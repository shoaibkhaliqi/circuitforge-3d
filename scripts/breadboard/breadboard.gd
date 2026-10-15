extends RefCounted
## CircuitForge 3D - virtual solderless breadboard topology.
##
## Models the electrical graph of the board, NOT its appearance:
##   * Terminal holes are labelled <column><row>, columns a..e (top half) and
##     f..j (bottom half), rows 1..rows.
##   * The five holes of one row within one half (a-e or f-j) form one node.
##   * The centre channel (gap between e and f) separates the two halves, so a-e
##     and f-j of the same row are never connected.
##   * Four power rails: TP (top +), TM (top -), BP (bottom +), BM (bottom -).
##     Rail holes are labelled TP<row> etc. Rails run the full length, or are
##     split at the midpoint when rail_split is enabled.
##
## Electrical connection between two nets is only ever created by a wire or by
## placing two component pins in the same node. Graphical proximity means nothing.

const HALF_A := ["a", "b", "c", "d", "e"]
const HALF_B := ["f", "g", "h", "i", "j"]
const RAIL_PREFIXES := ["TP", "TM", "BP", "BM"]

var rows: int = 30
var rail_split: bool = false


func _init(p_rows: int = 30, p_split: bool = false) -> void:
	rows = p_rows
	rail_split = p_split


## Is `hole` a valid hole id on this board?
func is_valid_hole(hole) -> bool:
	if typeof(hole) != TYPE_STRING or hole == "":
		return false
	var prefix: String = hole.substr(0, 2)
	if RAIL_PREFIXES.has(prefix):
		var r := int(hole.substr(2))
		return r >= 1 and r <= rows
	if hole.length() < 2:
		return false
	var col: String = hole.substr(0, 1)
	var row := int(hole.substr(1))
	if not (HALF_A.has(col) or HALF_B.has(col)):
		return false
	return row >= 1 and row <= rows


## Net name for a hole. Two holes sharing a net name are electrically connected.
func hole_net(hole) -> String:
	if not is_valid_hole(hole):
		return ""
	var prefix: String = hole.substr(0, 2)
	if RAIL_PREFIXES.has(prefix):
		var r := int(hole.substr(2))
		if rail_split:
			var half := 1 if r <= int(rows / 2) else 2
			return "%s.%d" % [prefix, half]
		return prefix
	var col: String = hole.substr(0, 1)
	var row := int(hole.substr(1))
	var side := "A" if HALF_A.has(col) else "B"
	return "%s%d" % [side, row]


func all_holes() -> Array:
	var out := []
	for r in range(1, rows + 1):
		for c in HALF_A:
			out.append("%s%d" % [c, r])
		for c in HALF_B:
			out.append("%s%d" % [c, r])
	for p in RAIL_PREFIXES:
		for r in range(1, rows + 1):
			out.append("%s%d" % [p, r])
	return out


## Groups of hole ids that are physically connected.
func net_groups() -> Dictionary:
	var groups := {}
	for h in all_holes():
		var n := hole_net(h)
		if not groups.has(n):
			groups[n] = []
		groups[n].append(h)
	return groups


## All net names defined by the board itself.
func net_names() -> Array:
	return net_groups().keys()
