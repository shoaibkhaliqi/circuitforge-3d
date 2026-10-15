extends RefCounted
## CircuitForge 3D - union-find over electrical terminals.

var parent: Dictionary = {}


func add(x: String) -> void:
	if not parent.has(x):
		parent[x] = x


func find(x: String) -> String:
	add(x)
	var root := x
	while parent[root] != root:
		root = parent[root]
	# Path compression.
	var cur := x
	while parent[cur] != root:
		var nxt: String = parent[cur]
		parent[cur] = root
		cur = nxt
	return root


func union(a: String, b: String) -> void:
	var ra := find(a)
	var rb := find(b)
	if ra != rb:
		parent[rb] = ra


func connected(a: String, b: String) -> bool:
	return find(a) == find(b)


## Return {root: Array_of_members}.
func groups() -> Dictionary:
	var out := {}
	for k in parent:
		var r := find(k)
		if not out.has(r):
			out[r] = []
		out[r].append(k)
	return out
