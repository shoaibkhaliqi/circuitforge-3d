extends RefCounted
## CircuitForge 3D - builds recognisable 3D visuals for components.
##
## Models are procedural (no external assets) and built from primitives, so they
## stay lightweight and depend only on the component definition. A visual is
## decorative: it never carries electrical meaning. Pin positions come from the
## breadboard holes, so a model always lines up with its real terminals.
##
## The body shape is chosen from the definition's `model.shape` (see
## docs/catalog/schema.md); the detailed hand-tuned models for the core
## electrical types take precedence so their live state (LED brightness, switch
## lever, resistor colour code) keeps working.
##
## `info` may carry live data used for informative visuals:
##   {"params": {...}, "current": float (A), "voltage": float (V),
##    "state": {...}}   # e.g. {"closed": true}

const Design = preload("res://scripts/ui/design.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")

const TYPE_COLORS := {
	"resistor": Color(0.84, 0.78, 0.62),
	"capacitor": Color(0.86, 0.55, 0.20),
	"inductor": Color(0.20, 0.22, 0.26),
	"potentiometer": Color(0.20, 0.34, 0.62),
	"vsource": Color(0.80, 0.24, 0.24),
	"isource": Color(0.85, 0.60, 0.20),
	"ground": Color(0.22, 0.23, 0.26),
	"switch": Color(0.30, 0.32, 0.36),
	"led": Color(0.90, 0.25, 0.30),
	"diode": Color(0.12, 0.12, 0.14),
	"zener": Color(0.14, 0.14, 0.18),
}

const METAL := Color(0.78, 0.80, 0.84)
const LEAD := Color(0.86, 0.87, 0.90)
const BODY_BLACK := Color(0.10, 0.10, 0.12)
const PCB_GREEN := Color(0.12, 0.42, 0.28)
const PCB_BLUE := Color(0.10, 0.26, 0.44)
const HEADER_BLACK := Color(0.08, 0.08, 0.10)

static var _mats := {}


static func _material(color: Color, roughness: float = 0.55, metallic: float = 0.0, emission: float = 0.0) -> StandardMaterial3D:
	var key := "%s_%.2f_%.2f_%.2f" % [color.to_html(), roughness, metallic, emission]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	_mats[key] = m
	return m


# --- primitive helpers ------------------------------------------------------

