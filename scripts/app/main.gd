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
const Design = preload("res://scripts/ui/design.gd")
const Persistence = preload("res://scripts/persistence/persistence.gd")

var session
var bb_view
var camera
var comp_root: Node3D
var wire_root: Node3D
var preview_root: Node3D
var viewport3d: SubViewport
var _hover_hole := ""
var _screenshot_path := ""

const WIRE_PALETTE := [
	Color(0.93, 0.32, 0.30), Color(0.30, 0.55, 0.95), Color(0.95, 0.74, 0.25),
	Color(0.36, 0.80, 0.46), Color(0.80, 0.45, 0.88), Color(0.92, 0.55, 0.25),
	Color(0.35, 0.82, 0.85), Color(0.80, 0.80, 0.84),
]

# Layout
var ui_root: Control
var mid_split: HSplitContainer
var center_split: VSplitContainer
var left_panel: PanelContainer
var right_panel: PanelContainer
var bottom_panel: PanelContainer
var workspace: Control
var status_state: Label
var status_msg: Label
var status_tool: Label
var status_net: Label
var status_zoom: Label
var status_warn: Label
var cat_filter: OptionButton
var lib_hint: Label
var _current_cat := "All"
var _warn_count := 0
var _status_text := "Ready."
var _sim_run_btn: Button
var _wire_btn: Button
var _project_label: Label

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

# Electrical-net bookkeeping for the visual layer (filled on every rebuild from
# the real netlist build - the highlight and wire colours ARE the netlist).
var _hole_nets: Dictionary = {}     # hole id -> net name
var _pin_nets: Dictionary = {}      # component id -> array of net names
var _net_members: Dictionary = {}   # net name -> array of hole ids


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
	call_deferred("_apply_default_layout")


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
	if _project_label != null:
		_project_label.text = "%s%s" % [name, star]


func _open_from_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	var path := ""
	var i := 0
	while i < args.size():
		var a := String(args[i])
		if a.begins_with("--screenshot"):
			if a.contains("="):
				_screenshot_path = a.substr(a.find("=") + 1)
			elif i + 1 < args.size():
				i += 1
				_screenshot_path = String(args[i])
		elif not a.begins_with("--"):
			path = a
		i += 1
	if path != "":
		if not session.load_project(path):
			return
		session.mark_untitled()
		var mode := String(session.project.get("simulation", {}).get("mode", "dc"))
		_on_status("Loaded %s" % path)
		if mode == "transient":
			_on_run_transient()
		else:
			_on_run_dc()
	if _screenshot_path != "":
		_capture_screenshot()


func _capture_screenshot() -> void:
	for i in 18:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_screenshot_path)
	print("screenshot written to %s (err=%d)" % [_screenshot_path, err])
	get_tree().quit()


# ---------------------------------------------------------------------------
# World
# ---------------------------------------------------------------------------

