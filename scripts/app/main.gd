extends Node3D
## CircuitForge 3D - main application scene.
##
## Builds the 3D workbench, the panel UI and wires user interaction to the
## Session (which owns the design and drives the solver).

const OrbitCamera = preload("res://scripts/camera/orbit_camera.gd")
const BreadboardView = preload("res://scripts/breadboard/breadboard_view.gd")
const ComponentFactory = preload("res://scripts/components/component_factory.gd")
const Session = preload("res://scripts/app/session.gd")
const ComponentDB = preload("res://scripts/components/component_db.gd")
const Oscilloscope = preload("res://scripts/instruments/oscilloscope.gd")
const Units = preload("res://scripts/simulation/units.gd")

var session
var bb_view
var camera
var comp_root: Node3D
var wire_root: Node3D

var pending_type = ""
var wire_mode = false
var wire_start = null

# UI references
var status_label: Label
var diag_label: RichTextLabel
var measure_label: RichTextLabel
var props_box: VBoxContainer
var lib_list: ItemList
var search_field: LineEdit
var scope_window: Window
var scope: Control
var scope_prev: LineEdit
var scope_sel: Array = []
var open_dialog: FileDialog
var save_dialog: FileDialog
var lib_defs: Array = []
var example_paths: Array = []
var save_as_mode := false
var meter_window: Window
var meter_probe: LineEdit
var meter_label: RichTextLabel
var quit_dialog: ConfirmationDialog
var env: Environment
var light_mode := 0


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)
	_build_world()
	_build_ui()
	session = Session.new()
	session.changed.connect(_on_session_changed)
	session.selection_changed.connect(_on_selection_changed)
	session.simulation_updated.connect(_on_simulation_updated)
	session.status_message.connect(_on_status)
	_on_session_changed()
	_on_status("Welcome to CircuitForge 3D. Pick a component, click the board to place it.")
	_open_from_command_line()
	_update_title()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if session != null and session.is_dirty():
			quit_dialog.popup_centered()
		else:
			get_tree().quit()


func _update_title() -> void:
	var name := "Untitled"
	if session != null and session.project.has("metadata"):
		name = String(session.project.metadata.get("name", "Untitled"))
	var star := " *" if (session != null and session.is_dirty()) else ""
	get_window().title = "CircuitForge 3D - %s%s" % [name, star]


func _open_from_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	var path := String(args[0])
	if not session.load_project(path):
		return
	session.mark_untitled()
	var mode := String(session.project.get("simulation", {}).get("mode", "dc"))
	_on_status("Loaded %s" % path)
	if mode == "transient":
		_on_run_transient()
	else:
		_on_run_dc()


# ---------------------------------------------------------------------------
# World
# ---------------------------------------------------------------------------

func _build_world() -> void:
	var env_node = WorldEnvironment.new()
	var e = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.1, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.52, 0.6)
	e.ambient_light_energy = 0.6
	env_node.environment = e
	add_child(env_node)
	env = e

	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	var fill = DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, 140, 0)
	fill.light_energy = 0.35
	add_child(fill)

	bb_view = BreadboardView.new()
	add_child(bb_view)

	comp_root = Node3D.new()
	comp_root.name = "Components"
	add_child(comp_root)

	wire_root = Node3D.new()
	wire_root.name = "Wires"
	add_child(wire_root)

	camera = OrbitCamera.new()
	camera.target = Vector3.ZERO
	add_child(camera)
	camera.current = true


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var layer = CanvasLayer.new()
	add_child(layer)
	var root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	_build_toolbar(root)
	_build_left(root)
	_build_right(root)
	_build_bottom(root)
	_build_scope()
	_build_meter()
	_build_dialogs()