static func _add(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO, scale: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.scale = scale
	parent.add_child(mi)
	return mi


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


static func _cyl(radius: float, height: float, segments: int = 20) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = height
	c.radial_segments = segments
	c.rings = 1
	return c


static func _sphere(radius: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	s.radial_segments = 20
	s.rings = 12
	return s


static func _torus(inner: float, outer: float) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	return t


# --- resistor colour code ---------------------------------------------------

const DIGIT_COLORS := [
	Color(0.06, 0.06, 0.06), # 0 black
	Color(0.42, 0.26, 0.12), # 1 brown
	Color(0.80, 0.12, 0.12), # 2 red
	Color(0.92, 0.45, 0.10), # 3 orange
	Color(0.92, 0.85, 0.20), # 4 yellow
	Color(0.15, 0.60, 0.25), # 5 green
	Color(0.15, 0.30, 0.85), # 6 blue
	Color(0.55, 0.20, 0.70), # 7 violet
	Color(0.55, 0.55, 0.58), # 8 grey
	Color(0.95, 0.95, 0.95), # 9 white
]


static func _multiplier_color(exp: int) -> Color:
	match exp:
		-2:
			return Color(0.75, 0.76, 0.78)   # silver
		-1:
			return Color(0.83, 0.68, 0.22)   # gold
		_:
			return DIGIT_COLORS[clampi(exp, 0, 9)]


## Return the four band colours (d1, d2, multiplier, tolerance) for a value.
static func resistor_bands(value: float) -> Array:
	if value <= 0.0:
		return []
	var exp := int(floor(log(value) / log(10.0)))
	var mant := value / pow(10.0, exp)
	var d1 := int(floor(mant))
	var d2 := int(round((mant - float(d1)) * 10.0))
	if d2 >= 10:
		d2 = 0
		d1 += 1
	if d1 >= 10:
		d1 = 9
	return [DIGIT_COLORS[clampi(d1, 0, 9)], DIGIT_COLORS[clampi(d2, 0, 9)],
			_multiplier_color(exp - 1), Color(0.83, 0.68, 0.22)]


# --- main entry -------------------------------------------------------------

static func build(type: String, pin_positions: Array, selected: bool = false, info: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.name = "Visual"

	# A frame at the mid-point of the pins with local +Z along pin0 -> pinN.
	var has_axis := pin_positions.size() >= 2
	var frame := Node3D.new()
	var span := 0.12
	var mid := Vector3.ZERO
	var axis := Vector3.FORWARD
	if has_axis:
		var a: Vector3 = pin_positions[0]
		var b: Vector3 = pin_positions[pin_positions.size() - 1]
		mid = (a + b) * 0.5
		axis = (b - a).normalized()
		if axis.length() < 1e-5:
			axis = Vector3.FORWARD
		var ref := Vector3.UP
		if absf(axis.dot(ref)) > 0.98:
			ref = Vector3.RIGHT
		var xaxis := ref.cross(axis).normalized()
		var yaxis := axis.cross(xaxis).normalized()
		frame.transform = Transform3D(Basis(xaxis, yaxis, axis), mid)
		span = a.distance_to(b)
	else:
		mid = pin_positions[0] if pin_positions.size() > 0 else Vector3.ZERO
		frame.position = mid
	root.add_child(frame)

	# Every pin's position along the frame axis, used so each terminal gets a real
	# lead instead of only the two outer ones. (frame.to_local() can't be used
	# here: the nodes aren't in the SceneTree yet.)
	var pin_along := []
	for p in pin_positions:
		pin_along.append((p - mid).dot(axis))

	_build_body(type, frame, span, pin_along, info)

	# Silver pin pads at the real terminal locations.
	for p in pin_positions:
		_add(root, _cyl(0.011, 0.02, 12), _material(METAL, 0.35, 0.6), Vector3(p.x, p.y + 0.009, p.z))

	if selected:
		_add(frame, _box(Vector3(0.11, 0.004, span + 0.05)) as Mesh, _material(Design.ACCENT, 0.4, 0.0, 1.2), Vector3(0, -0.012, 0))

	# Value / measurement label.
	if pin_positions.size() >= 1:
		var lbl := Label3D.new()
		lbl.text = ""
		lbl.name = "ValueLabel"
		lbl.font_size = 22
		lbl.pixel_size = 0.0009
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.modulate = Color(1, 1, 1)
		lbl.outline_size = 4
		lbl.outline_modulate = Color(0, 0, 0, 0.85)
		var c := Vector3.ZERO
		for p in pin_positions:
			c += p
		c /= max(1, pin_positions.size())
		lbl.position = c + Vector3(0, 0.16, 0)
		root.add_child(lbl)
	return root


# --- per-type models --------------------------------------------------------

static func _build_body(type: String, frame: Node3D, span: float, pin_along: Array, info: Dictionary) -> void:
	var params: Dictionary = info.get("params", {})
	match type:
		"resistor":
			_body_resistor(frame, span, pin_along, float(params.get("r", 1000.0)))
		"capacitor":
			_body_capacitor(frame, span, pin_along)
		"inductor":
			_body_inductor(frame, span, pin_along)
		"potentiometer":
			_body_potentiometer(frame, span, pin_along)
		"vsource":
			_body_source(frame, span, pin_along, true)
		"isource":
			_body_source(frame, span, pin_along, false)
		"ground":
			_body_ground(frame)
		"switch":
			_body_switch(frame, span, pin_along, bool(info.get("state", {}).get("closed", params.get("closed", false))))
		"led":
			_body_led(frame, span, pin_along, float(info.get("current", 0.0)))
		"diode":
			_body_diode(frame, span, pin_along, false)
		"zener":
			_body_diode(frame, span, pin_along, true)
		"and", "or", "not", "nand", "nor", "xor", "buffer":
			_body_logic(frame, span, pin_along, type)
		_:
			_body_by_shape(type, frame, span, pin_along)


# --- leads ------------------------------------------------------------------

## Draw a silver lead from the body end to every pin that sticks out past it.
## Falls back to the two outer leads when no per-pin data is available.
static func _leads(frame: Node3D, span: float, body_len: float, pin_along: Array = []) -> void:
	var half := body_len * 0.5
	if pin_along.is_empty():
		var h := span * 0.5
		var lead_len := maxf((span - body_len) * 0.5, 0.004)
		_add(frame, _cyl(0.006, lead_len, 10), _material(LEAD, 0.35, 0.7), Vector3(0, 0, -h + lead_len * 0.5), Vector3(90, 0, 0))
		_add(frame, _cyl(0.006, lead_len, 10), _material(LEAD, 0.35, 0.7), Vector3(0, 0, h - lead_len * 0.5), Vector3(90, 0, 0))
		return
	for z in pin_along:
		var zf := float(z)
		if absf(zf) <= half + 0.0005:
			continue
		var start := signf(zf) * half
		var length := absf(zf) - half
		_add(frame, _cyl(0.006, maxf(length, 0.004), 10), _material(LEAD, 0.35, 0.7),
				Vector3(0, 0, (start + zf) * 0.5), Vector3(90, 0, 0))


# --- core type bodies -------------------------------------------------------

static func _body_resistor(frame: Node3D, span: float, pin_along: Array, value: float) -> void:
	# Real 1/4 W axial proportions (pitch 0.1 == 2.54 mm): a ~10 mm body floats
	# above the board, taller than the hole span, with leads dropping at the
	# two holes - exactly how a resistor breadboards.
	var body_len := maxf(span * 1.15, 0.22)
	var radius := 0.044
	_add(frame, _cyl(radius, body_len, 20), _material(TYPE_COLORS["resistor"], 0.5), Vector3(0, radius, 0), Vector3(90, 0, 0))
	for z in pin_along:
		var zf := float(z)
		_add(frame, _cyl(0.007, radius, 10), _material(LEAD, 0.35, 0.7), Vector3(0, radius * 0.5, zf), Vector3(0, 0, -90))
	var bands := resistor_bands(value)
	for i in bands.size():
		var t := -body_len * 0.30 + float(i) * body_len * 0.20
		_add(frame, _cyl(radius + 0.0025, body_len * 0.055, 20), _material(bands[i], 0.45), Vector3(0, radius, t), Vector3(90, 0, 0))


static func _body_capacitor(frame: Node3D, span: float, pin_along: Array) -> void:
	var body_len := maxf(span * 0.5, 0.045)
	# Ceramic disc standing on edge between the two holes, coated tan.
	_leads(frame, span, 0.02, pin_along)
	_add(frame, _cyl(0.044, 0.018, 24), _material(TYPE_COLORS["capacitor"], 0.5), Vector3(0, 0.047, 0), Vector3(0, 0, 90))
	_add(frame, _cyl(0.0455, 0.003, 24), _material(Color(0.55, 0.30, 0.08), 0.5), Vector3(0, 0.047, 0), Vector3(0, 0, 90))


static func _body_inductor(frame: Node3D, span: float, pin_along: Array) -> void:
	var body_len := maxf(span * 0.66, 0.05)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _cyl(0.016, body_len, 16), _material(Color(0.10, 0.11, 0.13), 0.5), Vector3(0, 0.016, 0), Vector3(90, 0, 0))
	var coils := 5
	for i in coils:
		var t := -body_len * 0.36 + float(i) * (body_len * 0.72 / float(coils - 1))
		_add(frame, _torus(0.017, 0.021), _material(Color(0.72, 0.42, 0.18), 0.4, 0.7), Vector3(0, 0.016, t), Vector3(90, 0, 0))


## Small two-lead sensing bead (thermistor, LDR, RTD probe).
static func _body_bead(frame: Node3D, span: float, pin_along: Array, color: Color) -> void:
	var body_len := maxf(span * 0.5, 0.05)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _sphere(0.02), _material(color, 0.45), Vector3(0, 0.024, 0), Vector3.ZERO, Vector3(1.0, 0.9, 1.0))


## Two-lead motor / actuator bodies: brushed motor, vibration motor, solenoid, fan.
static func _body_motor(frame: Node3D, span: float, pin_along: Array, style: String) -> void:
	var body_len := maxf(span * 0.55, 0.06)
	_leads(frame, span, body_len * 0.6, pin_along)
	if style == "fan":
		_add(frame, _box(Vector3(0.07, 0.03, body_len)), _material(Color(0.16, 0.16, 0.18), 0.5), Vector3(0, 0.016, 0))
		_add(frame, _cyl(0.022, 0.02, 20), _material(Color(0.10, 0.10, 0.12), 0.5), Vector3(0, 0.031, 0))
		return
	if style == "solenoid":
		_add(frame, _cyl(0.024, body_len, 20), _material(Color(0.35, 0.30, 0.22), 0.5), Vector3(0, 0.024, 0), Vector3(90, 0, 0))
		_add(frame, _cyl(0.010, body_len * 0.4, 14), _material(METAL, 0.3, 0.7), Vector3(0, 0.024, body_len * 0.55), Vector3(90, 0, 0))
		return
	var radius := 0.022 if style == "vibration" else 0.03
	_add(frame, _cyl(radius, body_len, 20), _material(Color(0.55, 0.55, 0.58), 0.4), Vector3(0, radius, 0), Vector3(90, 0, 0))
	_add(frame, _cyl(radius * 0.35, body_len * 0.15, 12), _material(METAL, 0.3, 0.7), Vector3(0, radius, body_len * 0.55), Vector3(90, 0, 0))


static func _body_potentiometer(frame: Node3D, span: float, pin_along: Array) -> void:
	var body_len := maxf(span * 0.6, 0.06)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(0.05, 0.045, body_len)), _material(TYPE_COLORS["potentiometer"], 0.5), Vector3(0, 0.024, 0))
	_add(frame, _cyl(0.016, 0.02, 20), _material(Color(0.12, 0.12, 0.14), 0.4), Vector3(0, 0.052, 0))
	_add(frame, _box(Vector3(0.006, 0.02, body_len * 0.7)), _material(Color(0.85, 0.85, 0.88), 0.3, 0.5), Vector3(0, 0.062, 0))