func _build_world() -> void:
	# The whole 3D scene lives inside a SubViewport so it renders exactly in the
	# centre workspace, between the panels, instead of behind them.
	viewport3d = SubViewport.new()
	viewport3d.name = "Viewport3D"
	viewport3d.handle_input_locally = false
	viewport3d.msaa_3d = Viewport.MSAA_2X
	viewport3d.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport3d.size = Vector2i(900, 500)

	var env_node = WorldEnvironment.new()
	var e = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.09, 0.1, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.52, 0.6)
	e.ambient_light_energy = 0.6
	# Clarity-first realism: contact shadows ground parts on the board, filmic
	# tone response keeps plastics and LED emission reading naturally.
	e.ssao_enabled = true
	e.ssao_radius = 0.12
	e.ssao_intensity = 1.4
	e.ssao_detail = 0.8
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = e
	viewport3d.add_child(env_node)
	env = e

	# The bench: an anti-static mat under the board so the work area sits in a
	# believable space instead of floating in a void; it also receives the
	# sun's shadows, which sells the depth better than any extra light would.
	var mat := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(16, 10)
	mat.mesh = plane
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.10, 0.105, 0.125)
	mm.roughness = 0.97
	mm.metallic = 0.0
	mat.material_override = mm
	mat.position = Vector3(0, -0.062, 0)
	viewport3d.add_child(mat)

	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	viewport3d.add_child(sun)

	var fill = DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, 140, 0)
	fill.light_energy = 0.35
	viewport3d.add_child(fill)

	bb_view = BreadboardView.new()
	viewport3d.add_child(bb_view)

	comp_root = Node3D.new()
	comp_root.name = "Components"
	viewport3d.add_child(comp_root)

	wire_root = Node3D.new()
	wire_root.name = "Wires"
	viewport3d.add_child(wire_root)

	preview_root = Node3D.new()
	preview_root.name = "Preview"
	viewport3d.add_child(preview_root)

	camera = OrbitCamera.new()
	camera.target = Vector3.ZERO
	viewport3d.add_child(camera)
	camera.current = true


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var layer = CanvasLayer.new()
	layer.name = "UILayer"
	add_child(layer)
	var root = Control.new()
	root.name = "UIRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = Design.theme()
	layer.add_child(root)
	ui_root = root

	# The whole app is a vertical stack: toolbar / middle / status bar. The middle
	# is a split layout whose transparent centre reveals the 3D workbench.
	var app := VBoxContainer.new()
	app.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	app.add_theme_constant_override("separation", 0)
	app.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(app)

	app.add_child(_build_toolbar())

	mid_split = HSplitContainer.new()
	mid_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid_split.add_theme_constant_override("separation", 0)
	mid_split.mouse_filter = Control.MOUSE_FILTER_PASS
	app.add_child(mid_split)

	left_panel = _build_left()
	mid_split.add_child(left_panel)

	center_split = VSplitContainer.new()
	center_split.add_theme_constant_override("separation", 0)
	center_split.mouse_filter = Control.MOUSE_FILTER_PASS
	mid_split.add_child(center_split)

	workspace = SubViewportContainer.new()
	workspace.name = "Workspace"
	# PASS (not STOP) so clicks in the empty work area reach _unhandled_input for
	# 3D picking, while the viewport itself still receives its own events.
	workspace.mouse_filter = Control.MOUSE_FILTER_PASS
	workspace.stretch = true
	workspace.custom_minimum_size = Vector2(320, 220)
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_child(viewport3d)
	center_split.add_child(workspace)

	bottom_panel = _build_bottom()
	center_split.add_child(bottom_panel)

	right_panel = _build_right()
	mid_split.add_child(right_panel)

	app.add_child(_build_statusbar())

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


func _sep(parent: Node) -> void:
	var s := VSeparator.new()
	parent.add_child(s)


func _build_toolbar() -> PanelContainer:
	var bar := PanelContainer.new()
	bar.name = "Toolbar"
	# A flow container wraps to extra rows instead of forcing the window wider,
	# which keeps the panels on-screen at any width.
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 5)
	bar.add_child(flow)

	_mk_button(flow, "New", _on_new, "New project (Ctrl+N)")
	_mk_button(flow, "Open", _on_open, "Open a .cf3d project (Ctrl+O)")
	_mk_button(flow, "Save", _on_save, "Save (Ctrl+S)")
	_mk_button(flow, "Save As", _on_save_as, "Save under a new name (Ctrl+Shift+S)")
	_sep(flow)
	_build_examples_menu(flow)
	_build_view_menu(flow)
	_sep(flow)
	_mk_button(flow, "Undo", _on_undo, "Undo (Ctrl+Z)")
	_mk_button(flow, "Redo", _on_redo, "Redo (Ctrl+Y)")
	_sep(flow)
	_sim_run_btn = _mk_button(flow, "\u25B6 Run DC", _on_run_dc, "Solve the DC operating point (Space)")
	_mk_button(flow, "\u223F Transient", _on_run_transient, "Run a transient simulation")
	_mk_button(flow, "\u25A0 Stop", _on_stop, "Clear simulation results")
	_sep(flow)
	_wire_btn = _mk_button(flow, "Wire", _on_wire_mode, "Toggle wire drawing: click two holes (W)")
	_mk_button(flow, "Rotate", _on_rotate, "Rotate selected component (R)")
	_mk_button(flow, "Duplicate", _on_duplicate, "Duplicate selected component")
	_mk_button(flow, "Delete", _on_delete, "Delete selected component (Delete)")
	_sep(flow)
	_mk_button(flow, "Library", func(): _toggle_panel("left"), "Show/hide the component library")
	_mk_button(flow, "Inspector", func(): _toggle_panel("right"), "Show/hide the inspector")
	_mk_button(flow, "Console", func(): _toggle_panel("bottom"), "Show/hide the console")
	_mk_button(flow, "Scope", _on_toggle_scope, "Show/hide the oscilloscope")
	_mk_button(flow, "Meter", _on_toggle_meter, "Show/hide the multimeter")
	_mk_button(flow, "Lighting", _on_cycle_lighting, "Cycle the workbench lighting")
	return bar