func _mk_button(parent: Node, text: String, cb: Callable, tip: String = "") -> Button:
	var b = Button.new()
	b.text = text
	b.tooltip_text = tip if tip != "" else text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _build_toolbar(root: Control) -> void:
	var bar = PanelContainer.new()
	bar.anchor_right = 1.0
	bar.offset_bottom = 70
	var hb = HFlowContainer.new()
	hb.add_theme_constant_override("h_separation", 4)
	hb.add_theme_constant_override("v_separation", 4)
	bar.add_child(hb)
	root.add_child(bar)

	_mk_button(hb, "New", _on_new)
	_mk_button(hb, "Open", _on_open)
	_mk_button(hb, "Save", _on_save)
	_mk_button(hb, "Save As", _on_save_as)
	_build_examples_menu(hb)
	var sep1 = VSeparator.new(); hb.add_child(sep1)
	_mk_button(hb, "Wire", _on_wire_mode, "Toggle wire drawing (click two holes)")
	_mk_button(hb, "Rotate", _on_rotate, "Rotate selected component")
	_mk_button(hb, "Dup", _on_duplicate, "Duplicate selected component")
	_mk_button(hb, "Delete", _on_delete, "Delete selected component")
	var sep2 = VSeparator.new(); hb.add_child(sep2)
	_mk_button(hb, "Run DC", _on_run_dc, "Solve the DC operating point")
	_mk_button(hb, "Run Transient", _on_run_transient, "Run a transient simulation")
	_mk_button(hb, "Stop", _on_stop, "Clear simulation results")
	var sep3 = VSeparator.new(); hb.add_child(sep3)
	_mk_button(hb, "Undo", _on_undo, "Undo")
	_mk_button(hb, "Redo", _on_redo, "Redo")
	_mk_button(hb, "Scope", _on_toggle_scope, "Show/hide the oscilloscope")
	_mk_button(hb, "Meter", _on_toggle_meter, "Show/hide the multimeter")
	_mk_button(hb, "Lighting", _on_cycle_lighting, "Cycle the workbench lighting")
	_mk_button(hb, "Reset View", _on_reset_view, "Reset the camera")


func _build_examples_menu(hb: Control) -> void:
	var ex_btn = OptionButton.new()
	ex_btn.tooltip_text = "Load and simulate a bundled example circuit"
	ex_btn.add_item("Examples")
	ex_btn.set_item_disabled(0, true)
	example_paths.clear()
	var edir = DirAccess.open("res://data/examples")
	if edir != null:
		var names := []
		edir.list_dir_begin()
		var fn = edir.get_next()
		while fn != "":
			if fn.ends_with(".cf3d"):
				names.append(fn)
			fn = edir.get_next()
		edir.list_dir_end()
		names.sort()
		for n in names:
			example_paths.append("res://data/examples/" + n)
			ex_btn.add_item(String(n).get_basename().replace("_", " "))
	ex_btn.item_selected.connect(_on_example_selected)
	hb.add_child(ex_btn)


func _build_left(root: Control) -> void:
	var panel = PanelContainer.new()
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = 8
	panel.offset_right = 232
	panel.offset_top = 76
	panel.offset_bottom = 600
	root.add_child(panel)
	var vb = VBoxContainer.new()
	panel.add_child(vb)
	var title = Label.new()
	title.text = "Component Library"
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)
	search_field = LineEdit.new()
	search_field.placeholder_text = "Search..."
	search_field.text_changed.connect(_on_search)
	vb.add_child(search_field)
	lib_list = ItemList.new()
	lib_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lib_list.custom_minimum_size = Vector2(210, 460)
	lib_list.item_selected.connect(_on_library_pick)
	vb.add_child(lib_list)
	_refresh_library("")


func _build_right(root: Control) -> void:
	var panel = PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -280
	panel.offset_right = -8
	panel.offset_top = 76
	panel.offset_bottom = 600
	root.add_child(panel)
	var vb = VBoxContainer.new()
	panel.add_child(vb)
	var title = Label.new()
	title.text = "Properties"
	title.add_theme_font_size_override("font_size", 16)
	vb.add_child(title)
	props_box = VBoxContainer.new()
	props_box.custom_minimum_size = Vector2(260, 500)
	vb.add_child(props_box)


func _build_bottom(root: Control) -> void:
	var panel = PanelContainer.new()
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = 240
	panel.offset_right = -288
	panel.offset_top = -190
	panel.offset_bottom = -8
	root.add_child(panel)
	var vb = VBoxContainer.new()
	panel.add_child(vb)
	status_label = Label.new()
	status_label.text = "Ready."
	vb.add_child(status_label)
	var hs = HSplitContainer.new()
	hs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(hs)
	measure_label = RichTextLabel.new()
	measure_label.bbcode_enabled = true
	measure_label.custom_minimum_size = Vector2(360, 120)
	hs.add_child(measure_label)
	diag_label = RichTextLabel.new()
	diag_label.bbcode_enabled = true
	diag_label.custom_minimum_size = Vector2(360, 120)
	hs.add_child(diag_label)


