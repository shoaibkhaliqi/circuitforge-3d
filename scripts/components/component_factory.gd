extends RefCounted
## CircuitForge 3D - builds reusable 3D visuals for components.
##
## Every component type maps to a small reused set of meshes and materials. The
## visual is decorative only; it carries no electrical meaning.

const TYPE_COLORS := {
	"resistor": Color(0.82, 0.72, 0.52),
	"capacitor": Color(0.35, 0.55, 0.85),
	"inductor": Color(0.45, 0.7, 0.45),
	"potentiometer": Color(0.7, 0.6, 0.35),
	"vsource": Color(0.85, 0.3, 0.3),
	"isource": Color(0.9, 0.6, 0.25),
	"ground": Color(0.2, 0.2, 0.22),
	"switch": Color(0.5, 0.5, 0.55),
	"led": Color(0.9, 0.25, 0.3),
	"diode": Color(0.25, 0.25, 0.28),
	"zener": Color(0.3, 0.3, 0.4),
}

static var _materials := {}


static func _material(color: Color, emissive: bool = false) -> StandardMaterial3D:
	var key := "%s_%s" % [color.to_html(), str(emissive)]
	if _materials.has(key):
		return _materials[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.6
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.5
	_materials[key] = m
	return m


## Build a visual for one component. `pin_positions` are the world positions of
## each pin; the body is placed between them.
static func build(type: String, pin_positions: Array, selected: bool = false) -> Node3D:
	var root := Node3D.new()
	var color: Color = TYPE_COLORS.get(type, Color(0.6, 0.6, 0.6))
	if selected:
		color = color.lerp(Color(1.0, 0.9, 0.2), 0.5)
	var mat := _material(color, type == "led")

	# Pin pads.
	for p in pin_positions:
		var pad := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.02
		cyl.bottom_radius = 0.02
		cyl.height = 0.04
		pad.mesh = cyl
		pad.material_override = _material(Color(0.75, 0.75, 0.78))
		pad.position = p
		root.add_child(pad)

	# Body between the first and last pin, or at the single pin for ground.
	if pin_positions.size() >= 2:
		var a: Vector3 = pin_positions[0]
		var b: Vector3 = pin_positions[pin_positions.size() - 1]
		var mid := (a + b) * 0.5
		var span := a.distance_to(b)
		var body := MeshInstance3D.new()
		var box := BoxMesh.new()
		var dir := (b - a).normalized()
		if absf(dir.x) > absf(dir.z):
			box.size = Vector3(maxf(span * 0.6, 0.06), 0.06, 0.05)
		else:
			box.size = Vector3(0.05, 0.06, maxf(span * 0.6, 0.06))
		body.mesh = box
		body.material_override = mat
		body.position = mid + Vector3(0, 0.05, 0)
		root.add_child(body)
	elif pin_positions.size() == 1:
		var body1 := MeshInstance3D.new()
		var cyl1 := CylinderMesh.new()
		cyl1.top_radius = 0.05
		cyl1.bottom_radius = 0.05
		cyl1.height = 0.05
		body1.mesh = cyl1
		body1.material_override = mat
		body1.position = pin_positions[0] + Vector3(0, 0.03, 0)
		root.add_child(body1)

	# Value label.
	if pin_positions.size() >= 1:
		var lbl := Label3D.new()
		lbl.text = ""
		lbl.name = "ValueLabel"
		lbl.font_size = 32
		lbl.pixel_size = 0.0012
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.modulate = Color(1, 1, 1)
		lbl.outline_size = 6
		var c := Vector3.ZERO
		for p in pin_positions:
			c += p
		c /= max(1, pin_positions.size())
		lbl.position = c + Vector3(0, 0.14, 0)
		root.add_child(lbl)
	return root