static func _body_source(frame: Node3D, span: float, pin_along: Array, is_voltage: bool) -> void:
	var body_len := maxf(span * 0.62, 0.05)
	_leads(frame, span, body_len, pin_along)
	if is_voltage:
		_add(frame, _cyl(0.020, body_len, 20), _material(Color(0.18, 0.19, 0.22), 0.5), Vector3(0, 0.020, 0), Vector3(90, 0, 0))
		_add(frame, _cyl(0.0205, body_len * 0.4, 20), _material(Color(0.78, 0.22, 0.22), 0.5), Vector3(0, 0.020, -body_len * 0.3), Vector3(90, 0, 0))
		_add(frame, _cyl(0.008, 0.02, 12), _material(METAL, 0.3, 0.6), Vector3(0, 0.020, -body_len * 0.5), Vector3(90, 0, 0))
	else:
		_add(frame, _box(Vector3(0.05, 0.05, body_len)), _material(TYPE_COLORS["isource"], 0.5), Vector3(0, 0.026, 0))
		_add(frame, _cyl(0.012, 0.006, 16), _material(Color(0.15, 0.15, 0.15), 0.4), Vector3(0, 0.055, 0))


static func _body_ground(frame: Node3D) -> void:
	_add(frame, _cyl(0.008, 0.05, 12), _material(LEAD, 0.35, 0.7), Vector3(0, 0.025, 0))
	_add(frame, _box(Vector3(0.06, 0.006, 0.014)), _material(Color(0.15, 0.15, 0.17), 0.4), Vector3(0, 0.052, 0))
	_add(frame, _box(Vector3(0.04, 0.006, 0.014)), _material(Color(0.15, 0.15, 0.17), 0.4), Vector3(0, 0.062, 0))
	_add(frame, _box(Vector3(0.02, 0.006, 0.014)), _material(Color(0.15, 0.15, 0.17), 0.4), Vector3(0, 0.072, 0))