func _build_scope() -> void:
	scope_window = Window.new()
	scope_window.title = "Oscilloscope"
	scope_window.size = Vector2i(560, 340)
	scope_window.position = Vector2i(320, 120)
	scope_window.visible = false
	add_child(scope_window)
	var vb = VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scope_window.add_child(vb)
	var hb = HBoxContainer.new()
	vb.add_child(hb)
	var lbl = Label.new()
	lbl.text = "Probes (comma separated net/component ids):"
	hb.add_child(lbl)
	scope_prev = LineEdit.new()
	scope_prev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scope_prev.text = ""
	scope_prev.text_submitted.connect(_on_scope_probes)
	scope_prev.text_changed.connect(_on_scope_probes)
	hb.add_child(scope_prev)
	scope = Oscilloscope.new()
	scope.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scope.custom_minimum_size = Vector2(540, 260)
	vb.add_child(scope)


func _build_meter() -> void:
	meter_window = Window.new()
	meter_window.title = "Multimeter"
	meter_window.size = Vector2i(320, 220)
	meter_window.position = Vector2i(900, 200)
	meter_window.visible = false
	add_child(meter_window)
	var vb = VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	meter_window.add_child(vb)
	var lbl = Label.new()
	lbl.text = "Probe a net name (e.g. a5) or component id (e.g. R1):"
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(lbl)
	meter_probe = LineEdit.new()
	meter_probe.placeholder_text = "R1"
	meter_probe.text_changed.connect(_on_meter_probe)
	vb.add_child(meter_probe)
	meter_label = RichTextLabel.new()
	meter_label.bbcode_enabled = true
	meter_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	meter_label.custom_minimum_size = Vector2(300, 120)
	vb.add_child(meter_label)


func _build_dialogs() -> void:
	open_dialog = FileDialog.new()
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_dialog.add_filter("*.cf3d", "CircuitForge project")
	open_dialog.title = "Open Circuit"
	open_dialog.file_selected.connect(_on_open_selected)
	add_child(open_dialog)

	save_dialog = FileDialog.new()
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	save_dialog.add_filter("*.cf3d", "CircuitForge project")
	save_dialog.title = "Save Circuit"
	save_dialog.current_file = "circuit.cf3d"
	save_dialog.file_selected.connect(_on_save_selected)
	add_child(save_dialog)

	quit_dialog = ConfirmationDialog.new()
	quit_dialog.title = "Unsaved changes"
	quit_dialog.dialog_text = "This circuit has unsaved changes. Quit anyway?"
	quit_dialog.ok_button_text = "Quit without saving"
	quit_dialog.cancel_button_text = "Keep editing"
	quit_dialog.confirmed.connect(func(): get_tree().quit())
	add_child(quit_dialog)


# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

func _refresh_library(filter: String) -> void:
	lib_list.clear()
	lib_defs.clear()
	var defs = ComponentDB.all_defs()
	var keys = defs.keys()
	keys.sort()
	var f = filter.strip_edges().to_lower()
	for t in keys:
		var d = defs[t]
		var text = "%s  (%s)" % [String(d.name), String(d.category)]
		if f != "" and not (String(d.name).to_lower().contains(f) or String(t).to_lower().contains(f) or String(d.category).to_lower().contains(f)):
			continue
		lib_list.add_item(text)
		lib_defs.append(t)
		lib_list.set_item_tooltip(lib_list.item_count - 1, String(d.description))


func _on_search(text: String) -> void:
	_refresh_library(text)


func _on_library_pick(index: int) -> void:
	if index < 0 or index >= lib_defs.size():
		return
	pending_type = lib_defs[index]
	wire_mode = false
	var d = ComponentDB.get_def(pending_type)
	_on_status("Placing %s - click a breadboard hole." % String(d.name))


# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------

func _handle_click(pos: Vector2) -> void:
	var from = camera.project_ray_origin(pos)
	var dir = camera.project_ray_normal(pos)
	var hole = bb_view.ray_nearest_hole(from, dir, 0.08)

	if pending_type != "":
		if hole != "":
			var pc = ComponentDB.pin_count(pending_type)
			var holes = bb_view.default_holes(pending_type, pc, hole)
			session.add_component(pending_type, holes)
			pending_type = ""
			_on_status("Component placed. Select it to edit properties.")
		return

	if wire_mode:
		if hole == "":
			return
		if wire_start == null:
			wire_start = {"kind": "hole", "id": hole}
			_on_status("Wire start at %s - click the second hole." % hole)
		else:
			session.add_wire(wire_start, {"kind": "hole", "id": hole})
			wire_start = null
		return

	if hole != "":
		var cid = _component_at_hole(hole)
		session.select(cid)
	else:
		session.select("")