func _build_view_menu(flow: Control) -> void:
	var view := OptionButton.new()
	view.tooltip_text = "Camera views"
	view.add_item("View")
	view.set_item_disabled(0, true)
	view.add_item("Top")
	view.add_item("Front")
	view.add_item("Side")
	view.add_item("Isometric")
	view.add_item("Frame All")
	view.add_item("Reset View")
	view.item_selected.connect(func(i: int):
		match i:
			1: camera.set_preset("top")
			2: camera.set_preset("front")
			3: camera.set_preset("side")
			4: camera.set_preset("iso")
			5: _on_frame_all()
			6: _on_reset_view()
		view.select(0))
	flow.add_child(view)


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
			var path := "res://data/examples/" + String(n)
			var label := String(n).get_basename().replace("_", " ")
			if not _example_runnable(path):
				label += "  (soon)"
			example_paths.append(path)
			ex_btn.add_item(label)
	ex_btn.item_selected.connect(_on_example_selected)
	hb.add_child(ex_btn)


func _build_left() -> PanelContainer:
	var panel = PanelContainer.new()
	panel.name = "LibraryPanel"
	panel.custom_minimum_size = Vector2(248, 200)
	var vb = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)
	vb.add_child(Design.heading("Component Library"))
	search_field = LineEdit.new()
	search_field.placeholder_text = "Search by name, category, part number..."
	search_field.clear_button_enabled = true
	search_field.text_changed.connect(_on_search)
	vb.add_child(search_field)
	cat_filter = OptionButton.new()
	cat_filter.item_selected.connect(_on_category_selected)
	vb.add_child(cat_filter)
	lib_list = ItemList.new()
	lib_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lib_list.custom_minimum_size = Vector2(220, 300)
	lib_list.allow_reselect = true
	lib_list.fixed_icon_size = Vector2i(20, 20)
	lib_list.item_selected.connect(_on_library_pick)
	vb.add_child(lib_list)
	lib_hint = Design.hint("Pick a component, then click a breadboard hole to place it.")
	vb.add_child(lib_hint)
	_refresh_categories()
	_refresh_library("")
	return panel