static func _body_switch(frame: Node3D, span: float, pin_along: Array, closed: bool) -> void:
	var body_len := maxf(span * 0.6, 0.05)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(0.05, 0.03, body_len)), _material(Color(0.16, 0.17, 0.20), 0.5), Vector3(0, 0.015, 0))
	_add(frame, _cyl(0.006, 0.03, 12), _material(METAL, 0.3, 0.6), Vector3(0.012, 0.02, -body_len * 0.3))
	_add(frame, _cyl(0.006, 0.03, 12), _material(METAL, 0.3, 0.6), Vector3(0.012, 0.02, body_len * 0.3))
	if closed:
		_add(frame, _box(Vector3(0.01, 0.008, body_len * 0.6)), _material(METAL, 0.3, 0.7), Vector3(0.012, 0.03, 0))
	else:
		_add(frame, _box(Vector3(0.01, 0.008, body_len * 0.5)), _material(METAL, 0.3, 0.7), Vector3(0.02, 0.045, -body_len * 0.12), Vector3(28, 0, 0))


static func _body_led(frame: Node3D, span: float, pin_along: Array, current: float) -> void:
	var body_len := maxf(span * 0.6, 0.05)
	_leads(frame, span, body_len, pin_along)
	var lit := current > 1e-4
	var base_col := Color(0.85, 0.15, 0.18)
	var emission := 0.0
	if lit:
		emission = clampf(1.0 + current * 40.0, 1.0, 3.0)
	# Real 5mm LED proportions (one pitch = 2.54 mm): flange at the board,
	# ~4 mm straight barrel, hemispherical dome, flat side marking the cathode.
	_add(frame, _cyl(0.115, 0.007, 24), _material(base_col, 0.35, 0.0, emission * 0.5), Vector3(0, 0.0035, 0))
	_add(frame, _cyl(0.088, 0.155, 24), _material(base_col, 0.30, 0.0, emission * 0.7), Vector3(0, 0.0845, 0))
	_add(frame, _sphere(0.088), _material(base_col.lerp(Color(1, 1, 1), 0.2 if lit else 0.0), 0.25, 0.0, emission),
			Vector3(0, 0.162, 0), Vector3.ZERO, Vector3(1, 0.6, 1))
	_add(frame, _box(Vector3(0.006, 0.14, 0.05)), _material(Color(0.42, 0.05, 0.06), 0.4), Vector3(0.084, 0.095, 0))