func _component_at_hole(hole: String) -> String:
	for c in session.project.components:
		for h in c.holes:
			if String(h) == hole:
				return String(c.id)
	return ""


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_handle_click(mb.position)
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and mb.double_click:
			pass
	elif event is InputEventKey:
		var ek = event as InputEventKey
		if not ek.pressed or ek.echo:
			return
		if ek.ctrl_pressed:
			match ek.keycode:
				KEY_S:
					if ek.shift_pressed:
						_on_save_as()
					else:
						_on_save()
					return
				KEY_O:
					_on_open()
					return
				KEY_N:
					_on_new()
					return
				KEY_Z:
					_on_undo()
					return
				KEY_Y:
					_on_redo()
					return
		match ek.keycode:
			KEY_DELETE:
				_on_delete()
			KEY_W:
				_on_wire_mode()
			KEY_R:
				_on_rotate()
			KEY_SPACE:
				_on_run_dc()
			KEY_F1:
				_show_help()


# ---------------------------------------------------------------------------
# 3D rebuild + labels
# ---------------------------------------------------------------------------

func _on_session_changed() -> void:
	_rebuild_3d()
	_refresh_properties()
	_update_title()


func _on_selection_changed(_id: String) -> void:
	_refresh_properties()
	_rebuild_3d()


func _rebuild_3d() -> void:
	if comp_root == null:
		return
	# Child nodes may be posted for deferred deletion; free them immediately so a
	# rapid sequence of edits cannot stack duplicate visuals for a frame.
	for c in comp_root.get_children():
		comp_root.remove_child(c)
		c.queue_free()
	for c in wire_root.get_children():
		wire_root.remove_child(c)
		c.queue_free()

	for comp in session.project.components:
		var pin_positions = []
		var valid = true
		for h in comp.holes:
			var hs = String(h)
			if hs == "" or not bb_view.hole_positions.has(hs):
				valid = false
				pin_positions.append(Vector3.ZERO)
			else:
				pin_positions.append(bb_view.hole_positions[hs])
		var node = ComponentFactory.build(String(comp.type), pin_positions, String(comp.id) == session.selected_id)
		node.name = String(comp.id)
		node.set_meta("component_id", String(comp.id))
		comp_root.add_child(node)
		if not valid:
			var lbl = node.get_node_or_null("ValueLabel")
			if lbl != null:
				lbl.modulate = Color(1.0, 0.45, 0.45)
				lbl.set_meta("invalid_placement", true)

	for w in session.project.wires:
		_draw_wire(w)

	_update_labels()


func _draw_wire(w: Dictionary) -> void:
	var a = _endpoint_world(w.a)
	var b = _endpoint_world(w.b)
	if a == null or b == null:
		return
	_cylinder_between(a, b, 0.012, Color(0.85, 0.55, 0.2), wire_root)


func _endpoint_world(ep) -> Variant:
	if typeof(ep) != TYPE_DICTIONARY:
		return null
	if String(ep.get("kind", "")) == "hole":
		var h = String(ep.get("id", ""))
		if bb_view.hole_positions.has(h):
			return bb_view.hole_positions[h] + Vector3(0, 0.03, 0)
		return null
	var cid = String(ep.get("component", ""))
	var pin = int(ep.get("pin", 0))
	for c in session.project.components:
		if String(c.id) == cid and pin < c.holes.size():
			var h2 = String(c.holes[pin])
			if bb_view.hole_positions.has(h2):
				return bb_view.hole_positions[h2] + Vector3(0, 0.06, 0)
	return null


func _cylinder_between(a: Vector3, b: Vector3, radius: float, color: Color, parent: Node3D) -> void:
	var mid = (a + b) * 0.5
	var length = a.distance_to(b)
	if length < 1e-5:
		return
	var mi = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = length
	mi.mesh = cyl
	var m = StandardMaterial3D.new()
	m.albedo_color = color
	mi.material_override = m
	var up = (b - a).normalized()
	var basis = Basis()
	var axis = Vector3.UP.cross(up)
	if axis.length() < 1e-6:
		basis = Basis() if up.y > 0 else Basis.from_euler(Vector3(PI, 0, 0))
	else:
		var angle = Vector3.UP.angle_to(up)
		basis = Basis(axis.normalized(), angle)
	mi.transform = Transform3D(basis, mid)
	parent.add_child(mi)


