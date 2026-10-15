extends RefCounted
## CircuitForge 3D - dense linear algebra helpers.
##
## Small, dependency-free routines used by the circuit solver. Matrices are plain
## GDScript arrays of arrays of floats. No scene-tree access happens here.

const PIVOT_EPS := 1e-12


## Solve A*x = b with Gaussian elimination and partial pivoting.
## Returns {"ok": bool, "x": Array, "error": String}.
static func solve(a_in: Array, b_in: Array) -> Dictionary:
	var n: int = b_in.size()
	if n == 0:
		return {"ok": true, "x": []}
	if a_in.size() != n:
		return {"ok": false, "error": "Matrix/vector size mismatch (%d vs %d)." % [a_in.size(), n]}

	# Work on copies so callers keep their data.
	var a := []
	for i in n:
		if a_in[i].size() != n:
			return {"ok": false, "error": "Matrix is not square at row %d." % i}
		a.append(a_in[i].duplicate())
	var b: Array = b_in.duplicate()

	for col in n:
		# Partial pivot: pick the row with the largest magnitude in this column.
		var piv := col
		var maxv: float = abs(a[col][col])
		for r in range(col + 1, n):
			var v: float = abs(a[r][col])
			if v > maxv:
				maxv = v
				piv = r
		if maxv < PIVOT_EPS:
			return {
				"ok": false,
				"error": "Singular matrix at column %d (zero pivot). The circuit likely has a floating node or conflicting ideal sources." % col,
				"singular_index": col,
			}
		if piv != col:
			var ta: Array = a[piv]
			a[piv] = a[col]
			a[col] = ta
			var tb: float = b[piv]
			b[piv] = b[col]
			b[col] = tb

		var d: float = a[col][col]
		for r in range(col + 1, n):
			var f: float = a[r][col] / d
			if f == 0.0:
				continue
			for c in range(col, n):
				a[r][c] -= f * a[col][c]
			b[r] -= f * b[col]

	# Back substitution.
	var x: Array = []
	x.resize(n)
	for i in range(n - 1, -1, -1):
		var s: float = b[i]
		for j in range(i + 1, n):
			s -= a[i][j] * x[j]
		x[i] = s / a[i][i]
	return {"ok": true, "x": x}