static func _body_diode(frame: Node3D, span: float, pin_along: Array, is_zener: bool) -> void:
	var body_len := maxf(span * 0.62, 0.05)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _cyl(0.016, body_len, 20), _material(Color(0.12, 0.12, 0.14), 0.5), Vector3(0, 0.016, 0), Vector3(90, 0, 0))
	var band_col := Color(0.85, 0.85, 0.88) if not is_zener else Color(0.25, 0.55, 0.95)
	_add(frame, _cyl(0.017, body_len * 0.12, 20), _material(band_col, 0.45), Vector3(0, 0.016, body_len * 0.32), Vector3(90, 0, 0))
	if is_zener:
		_add(frame, _box(Vector3(0.02, 0.004, 0.006)), _material(band_col, 0.4), Vector3(0, 0.032, body_len * 0.32))


static func _body_logic(frame: Node3D, span: float, pin_along: Array, type: String) -> void:
	var body_len := maxf(span * 0.7, 0.06)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(0.06, 0.022, body_len)), _material(BODY_BLACK, 0.5), Vector3(0, 0.013, 0))
	_add(frame, _cyl(0.005, 0.004, 10), _material(Color(0.5, 0.5, 0.55), 0.4), Vector3(-0.022, 0.025, -body_len * 0.35))
	var mark := Label3D.new()
	lbl_setup(mark, type.substr(0, 3).to_upper())
	mark.position = Vector3(0, 0.04, 0)
	frame.add_child(mark)


static func lbl_setup(lbl: Label3D, text: String) -> void:
	lbl.text = text
	lbl.font_size = 28
	lbl.pixel_size = 0.00028
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = Color(0.9, 0.9, 0.95)
	lbl.outline_size = 4
	lbl.outline_modulate = Color(0, 0, 0, 0.8)


# --- shape-driven package bodies (catalog parts) ----------------------------

## Keyword hints used to pick a plausible package for catalog shapes we don't
## model by hand. Order matters: a developer board wins over a generic module.
const BOARD_HINTS := [
	"uno", "nano", "mega", "micro", "pro_mini", "pico", "bluepill", "blackpill", "teensy",
	"xiao", "digispark", "pi_", "zero_2w", "tv_", "phone", "tablet", "esp32_devkit",
]
const MODULE_HINTS := [
	"module", "breakout", "sensor", "probe", "hcsr04", "dht", "oled", "lcd", "tft", "epaper",
	"max7219", "shield", "nodemcu", "esp", "nrf", "lora", "sim800", "pir", "flow", "acs712",
	"level_shifter", "relay", "bridge", "boost", "buck", "dc_dc", "mb102", "uln2003",
	"stepper_driver", "otg", "usb", "y_cable", "capture", "ds18b20", "rtd", "load_cell",
	"h_bridge", "socket", "header", "matrix", "adapter", "terminal_block",
]


static func _matches(shape: String, hints: Array) -> bool:
	for h in hints:
		if shape.contains(h):
			return true
	return false


static func _short_label(type: String) -> String:
	var def := ComponentDB.get_def(type)
	var s := String(def.get("part_number", ""))
	if s == "":
		s = String(def.get("name", ""))
	if s == "":
		s = type
	if s.length() > 10:
		s = s.substr(0, 10)
	return s.to_upper()