func _update_labels() -> void:
	var res = session.last_result
	for c in comp_root.get_children():
		if not c.has_meta("component_id"):
			continue
		var cid = String(c.get_meta("component_id"))
		var comp = null
		for cc in session.project.components:
			if String(cc.id) == cid:
				comp = cc
				break
		var lbl = c.get_node_or_null("ValueLabel")
		if lbl == null or comp == null:
			continue
		var parts = []
		var d = ComponentDB.get_def(String(comp.type))
		if d.is_empty():
			continue
		if d.params.size() > 0:
			var pk = d.params.keys()[0]
			parts.append("%s = %s" % [cid, Units.format(float(comp.params.get(pk, 0.0)), String(d.params[pk].unit))])
		else:
			parts.append(cid)
		if res is Dictionary and res.get("ok", false):
			if res.element_voltages.has(cid):
				parts.append("V=" + Units.format(float(res.element_voltages[cid]), "V"))
			if res.element_currents.has(cid):
				parts.append("I=" + Units.format(float(res.element_currents[cid]), "A"))
		lbl.text = "\n".join(parts)


# ---------------------------------------------------------------------------
# Properties panel
# ---------------------------------------------------------------------------

func _refresh_properties() -> void:
	if props_box == null:
		return
	for c in props_box.get_children():
		c.queue_free()
	if session.selected_id == "":
		var l = Label.new()
		l.text = "No component selected.\n\nClick a placed component on the board, or pick one from the library and click the board."
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(250, 100)
		props_box.add_child(l)
		return
	var comp = null
	for cc in session.project.components:
		if String(cc.id) == session.selected_id:
			comp = cc
			break
	if comp == null:
		return
	var title = Label.new()
	title.text = "%s  (%s)" % [String(comp.id), String(comp.type)]
	title.add_theme_font_size_override("font_size", 15)
	props_box.add_child(title)

	var d = ComponentDB.get_def(String(comp.type))
	for key in d.params:
		var spec = d.params[key]
		var row = HBoxContainer.new()
		var lbl = Label.new()
		lbl.text = String(spec.label)
		lbl.custom_minimum_size = Vector2(120, 0)
		row.add_child(lbl)
		var le = LineEdit.new()
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var raw = comp.params.get(key, spec.default)
		if typeof(raw) == TYPE_BOOL:
			le.text = str(raw)
		else:
			le.text = str(raw)
		var captured = key
		le.text_submitted.connect(func(t): _apply_param(comp.id, captured, t))
		le.focus_exited.connect(func(): _apply_param(comp.id, captured, le.text))
		row.add_child(le)
		var u = Label.new()
		u.text = String(spec.unit)
		u.custom_minimum_size = Vector2(34, 0)
		row.add_child(u)
		props_box.add_child(row)

	# Pin -> net mapping.
	var pin_title = Label.new()
	pin_title.text = "Pins:"
	props_box.add_child(pin_title)
	var built = session.build_circuit()
	var nets: Array = built.pin_nets.get(String(comp.id), [])
	for i in comp.holes.size():
		var pl = Label.new()
		var h = String(comp.holes[i])
		var net = String(nets[i]) if i < nets.size() else "?"
		pl.text = "  pin %d: hole %s  ->  net %s" % [i + 1, h if h != "" else "(unplaced)", net]
		props_box.add_child(pl)

	var btnrow = HBoxContainer.new()
	_mk_button(btnrow, "Rotate", _on_rotate)
	_mk_button(btnrow, "Duplicate", _on_duplicate)
	_mk_button(btnrow, "Delete", _on_delete)
	props_box.add_child(btnrow)


func _apply_param(cid: String, key: String, text: String) -> void:
	var comp = null
	for cc in session.project.components:
		if String(cc.id) == cid:
			comp = cc
			break
	if comp == null:
		return
	var d = ComponentDB.get_def(String(comp.type))
	var spec = d.params.get(key, {})
	var cur = comp.params.get(key, null)
	var value
	if typeof(cur) == TYPE_BOOL:
		value = text.strip_edges().to_lower() in ["true", "1", "yes", "on", "closed"]
	else:
		value = Units.parse(text)
	if cur != null and typeof(value) == typeof(cur) and value == cur:
		return
	session.set_param(cid, key, value)


