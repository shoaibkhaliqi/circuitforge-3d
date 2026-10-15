extends Control
## CircuitForge 3D - simulation-backed oscilloscope.
##
## Draws real recorded samples from the solver. Nothing here is synthesised:
## if there are no samples, nothing is drawn.

const CH_COLORS := [Color(0.3, 0.9, 0.4), Color(0.95, 0.8, 0.25), Color(0.4, 0.7, 1.0), Color(1.0, 0.4, 0.6)]

var waveforms: Dictionary = {}       # {"time": [], "series": {"name": [..]}}
var channels: Array = ["", "", "", ""]
var show_grid := true
var v_scale := 1.0
var v_offset := 0.0
var time_span := 0.0                 # 0 = auto (full range)


func set_waveforms(wf: Dictionary) -> void:
	waveforms = wf
	queue_redraw()


func set_channels(ch: Array) -> void:
	channels = ch
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.06, 0.07, 0.09))
	if show_grid:
		var grid := Color(0.18, 0.22, 0.28)
		for i in range(1, 10):
			var x := w * float(i) / 10.0
			draw_line(Vector2(x, 0), Vector2(x, h), grid, 1.0)
		for i in range(1, 8):
			var y := h * float(i) / 8.0
			draw_line(Vector2(0, y), Vector2(w, y), grid, 1.0)
		# Centre axes.
		draw_line(Vector2(0, h * 0.5), Vector2(w, h * 0.5), Color(0.35, 0.4, 0.5), 1.5)
	if waveforms.is_empty() or not waveforms.has("time") or waveforms.time.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(12, 22), "No samples - run a transient simulation.", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.6, 0.6, 0.6))
		return

	var time: Array = waveforms.time
	var t0: float = time[0]
	var t1: float = time[time.size() - 1]
	if time_span > 0.0:
		t1 = min(t1, t0 + time_span)
	if t1 <= t0:
		return

	# Vertical range.
	var vmax := 1.0
	var vmin := -1.0
	for ch in channels:
		if ch == "" or not waveforms.series.has(ch):
			continue
		for v in waveforms.series[ch]:
			vmax = max(vmax, float(v))
			vmin = min(vmin, float(v))
	if v_offset != 0.0:
		vmax += v_offset
		vmin += v_offset

	for ci in channels.size():
		var name: String = channels[ci] if ci < channels.size() else ""
		if name == "" or not waveforms.series.has(name):
			continue
		var series: Array = waveforms.series[name]
		var pts := PackedVector2Array()
		for i in series.size():
			var t: float = time[i]
			if t > t1:
				break
			var x := (t - t0) / (t1 - t0) * w
			var v: float = float(series[i])
			var y := h - (v - vmin) / (vmax - vmin) * h
			pts.append(Vector2(clampf(x, 0, w), clampf(y, 0, h)))
		if pts.size() >= 2:
			draw_polyline(pts, CH_COLORS[ci % CH_COLORS.size()], 1.8, true)

	# Legend and scale readout.
	var yy := 18.0
	for ci in channels.size():
		var name: String = channels[ci] if ci < channels.size() else ""
		if name == "":
			continue
		draw_string(ThemeDB.fallback_font, Vector2(8, yy), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, CH_COLORS[ci % CH_COLORS.size()])
		yy += 16
	draw_string(ThemeDB.fallback_font, Vector2(w - 190, h - 8),
		"t: %s s   V: %s .. %s" % [str(t1 - t0), str(vmin), str(vmax)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.7, 0.7))