static func _body_by_shape(type: String, frame: Node3D, span: float, pin_along: Array) -> void:
	var def := ComponentDB.get_def(type)
	var shape := ""
	if def.has("model"):
		var m = def.model
		if typeof(m) == TYPE_DICTIONARY:
			shape = String(m.get("shape", ""))
	var label := _short_label(type)

	match shape:
		"to92":
			_body_to92(frame, span, pin_along)
		"to220", "to247":
			_body_to220(frame, span, pin_along)
		"sot223":
			_body_sot223(frame, span, pin_along)
		"servo", "servo_large":
			_body_servo(frame, span, pin_along, shape)
		"electrolytic_can":
			_body_electrolytic(frame, span, pin_along, false)
		"supercap_can":
			_body_electrolytic(frame, span, pin_along, true)
		"seven_segment":
			_body_seven_segment(frame, span, pin_along)
		"ws2812", "led_5mm", "led_dome", "rgb_led":
			_body_led_package(frame, span, pin_along, def)
		"thermistor", "ntc_bead", "bead_thermistor":
			_body_bead(frame, span, pin_along, BODY_BLACK)
		"ldr", "photoresistor", "ldr_disc":
			_body_bead(frame, span, pin_along, Color(0.78, 0.75, 0.55))
		"rtd_probe":
			_body_bead(frame, span, pin_along, Color(0.72, 0.74, 0.78))
		"dc_motor", "dc_gearmotor_tt", "motor":
			_body_motor(frame, span, pin_along, "dc")
		"vibration_motor":
			_body_motor(frame, span, pin_along, "vibration")
		"solenoid", "solenoid_valve":
			_body_motor(frame, span, pin_along, "solenoid")
		"fan":
			_body_motor(frame, span, pin_along, "fan")
		_:
			if shape.begins_with("dip") or shape.begins_with("dip_socket"):
				_body_dip(frame, span, pin_along, label)
			elif _matches(shape, BOARD_HINTS):
				_body_board(frame, span, pin_along, label, type)
			elif _matches(shape, MODULE_HINTS) or pin_along.size() >= 6:
				_body_module(frame, span, pin_along, label, PCB_GREEN)
			else:
				_body_generic(frame, span, pin_along, TYPE_COLORS.get(type, Color(0.6, 0.6, 0.6)))


static func _body_dip(frame: Node3D, span: float, pin_along: Array, label: String) -> void:
	var body_len := maxf(span * 0.42, maxf(float(pin_along.size()) * 0.02, 0.06))
	var width := 0.085
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(width, 0.024, body_len)), _material(BODY_BLACK, 0.5), Vector3(0, 0.014, 0))
	# pin-1 dimple and end notch
	_add(frame, _cyl(0.006, 0.004, 14), _material(Color(0.32, 0.32, 0.37), 0.4), Vector3(-0.022, 0.028, -body_len * 0.5 + 0.014))
	_add(frame, _cyl(0.007, 0.026, 14), _material(Color(0.16, 0.16, 0.19), 0.5), Vector3(0, 0.004, -body_len * 0.5 - 0.004), Vector3(90, 0, 0))
	var mark := Label3D.new()
	lbl_setup(mark, label)
	mark.position = Vector3(0, 0.045, 0)
	frame.add_child(mark)


static func _body_to92(frame: Node3D, span: float, pin_along: Array) -> void:
	var body_len := maxf(span * 0.4, 0.04)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _sphere(0.02), _material(BODY_BLACK, 0.5), Vector3(0, 0.022, 0), Vector3.ZERO, Vector3(1.0, 1.0, 1.1))
	_add(frame, _box(Vector3(0.026, 0.024, 0.03)), _material(BODY_BLACK, 0.5), Vector3(0, 0.014, 0))


static func _body_to220(frame: Node3D, span: float, pin_along: Array) -> void:
	var body_len := maxf(span * 0.4, 0.05)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(0.05, 0.03, body_len)), _material(BODY_BLACK, 0.5), Vector3(0, 0.02, 0))
	_add(frame, _box(Vector3(0.044, 0.05, 0.004)), _material(METAL, 0.3, 0.7), Vector3(0, 0.03, -body_len * 0.5 - 0.003))