# ---------------------------------------------------------------------------
# Toolbar callbacks
# ---------------------------------------------------------------------------

func _on_new() -> void:
	session.new_project()
	_on_status("New project. Add a Ground component so the circuit can be solved.")

func _on_open() -> void:
	open_dialog.popup_centered(Vector2i(700, 460))

func _on_open_selected(path: String) -> void:
	if session.load_project(path):
		_on_status("Opened " + path)

func _on_example_selected(index: int) -> void:
	if index <= 0 or index - 1 >= example_paths.size():
		return
	var path := String(example_paths[index - 1])
	if not session.load_project(path):
		return
	session.mark_untitled()
	var mode := String(session.project.get("simulation", {}).get("mode", "dc"))
	_on_status("Loaded example: %s" % String(path).get_file())
	if mode == "transient":
		_on_run_transient()
	else:
		_on_run_dc()


func _on_save() -> void:
	if session.current_file() != "":
		session.save_project(session.current_file())
		_update_title()
	else:
		save_dialog.popup_centered(Vector2i(700, 460))

func _on_save_selected(path: String) -> void:
	session.save_project(path)
	save_as_mode = false
	_update_title()


func _on_save_as() -> void:
	save_as_mode = true
	save_dialog.popup_centered(Vector2i(700, 460))

func _on_wire_mode() -> void:
	wire_mode = not wire_mode
	pending_type = ""
	wire_start = null
	_on_status("Wire mode %s." % ("ON - click two holes" if wire_mode else "OFF"))

func _on_rotate() -> void:
	if session.selected_id != "":
		session.rotate_component(session.selected_id)

func _on_duplicate() -> void:
	if session.selected_id != "":
		session.duplicate_component(session.selected_id)

func _on_delete() -> void:
	if session.selected_id != "":
		session.remove_component(session.selected_id)

func _on_undo() -> void:
	session.undo()

func _on_redo() -> void:
	session.redo()

func _on_run_dc() -> void:
	session.simulate_dc()

func _on_run_transient() -> void:
	session.run_transient()
	_refresh_scope_targets()

func _on_stop() -> void:
	session.last_result = {}
	session.waveforms = {}
	session.simulation_updated.emit({})
	_on_status("Simulation results cleared.")

func _on_reset_view() -> void:
	camera.focus_on(Vector3.ZERO, 3.2)

func _on_toggle_scope() -> void:
	scope_window.visible = not scope_window.visible
	_refresh_scope_targets()


func _on_toggle_meter() -> void:
	meter_window.visible = not meter_window.visible
	_refresh_meter()


func _on_cycle_lighting() -> void:
	if env == null:
		return
	light_mode = (light_mode + 1) % 3
	match light_mode:
		1:
			env.background_color = Color(0.16, 0.18, 0.21)
			env.ambient_light_energy = 0.95
			_on_status("Lighting: bright")
		2:
			env.background_color = Color(0.03, 0.03, 0.05)
			env.ambient_light_energy = 0.25
			_on_status("Lighting: night")
		_:
			env.background_color = Color(0.09, 0.1, 0.12)
			env.ambient_light_energy = 0.6
			_on_status("Lighting: studio")


func _on_meter_probe(_text: String) -> void:
	_refresh_meter()


func _refresh_meter() -> void:
	if meter_label == null:
		return
	var probe := meter_probe.text.strip_edges() if meter_probe != null else ""
	var res = session.last_result
	var lines := []
	if probe == "":
		meter_label.text = "[b]Multimeter[/b]\nEnter a probe."
		return
	if not (res is Dictionary) or not res.get("ok", false):
		meter_label.text = "[b]Multimeter[/b]\nNo simulation run yet."
		return
	lines.append("[b]Multimeter - %s[/b]" % probe)
	var node = res.get("node_voltages", {})
	var vres = res.get("element_voltages", {})
	var ires = res.get("element_currents", {})
	var found := false
	if node.has(probe):
		found = true
		lines.append("Node voltage (%s -> ref): %s" % [probe, Units.format(float(node[probe]), "V")])
	if vres.has(probe):
		found = true
		lines.append("Voltage across %s: %s" % [probe, Units.format(float(vres[probe]), "V")])
	if ires.has(probe):
		found = true
		lines.append("Current through %s: %s" % [probe, Units.format(float(ires[probe]), "A")])
	if not found:
		lines.append("[color=orange]No net or component with that name.[/color]")
	meter_label.text = "\n".join(lines)