func _build_right() -> PanelContainer:
	var panel = PanelContainer.new()
	panel.name = "InspectorPanel"
	panel.custom_minimum_size = Vector2(300, 200)
	var vb = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)
	vb.add_child(Design.heading("Inspector"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	props_box = VBoxContainer.new()
	props_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	props_box.add_theme_constant_override("separation", 6)
	scroll.add_child(props_box)
	return panel


func _build_bottom() -> PanelContainer:
	var panel = PanelContainer.new()
	panel.name = "ConsolePanel"
	panel.custom_minimum_size = Vector2(0, 120)
	var vb = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	head.add_child(Design.heading("Console", Design.FONT_LABEL))
	var hs = HSplitContainer.new()
	hs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(hs)
	measure_label = RichTextLabel.new()
	measure_label.bbcode_enabled = true
	measure_label.custom_minimum_size = Vector2(320, 90)
	hs.add_child(measure_label)
	diag_label = RichTextLabel.new()
	diag_label.bbcode_enabled = true
	diag_label.custom_minimum_size = Vector2(320, 90)
	hs.add_child(diag_label)
	return panel


func _build_statusbar() -> PanelContainer:
	var bar := PanelContainer.new()
	bar.name = "StatusBar"
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	bar.add_child(hb)
	status_state = Label.new()
	status_state.add_theme_color_override("font_color", Design.TEXT_DIM)
	hb.add_child(status_state)
	status_msg = Label.new()
	status_msg.add_theme_color_override("font_color", Design.TEXT_DIM)
	status_msg.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hb.add_child(status_msg)
	var sp1 := Control.new(); sp1.size_flags_horizontal = Control.SIZE_EXPAND_FILL; hb.add_child(sp1)
	_project_label = Label.new()
	_project_label.add_theme_color_override("font_color", Design.TEXT)
	hb.add_child(_project_label)
	var sp2 := VSeparator.new(); hb.add_child(sp2)
	status_tool = Label.new()
	status_tool.add_theme_color_override("font_color", Design.TEXT_DIM)
	hb.add_child(status_tool)
	status_net = Label.new()
	status_net.add_theme_color_override("font_color", Design.ACCENT_SOFT)
	hb.add_child(status_net)
	status_zoom = Label.new()
	status_zoom.add_theme_color_override("font_color", Design.TEXT_DIM)
	hb.add_child(status_zoom)
	status_warn = Label.new()
	status_warn.add_theme_color_override("font_color", Design.WARN)
	hb.add_child(status_warn)
	_refresh_statusbar()
	return bar


# --- panel visibility + layout defaults ------------------------------------

func _apply_default_layout() -> void:
	if mid_split != null:
		mid_split.split_offset = 264
	if center_split != null:
		center_split.split_offset = max(120, int(center_split.size.y) - 210)


func _toggle_panel(which: String) -> void:
	match which:
		"left":
			left_panel.visible = not left_panel.visible
		"right":
			right_panel.visible = not right_panel.visible
		"bottom":
			bottom_panel.visible = not bottom_panel.visible
	_on_status("Toggled %s panel." % which)


func _refresh_statusbar() -> void:
	if status_state == null:
		return
	var state := "Idle"
	var col := Design.TEXT_DIM
	if session != null and session.last_result is Dictionary and session.last_result.get("ok", false):
		state = "Solved"
		col = Design.OK
	status_state.text = "\u25CF  %s" % state
	status_state.add_theme_color_override("font_color", col)
	if status_msg != null:
		status_msg.text = _status_text
	status_tool.text = "Tool: %s" % ("Wire" if wire_mode else ("Place: " + pending_type if pending_type != "" else "Select"))
	if camera != null:
		status_zoom.text = "Zoom: %.2f m" % camera.distance
	if session != null:
		var n := 0
		if session.last_result is Dictionary:
			n = int(session.last_result.get("builder_warnings", []).size()) + int(session.last_result.get("warnings", []).size())
		_warn_count = n
	status_warn.text = "" if _warn_count == 0 else "\u26A0 %d warning(s)" % _warn_count


func _build_scope() -> void:
	scope_window = Window.new()
	scope_window.theme = Design.theme()
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
	meter_window.theme = Design.theme()
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

func _refresh_categories() -> void:
	if cat_filter == null:
		return
	cat_filter.clear()
	cat_filter.add_item("All categories")
	cat_filter.add_item("Fully simulated")
	cat_filter.add_item("Simulatable")
	cat_filter.add_item("Arduino-compatible")
	cat_filter.add_item("Not yet simulated")
	for c in ComponentDB.categories():
		cat_filter.add_item(String(c))
	cat_filter.select(0)


func _on_category_selected(index: int) -> void:
	match index:
		0:
			_current_cat = "All"
		1:
			_current_cat = "@full"
		2:
			_current_cat = "@sim"
		3:
			_current_cat = "@arduino"
		4:
			_current_cat = "@notimpl"
		_:
			_current_cat = cat_filter.get_item_text(index)
	_refresh_library(search_field.text if search_field != null else "")


func _refresh_library(filter: String) -> void:
	if lib_list == null:
		return
	lib_list.clear()
	lib_defs.clear()
	var defs = ComponentDB.all_defs()
	var keys = defs.keys()
	keys.sort()
	var f = filter.strip_edges().to_lower()
	for t in keys:
		var d = defs[t]
		var cat := String(d.get("category", ""))
		var status := String(d.get("simulation_status", "full"))
		var arduino := bool(d.get("arduino_compatible", false))
		var simulatable := ComponentDB.is_simulatable(t)
		if _current_cat == "@full" and status != "full":
			continue
		if _current_cat == "@sim" and not simulatable:
			continue
		if _current_cat == "@notimpl" and simulatable:
			continue
		if _current_cat == "@arduino" and not arduino:
			continue
		if _current_cat != "All" and not _current_cat.begins_with("@"):
			if cat != _current_cat:
				continue
		if f != "":
			var hay := ("%s %s %s %s %s" % [String(d.name), t, cat, String(d.get("part_number", "")), String(d.get("description", ""))]).to_lower()
			if not hay.contains(f):
				continue
		var label := String(d.name)
		if not simulatable:
			label += "  \u00b7 %s" % ComponentDB.status_label(t)
		lib_list.add_item(label)
		lib_defs.append(t)
		lib_list.set_item_tooltip(lib_list.item_count - 1,
			"%s  \u2022  %s\n\n%s\n\nSimulation: %s" % [String(d.name), cat, String(d.get("description", "")), ComponentDB.status_label(t)])
	if lib_hint != null:
		lib_hint.text = "%d component(s) shown. Pick one, then click a breadboard hole." % lib_defs.size()


func _on_search(text: String) -> void:
	_refresh_library(text)


func _on_library_pick(index: int) -> void:
	if index < 0 or index >= lib_defs.size():
		return
	pending_type = lib_defs[index]
	wire_mode = false
	_refresh_statusbar()
	var d = ComponentDB.get_def(pending_type)
	var status := String(d.get("simulation_status", "full"))
	var note := ""
	if not ComponentDB.is_simulatable(pending_type):
		note = "  (%s - it will be placed but not solved)" % ComponentDB.status_label(pending_type).to_lower()
	elif status == "partial":
		note = "  (partially simulated)"
	_on_status("Placing %s - click a breadboard hole.%s" % [String(d.name), note])


## True when every component in an example has a working electrical model.
func _example_runnable(path: String) -> bool:
	var r = Persistence.load_from_file(path)
	if not r.ok:
		return false
	for c in r.project.get("components", []):
		if not ComponentDB.exists(String(c.type)) or not ComponentDB.is_simulatable(String(c.type)):
			return false
	return true


func _on_frame_all() -> void:
	var merged := AABB()
	var first := true
	for c in comp_root.get_children():
		var box = _node_aabb(c)
		if box == null:
			continue
		if first:
			merged = box
			first = false
		else:
			merged = merged.merge(box)
	if first:
		camera.focus_on(Vector3.ZERO, 3.2)
	else:
		camera.frame_box(merged.position, merged.end)


func _node_aabb(node: Node) -> Variant:
	var found := false
	var box := AABB()
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var local := mi.mesh.get_aabb()
		var t := Transform3D(_global_basis_of(mi), mi.global_position)
		var world := t * local
		if found:
			box = box.merge(world)
		else:
			box = world
			found = true
	return box if found else null


func _global_basis_of(node: Node3D) -> Basis:
	return node.global_transform.basis


# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------

func _work_pos(window_pos: Vector2) -> Vector2:
	# Map an event position (root-viewport space) into the 3D SubViewport's own
	# pixel space, so project_ray_* sees the same coordinates the camera renders.
	if workspace == null:
		return window_pos
	var rect := workspace.get_global_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return window_pos - rect.position
	var n := (window_pos - rect.position) / rect.size
	if viewport3d != null:
		return Vector2(n.x * float(viewport3d.size.x), n.y * float(viewport3d.size.y))
	return n * rect.size


func _handle_click(pos: Vector2) -> void:
	var local := _work_pos(pos)
	var from = camera.project_ray_origin(local)
	var dir = camera.project_ray_normal(local)
	var hole = bb_view.ray_nearest_hole(from, dir, 0.08)

	if pending_type != "":
		if hole != "":
			var pc = ComponentDB.pin_count(pending_type)
			var holes = bb_view.default_holes(pending_type, pc, hole)
			session.add_component(pending_type, holes)
			pending_type = ""
			_on_status("Component placed. Select it to edit properties.")
			_refresh_statusbar()
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
	_update_preview(pos)


func _component_at_hole(hole: String) -> String:
	for c in session.project.components:
		for h in c.holes:
			if String(h) == hole:
				return String(c.id)
	return ""


func _holes_to_positions(holes: Array) -> Array:
	var out := []
	for h in holes:
		out.append(bb_view.hole_positions.get(String(h), Vector3.ZERO))
	return out


func _clear_preview() -> void:
	if preview_root == null:
		return
	for c in preview_root.get_children():
		preview_root.remove_child(c)
		c.queue_free()


func _tint_ghost(node: Node, color: Color) -> void:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, 0.5)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 0.7
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = m
	for lbl in node.find_children("*", "Label3D", true, false):
		(lbl as Label3D).text = ""


## Show a translucent placement ghost (green = valid, red = blocked) or a wire
## rubber-band while the pointer is over the board. Hovering ANY board position
## keeps the electrical net alive: the net under the pointer stays highlighted.
func _update_preview(pos: Vector2) -> void:
	if preview_root == null or bb_view == null or camera == null:
		return
	_clear_preview()
	var placing: bool = pending_type != ""
	var wiring: bool = wire_mode and wire_start != null
	var local := _work_pos(pos)
	var from = camera.project_ray_origin(local)
	var dir = camera.project_ray_normal(local)
	var hole = bb_view.ray_nearest_hole(from, dir, 0.08)
	_hover_hole = hole
	if placing:
		if hole != "":
			var pc = ComponentDB.pin_count(pending_type)
			var holes = bb_view.default_holes(pending_type, pc, hole)
			var valid := true
			for h in holes:
				if _component_at_hole(String(h)) != "":
					valid = false
			var ghost = ComponentFactory.build(pending_type, _holes_to_positions(holes), false, {})
			_tint_ghost(ghost, Design.OK if valid else Design.ERR)
			preview_root.add_child(ghost)
	elif wiring:
		if hole != "" and wire_start != null:
			var a = _endpoint_world(wire_start)
			if a != null and bb_view.hole_positions.has(hole):
				_cylinder_between(a, bb_view.hole_positions[hole] + Vector3(0, 0.01, 0),
						0.008, Design.ACCENT, preview_root)
	_refresh_net_highlight()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_handle_click(mb.position)
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and mb.double_click:
			pass
	elif event is InputEventMouseMotion:
		_update_preview((event as InputEventMouseMotion).position)
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


func _on_simulation_updated(res: Dictionary) -> void:
	# Re-bake the 3D visuals: the factory reads I/V from the result, so LEDs
	# light up, labels update and switches show their driven state right after
	# a solve - not only after the next edit.
	_rebuild_3d()
	_update_labels()
	_show_measurements(res)
	_show_diagnostics(res)
	_refresh_meter()
	_refresh_statusbar()


func _rebuild_3d() -> void:
	if comp_root == null:
		return
	# Rebuild the net bookkeeping from the real netlist first: the wire colours
	# and the hover/selection net highlight are derived from it, so what the
	# user sees is the built netlist, not a decoration pretending to be one.
	var built = session.build_circuit()
	_hole_nets = built.get("hole_nets", {})
	_pin_nets = built.get("pin_nets", {})
	_net_members = _net_members_from(_hole_nets)

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
		var info := {"params": comp.params}
		var lres = session.last_result
		if lres is Dictionary and lres.get("ok", false):
			if lres.element_currents.has(String(comp.id)):
				info["current"] = float(lres.element_currents[String(comp.id)])
			if lres.element_voltages.has(String(comp.id)):
				info["voltage"] = float(lres.element_voltages[String(comp.id)])
		var node = ComponentFactory.build(String(comp.type), pin_positions, String(comp.id) == session.selected_id, info)
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
	_refresh_net_highlight()


# --- electrical net overlay ---------------------------------------------------

## Invert the hole->net map into net->members.
func _net_members_from(hole_nets: Dictionary) -> Dictionary:
	var members := {}
	for h in hole_nets.keys():
		var n := String(hole_nets[h])
		if n == "":
			continue
		if not members.has(n):
			members[n] = []
		members[n].append(String(h))
	return members


## The nets the selected component's pins sit on (empty when nothing selected).
func _selection_nets() -> Array:
	if session == null or String(session.selected_id) == "":
		return []
	for comp in session.project.components:
		if String(comp.id) != String(session.selected_id):
			continue
		var nets := []
		for h in comp.holes:
			var n := String(_hole_nets.get(String(h), ""))
			if n != "" and not nets.has(n):
				nets.append(n)
		return nets
	return []


## Reapply the point highlight: hover wins, then the selected component's nets,
## then a clean board. This is what keeps "what I see" == "what the netlist is".
func _refresh_net_highlight() -> void:
	if bb_view == null:
		return
	var h := String(_hover_hole)
	if h != "" and _hole_nets.get(h, "") != "":
		var net := String(_hole_nets.get(h, ""))
		var members: Array = _net_members.get(net, [])
		bb_view.set_highlight(members, [h])
		if status_net != null:
			status_net.text = "Net %s  (%d terminal%s)" % [net, members.size(), "s" if members.size() != 1 else ""]
		return
	var nets := _selection_nets()
	if nets.is_empty():
		bb_view.set_highlight([], [])
		if status_net != null:
			status_net.text = ""
		return
	var holes := []
	for n in nets:
		holes.append_array(_net_members.get(String(n), []))
	bb_view.set_highlight(holes, [])
	if status_net != null:
		status_net.text = "Selected nets: %s" % ", ".join(nets)


func _draw_wire(w: Dictionary) -> void:
	var a = _endpoint_world(w.a)
	var b = _endpoint_world(w.b)
	if a == null or b == null:
		return
	_wire_curve(a, b, _wire_color(w), wire_root)


func _ep_key(ep) -> String:
	if typeof(ep) != TYPE_DICTIONARY:
		return "?"
	var k = String(ep.get("kind", ""))
	if k == "hole":
		return "h:" + String(ep.get("id", ""))
	return "c:" + String(ep.get("component", "")) + ":" + str(ep.get("pin", 0))


## Wire colour follows the ELECTRICAL net: two wires on the same net match,
## distinct nets get distinct colours, so the drawing agrees with the netlist.
## (Falls back to the endpoint hash if the net is not yet known.)
func _wire_color(w: Dictionary) -> Color:
	var net := _endpoint_net(w.get("a", {}))
	if net == "":
		net = _endpoint_net(w.get("b", {}))
	if net != "":
		return WIRE_PALETTE[absi(net.hash()) % WIRE_PALETTE.size()]
	var key := _ep_key(w.get("a")) + "|" + _ep_key(w.get("b"))
	return WIRE_PALETTE[absi(key.hash()) % WIRE_PALETTE.size()]


## Net name an endpoint belongs to, from the last real netlist build.
func _endpoint_net(ep) -> String:
	if typeof(ep) != TYPE_DICTIONARY:
		return ""
	if String(ep.get("kind", "")) == "hole":
		return String(_hole_nets.get(String(ep.get("id", "")), ""))
	var cid := String(ep.get("component", ""))
	var pin := int(ep.get("pin", 0))
	var nets: Array = _pin_nets.get(cid, [])
	if pin >= 0 and pin < nets.size():
		return String(nets[pin])
	return ""


## Draw a wire as a shallow arched curve (insulation sags, then lifts at the ends).
func _wire_curve(a: Vector3, b: Vector3, color: Color, parent: Node3D) -> void:
	var segs := 12
	var lift := 0.015 + a.distance_to(b) * 0.05
	var prev := a + Vector3(0, 0.012, 0)
	for i in range(1, segs + 1):
		var t := float(i) / float(segs)
		var p := a.lerp(b, t)
		p.y += 0.012 + sin(t * PI) * lift
		_cylinder_between(prev, p, 0.0105, color, parent)
		prev = p


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
	_clear_preview()
	_on_status("Wire mode %s." % ("ON - click two holes" if wire_mode else "OFF"))
	_refresh_statusbar()

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
	camera.focus_on(Vector3(0, 0, 0), 2.4)

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
	_status_text = text
	if status_msg != null:
		status_msg.text = text
	if status_state != null:
		status_state.tooltip_text = text


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