static func _body_sot223(frame: Node3D, span: float, pin_along: Array) -> void:
	var body_len := maxf(span * 0.4, 0.04)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(0.04, 0.012, body_len)), _material(BODY_BLACK, 0.5), Vector3(0, 0.008, 0))
	_add(frame, _box(Vector3(0.05, 0.004, 0.03)), _material(METAL, 0.3, 0.7), Vector3(0, 0.002, -body_len * 0.2))


static func _body_servo(frame: Node3D, span: float, pin_along: Array, shape: String) -> void:
	var body_len := maxf(span * 0.5, 0.05)
	var big := shape == "servo_large"
	var w := 0.05 if not big else 0.07
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(w, 0.04, body_len)), _material(Color(0.15, 0.18, 0.42), 0.5), Vector3(0, 0.02, 0))
	_add(frame, _box(Vector3(w * 0.8, 0.06, body_len * 0.3)), _material(Color(0.18, 0.20, 0.46), 0.5), Vector3(0, 0.06, -body_len * 0.2))
	_add(frame, _cyl(0.012, 0.01, 16), _material(Color(0.9, 0.9, 0.92), 0.4), Vector3(0, 0.095, -body_len * 0.2))
	_add(frame, _box(Vector3(0.008, 0.006, body_len * 0.5)), _material(Color(0.85, 0.85, 0.88), 0.4), Vector3(0, 0.098, -body_len * 0.2 + 0.02))


static func _body_seven_segment(frame: Node3D, span: float, pin_along: Array) -> void:
	var body_len := maxf(span * 0.55, 0.12)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(0.06, 0.028, body_len)), _material(Color(0.10, 0.10, 0.12), 0.5), Vector3(0, 0.014, 0))
	# recessed light face so unlit segments stay crisp against it
	_add(frame, _box(Vector3(0.042, 0.004, body_len * 0.8)), _material(Color(0.03, 0.03, 0.04), 0.6), Vector3(0, 0.029, 0))
	var seg_mat := _material(Color(0.80, 0.12, 0.12), 0.4, 0.0, 0.7)
	var hz := body_len * 0.4
	_add(frame, _box(Vector3(0.026, 0.004, 0.005)), seg_mat, Vector3(0, 0.031, -hz))     # a
	_add(frame, _box(Vector3(0.026, 0.004, 0.005)), seg_mat, Vector3(0, 0.031, 0.0))     # g
	_add(frame, _box(Vector3(0.026, 0.004, 0.005)), seg_mat, Vector3(0, 0.031, hz))      # d
	_add(frame, _box(Vector3(0.005, 0.004, 0.024)), seg_mat, Vector3(-0.013, 0.031, -hz * 0.5))  # f
	_add(frame, _box(Vector3(0.005, 0.004, 0.024)), seg_mat, Vector3(0.013, 0.031, -hz * 0.5))   # b
	_add(frame, _box(Vector3(0.005, 0.004, 0.024)), seg_mat, Vector3(-0.013, 0.031, hz * 0.5))   # e
	_add(frame, _box(Vector3(0.005, 0.004, 0.024)), seg_mat, Vector3(0.013, 0.031, hz * 0.5))    # c
	_add(frame, _box(Vector3(0.005, 0.004, 0.005)), seg_mat, Vector3(0.014, 0.031, hz * 1.07))   # dp


## Radial electrolytic / supercap can standing between its two holes: shrink
## sleeve, metal top with the vent impression, printed minus stripe.
static func _body_electrolytic(frame: Node3D, span: float, pin_along: Array, big: bool) -> void:
	_leads(frame, span, 0.0, pin_along)
	var r := 0.055 if not big else 0.075
	var h := 0.09 if not big else 0.14
	_add(frame, _cyl(r, h, 24), _material(Color(0.09, 0.10, 0.14), 0.45), Vector3(0, h * 0.5 + 0.004, 0))
	_add(frame, _cyl(r * 0.96, 0.004, 24), _material(METAL, 0.3, 0.7), Vector3(0, h + 0.004, 0))
	_add(frame, _box(Vector3(r * 1.3, 0.002, 0.005)), _material(Color(0.30, 0.32, 0.34), 0.4), Vector3(0, h + 0.002, 0))
	_add(frame, _box(Vector3(0.010, h * 0.6, 0.014)), _material(Color(0.88, 0.88, 0.9), 0.5), Vector3(r * 0.93, h * 0.55, 0))


