extends RefCounted
## CircuitForge 3D - Modified Nodal Analysis matrix builder.
##
## Unknowns are ordered: [ v_node1 .. v_node(N-1), i_branch0 .. i_branch(M-1) ].
## Node 0 is the reference (ground) node and is not an unknown.

var num_nodes: int = 0        # includes the reference node at index 0
var num_branches: int = 0     # extra current unknowns (voltage sources, inductors)
var size: int = 0
var a: Array = []
var z: Array = []


func setup(n_nodes: int, n_branches: int) -> void:
	num_nodes = n_nodes
	num_branches = n_branches
	size = (n_nodes - 1) + n_branches
	a = []
	for i in size:
		var row := []
		row.resize(size)
		row.fill(0.0)
		a.append(row)
	z = []
	z.resize(size)
	z.fill(0.0)


func reset() -> void:
	for row in a:
		row.fill(0.0)
	z.fill(0.0)


## Add conductance g between nodes p and n. Node index 0 is ground and is skipped.
func add_g(p: int, n: int, g: float) -> void:
	if size == 0:
		return
	var ip := p - 1
	var im := n - 1
	if p > 0:
		a[ip][ip] += g
	if n > 0:
		a[im][im] += g
	if p > 0 and n > 0:
		a[ip][im] -= g
		a[im][ip] -= g


## Add a conductance to ground at node p (leakage / gmin). Node 0 is skipped.
func add_shunt(p: int, g: float) -> void:
	if size == 0 or p <= 0:
		return
	a[p - 1][p - 1] += g


## Inject current i into node p and draw it from node n (current source).
func add_i(p: int, n: int, i: float) -> void:
	if p > 0:
		z[p - 1] += i
	if n > 0:
		z[n - 1] -= i


## Create a branch (extra current unknown) incidence for voltage sources / inductors.
func add_branch(p: int, n: int, row: int) -> void:
	if p > 0:
		a[row][p - 1] += 1.0
		a[p - 1][row] += 1.0
	if n > 0:
		a[row][n - 1] -= 1.0
		a[n - 1][row] -= 1.0


func branch_extra(row: int, diag: float, rhs: float) -> void:
	a[row][row] += diag
	z[row] += rhs