# ---------------------------------------------------------------------------
# Simulation results
# ---------------------------------------------------------------------------

func _on_simulation_updated(res: Dictionary) -> void:
	_update_labels()
	_show_measurements(res)
	_show_diagnostics(res)
	_refresh_meter()


func _show_measurements(res: Dictionary) -> void:
	if measure_label == null:
		return
	var lines = []
	if res.is_empty():
		measure_label.text = "[b]Measurements[/b]\nNo simulation run yet."
		return
	if not res.get("ok", false):
		measure_label.text = "[b]Measurements[/b]\nSimulation failed: %s" % String(res.get("error", ""))
		return
	lines.append("[b]Node voltages[/b]")
	var nets: Array = res.node_voltages.keys()
	nets.sort()
	for n in nets:
		lines.append("  net %s = %s" % [String(n), Units.format(float(res.node_voltages[n]), "V")])
	lines.append("[b]Branch currents[/b]")
	var els: Array = res.element_currents.keys()
	els.sort()
	for e in els:
		lines.append("  %s = %s" % [String(e), Units.format(float(res.element_currents[e]), "A")])
	measure_label.text = "\n".join(lines)


func _show_diagnostics(res: Dictionary) -> void:
	if diag_label == null:
		return
	var lines = []
	lines.append("[b]Diagnostics[/b]")
	if res.is_empty():
		diag_label.text = "[b]Diagnostics[/b]\nNo diagnostics."
		return
	var warns: Array = []
	warns.append_array(res.get("builder_warnings", []))
	warns.append_array(res.get("warnings", []))
	if warns.is_empty():
		lines.append("  No warnings.")
	else:
		for w in warns:
			lines.append("  [color=orange]![/color] " + String(w))
	if res.get("ok", false):
		lines.append("  Solver: OK (%d iteration(s), %d node(s))" % [int(res.get("iterations", 0)), (res.node_voltages.size())])
	else:
		lines.append("  [color=red]Solver error: %s[/color]" % String(res.get("error", "")))
	diag_label.text = "\n".join(lines)


func _on_status(text: String) -> void:
	if status_label != null:
		status_label.text = text


# ---------------------------------------------------------------------------
# Oscilloscope
# ---------------------------------------------------------------------------

func _refresh_scope_targets() -> void:
	if scope == null:
		return
	scope.set_waveforms(session.waveforms)
	if scope_prev != null and session.waveforms.has("series"):
		var keys: Array = session.waveforms.series.keys()
		keys.sort()
		var picks := []
		for k in session.waveforms.get("node_keys", []):
			if String(k) != "0":
				picks.append(k)
			if picks.size() >= 3:
				break
		if picks.is_empty():
			picks = keys.slice(0, min(2, keys.size()))
		scope_prev.text = ", ".join(picks)
		_on_scope_probes(scope_prev.text)


func _on_scope_probes(text: String) -> void:
	var parts = text.split(",")
	var ch = ["", "", "", ""]
	for i in range(min(4, parts.size())):
		ch[i] = parts[i].strip_edges()
	scope.set_channels(ch)


func _show_help() -> void:
	var dlg = AcceptDialog.new()
	dlg.title = "CircuitForge 3D - Help"
	dlg.dialog_text = """CircuitForge 3D quick start

1. Pick a component in the left library.
2. Click a breadboard hole to place it (pins land on the next rows).
3. Use Wire mode: click two holes to join them.
4. Place a Ground component on the net you want as 0 V.
5. Press Run DC to solve, or Run Transient for waveforms.
6. Select a component to edit its value in the Properties panel.

Instruments: Scope plots transient traces; Meter reads a net or component.
Logic: AND / OR / NOT / NAND / NOR / XOR / Buffer gates use 5 V logic levels.

Camera: right-drag = orbit, middle-drag = pan, wheel = zoom.
Shortcuts: W wire, R rotate, Delete delete, Space run DC, F1 help,
           Ctrl+S save, Ctrl+Shift+S save as, Ctrl+O open, Ctrl+Z/Y undo/redo."""
	add_child(dlg)
	dlg.popup_centered()