static func _body_led_package(frame: Node3D, span: float, pin_along: Array, _def: Dictionary) -> void:
	var body_len := maxf(span * 0.5, 0.05)
	_leads(frame, span, body_len, pin_along)
	# 5050-style SMD tile: metal base, black face, brighter light centre.
	_add(frame, _box(Vector3(0.062, 0.006, body_len)), _material(Color(0.85, 0.85, 0.88), 0.4), Vector3(0, 0.003, 0))
	_add(frame, _box(Vector3(0.05, 0.012, body_len * 0.8)), _material(Color(0.08, 0.08, 0.10), 0.5), Vector3(0, 0.012, 0))
	_add(frame, _box(Vector3(0.024, 0.004, body_len * 0.42)), _material(Color(1.0, 1.0, 1.0), 0.3, 0.0, 0.35), Vector3(0, 0.019, 0))


static func _body_module(frame: Node3D, span: float, pin_along: Array, label: String, pcb: Color) -> void:
	var body_len := maxf(span * 0.75, maxf(float(pin_along.size()) * 0.02, 0.07))
	var width := 0.07
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(width, 0.006, body_len)), _material(pcb, 0.6), Vector3(0, 0.003, 0))
	# header block along the pinned edge
	_add(frame, _box(Vector3(0.02, 0.016, body_len * 0.92)), _material(HEADER_BLACK, 0.5), Vector3(0, 0.011, 0))
	# a chip and a couple of parts
	_add(frame, _box(Vector3(0.03, 0.01, 0.03)), _material(BODY_BLACK, 0.5), Vector3(0.012, 0.011, -body_len * 0.15))
	_add(frame, _box(Vector3(0.024, 0.006, 0.02)), _material(Color(0.28, 0.30, 0.34), 0.5), Vector3(0.012, 0.009, body_len * 0.2))
	var mark := Label3D.new()
	lbl_setup(mark, label)
	mark.position = Vector3(0, 0.05, 0)
	frame.add_child(mark)


## PCB colour by board family: Arduino boards are their documented teal-blue,
## Raspberry Pi / Teensy are dark green, Pico/XIAO/BlackPill/ESP32 modules are
## matte black, the BluePill is blue. Falls back to the generic PCB blue.
static func _board_pcb_color(a_type: String) -> Color:
	var t := a_type.to_lower()
	if t.contains("bluepill"):
		return Color(0.12, 0.24, 0.62)
	if t.contains("blackpill") or t.contains("pico") or t.contains("xiao") or t.contains("esp32"):
		return Color(0.075, 0.08, 0.095)
	if t.contains("pi") or t.contains("teensy"):
		return Color(0.11, 0.29, 0.18)
	return PCB_BLUE


static func _body_board(frame: Node3D, span: float, pin_along: Array, label: String, a_type: String = "") -> void:
	var body_len := maxf(span * 0.85, 0.1)
	var width := 0.11
	var def := ComponentDB.get_def(a_type)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(width, 0.008, body_len)), _material(_board_pcb_color(a_type), 0.6), Vector3(0, 0.004, 0))
	# two header strips (one per long edge)
	_add(frame, _box(Vector3(0.016, 0.014, body_len * 0.9)), _material(HEADER_BLACK, 0.5), Vector3(-width * 0.5 + 0.01, 0.012, 0))
	_add(frame, _box(Vector3(0.016, 0.014, body_len * 0.9)), _material(HEADER_BLACK, 0.5), Vector3(width * 0.5 - 0.01, 0.012, 0))
	# big IC / shield footprint
	_add(frame, _box(Vector3(0.05, 0.012, body_len * 0.4)), _material(BODY_BLACK, 0.5), Vector3(0, 0.013, -body_len * 0.1))
	# documented USB connector on the headerless end
	var bi = def.get("board_info", {})
	var usb := ""
	if typeof(bi) == TYPE_DICTIONARY:
		usb = String(bi.get("usb", ""))
	if usb != "" and usb != "none":
		_add(frame, _box(Vector3(0.05, 0.030, 0.034)), _material(METAL, 0.3, 0.65), Vector3(0, 0.016, -body_len * 0.5 - 0.014))
	var mark := Label3D.new()
	lbl_setup(mark, label)
	mark.position = Vector3(0, 0.06, 0)
	frame.add_child(mark)


static func _body_generic(frame: Node3D, span: float, pin_along: Array, color: Color) -> void:
	var body_len := maxf(span * 0.6, 0.05)
	_leads(frame, span, body_len, pin_along)
	_add(frame, _box(Vector3(0.05, 0.04, body_len)), _material(color, 0.55), Vector3(0, 0.02, 0))
