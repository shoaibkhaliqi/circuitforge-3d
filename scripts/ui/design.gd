extends RefCounted
## CircuitForge 3D - central visual design system.
##
## One palette, one Theme and a set of small reusable widgets so every panel,
## button and label looks consistent. Built at runtime because the UI is created
## in code. Import this and call `Design.theme()` on the UI root.
##
## Visual language: dark graphite "laboratory instrument" theme, restrained cyan
## accent, colour reserved for state (running / warning / error / selection).

# --- Palette ---------------------------------------------------------------

const BG_VOID := Color("0e1116")        # behind everything / 3D backdrop
const BG_PANEL := Color("161a21")       # side + bottom panels
const BG_PANEL_2 := Color("1e232b")     # raised headers, toolbars
const BG_INPUT := Color("11151b")       # text fields, list backgrounds
const BG_SUNKEN := Color("0b0e12")      # console / code areas

const BORDER := Color("2a313b")
const BORDER_STRONG := Color("3a4350")

const TEXT := Color("e3e8ef")
const TEXT_DIM := Color("9aa6b6")
const TEXT_MUTED := Color("6b7684")

const ACCENT := Color("4cc2ff")
const ACCENT_DEEP := Color("1f7aa8")
const ACCENT_SOFT := Color("8fd8ff")

const OK := Color("3fd68a")
const WARN := Color("ffb74d")
const ERR := Color("ff6b6b")
const SELECT := Color("2b6f9c")

const FONT_SMALL := 12
const FONT_BASE := 14
const FONT_LABEL := 13
const FONT_TITLE := 16
const FONT_H2 := 20

const PAD := 10
const PAD_S := 6
const RADIUS := 6

# --- Theme -----------------------------------------------------------------

static var _theme: Theme = null


static func sb(bg: Color, border: Color, radius: int = RADIUS, bw: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	if bw > 0:
		s.set_border_width_all(bw)
		s.border_color = border
	s.content_margin_left = PAD
	s.content_margin_right = PAD
	s.content_margin_top = PAD_S
	s.content_margin_bottom = PAD_S
	return s


static func _sb_plain(bg: Color, radius: int = RADIUS) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	return s


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font_size = FONT_BASE

	# --- Label
	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", FONT_BASE)

	# --- PanelContainer
	var p := sb(BG_PANEL, BORDER)
	t.set_stylebox("panel", "PanelContainer", p)

	# --- Panel (plain)
	var pp := sb(BG_PANEL, BORDER)
	t.set_stylebox("panel", "Panel", pp)

	# --- Button
	var b_normal := sb(BG_PANEL_2, BORDER_STRONG)
	b_normal.content_margin_left = 12
	b_normal.content_margin_right = 12
	b_normal.content_margin_top = 7
	b_normal.content_margin_bottom = 7
	var b_hover := sb(Color("2a323d"), ACCENT_DEEP)
	b_hover.content_margin_left = 12
	b_hover.content_margin_right = 12
	b_hover.content_margin_top = 7
	b_hover.content_margin_bottom = 7
	var b_pressed := sb(ACCENT_DEEP, ACCENT)
	b_pressed.content_margin_left = 12
	b_pressed.content_margin_right = 12
	b_pressed.content_margin_top = 7
	b_pressed.content_margin_bottom = 7
	var b_disabled := sb(BG_PANEL, BORDER)
	b_disabled.content_margin_left = 12
	b_disabled.content_margin_right = 12
	b_disabled.content_margin_top = 7
	b_disabled.content_margin_bottom = 7
	var b_focus := sb(Color(0, 0, 0, 0), ACCENT, RADIUS, 1)
	t.set_stylebox("normal", "Button", b_normal)
	t.set_stylebox("hover", "Button", b_hover)
	t.set_stylebox("pressed", "Button", b_pressed)
	t.set_stylebox("disabled", "Button", b_disabled)
	t.set_stylebox("focus", "Button", b_focus)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", ACCENT_SOFT)
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", TEXT_MUTED)
	t.set_font_size("font_size", "Button", FONT_BASE)

	# --- OptionButton (uses Button styles + these)
	t.set_color("font_color", "OptionButton", TEXT)
	t.set_color("font_hover_color", "OptionButton", ACCENT_SOFT)
	t.set_font_size("font_size", "OptionButton", FONT_BASE)

	# --- LineEdit
	var le := sb(BG_INPUT, BORDER_STRONG, RADIUS, 1)
	le.content_margin_top = 5
	le.content_margin_bottom = 5
	var le_focus := sb(BG_INPUT, ACCENT, RADIUS, 1)
	le_focus.content_margin_top = 5
	le_focus.content_margin_bottom = 5
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", le_focus)
	t.set_stylebox("read_only", "LineEdit", sb(BG_SUNKEN, BORDER))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", TEXT_MUTED)
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", SELECT)
	t.set_font_size("font_size", "LineEdit", FONT_BASE)

	# --- TextEdit / CodeEdit (console + editor)
	t.set_stylebox("normal", "TextEdit", sb(BG_SUNKEN, BORDER))
	t.set_stylebox("focus", "TextEdit", sb(BG_SUNKEN, ACCENT_DEEP))
	t.set_color("font_color", "TextEdit", TEXT)
	t.set_font_size("font_size", "TextEdit", FONT_BASE)

	# --- RichTextLabel
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_font_size("normal_font_size", "RichTextLabel", FONT_BASE)
	t.set_stylebox("normal", "RichTextLabel", _sb_plain(BG_PANEL))
	t.set_stylebox("focus", "RichTextLabel", _sb_plain(BG_PANEL))

	# --- ItemList (component browser)
	t.set_stylebox("panel", "ItemList", sb(BG_INPUT, BORDER))
	t.set_stylebox("focus", "ItemList", sb(BG_INPUT, ACCENT_DEEP))
	t.set_stylebox("selected", "ItemList", _sb_plain(SELECT))
	t.set_stylebox("selected_focus", "ItemList", _sb_plain(SELECT))
	t.set_stylebox("hovered", "ItemList", _sb_plain(Color("222934")))
	t.set_stylebox("cursor", "ItemList", _sb_plain(BG_PANEL))
	t.set_stylebox("cursor_unfocused", "ItemList", _sb_plain(BG_PANEL))
	t.set_color("font_color", "ItemList", TEXT)
	t.set_color("font_selected_color", "ItemList", Color.WHITE)
	t.set_color("font_hovered_color", "ItemList", ACCENT_SOFT)
	t.set_font_size("font_size", "ItemList", FONT_BASE)
	t.set_constant("h_separation", "ItemList", 4)

	# --- Tree (used by future inspectors)
	t.set_stylebox("panel", "Tree", sb(BG_INPUT, BORDER))
	t.set_color("font_color", "Tree", TEXT)
	t.set_color("font_selected_color", "Tree", Color.WHITE)
	t.set_stylebox("selected", "Tree", _sb_plain(SELECT))
	t.set_stylebox("selected_focus", "Tree", _sb_plain(SELECT))
	t.set_stylebox("focus", "Tree", _sb_plain(Color(0, 0, 0, 0)))

	# --- ScrollBar
	var grab := _sb_plain(Color("39424e"), 4)
	grab.content_margin_left = 0
	grab.content_margin_right = 0
	t.set_stylebox("scroll", "VScrollBar", _sb_plain(Color("161a21")))
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", _sb_plain(ACCENT_DEEP, 4))
	t.set_stylebox("grabber_pressed", "VScrollBar", _sb_plain(ACCENT_DEEP, 4))
	var grabh := _sb_plain(Color("39424e"), 4)
	t.set_stylebox("scroll", "HScrollBar", _sb_plain(Color("161a21")))
	t.set_stylebox("grabber", "HScrollBar", grabh)
	t.set_stylebox("grabber_highlight", "HScrollBar", _sb_plain(ACCENT_DEEP, 4))
	t.set_stylebox("grabber_pressed", "HScrollBar", _sb_plain(ACCENT_DEEP, 4))

	# --- Separators
	var sep := StyleBoxLine.new()
	sep.color = BORDER
	sep.thickness = 1
	t.set_stylebox("separator", "VSeparator", sep)
	t.set_stylebox("separator", "HSeparator", sep)

	# --- SplitContainer grabber
	var sp := StyleBoxFlat.new()
	sp.bg_color = Color(0.16, 0.18, 0.21, 0.0)
	sp.content_margin_left = 2
	sp.content_margin_right = 2
	t.set_stylebox("grabber", "HSplitContainer", sp)
	t.set_stylebox("grabber", "VSplitContainer", sp)

	# --- PopupMenu / Window chrome
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_font_size("font_size", "PopupMenu", FONT_BASE)
	t.set_stylebox("panel", "PopupMenu", sb(BG_PANEL_2, BORDER_STRONG))
	t.set_color("font_color", "Window", TEXT)
	t.set_font_size("title_font_size", "Window", FONT_SMALL)

	# --- TabContainer
	t.set_stylebox("panel", "TabContainer", sb(BG_PANEL, BORDER))
	t.set_color("font_selected_color", "TabContainer", ACCENT_SOFT)
	t.set_color("font_unselected_color", "TabContainer", TEXT_DIM)
	t.set_font_size("font_size", "TabContainer", FONT_BASE)

	# --- Tooltip
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", FONT_SMALL)
	t.set_stylebox("panel", "TooltipPanel", sb(BG_PANEL_2, ACCENT_DEEP))

	_theme = t
	return t


# --- Small reusable widgets -------------------------------------------------

## A titled, bordered panel. Returns the inner VBoxContainer for content.
static func section(title: String) -> Dictionary:
	var panel := PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", PAD_S)
	panel.add_child(vb)

	if title != "":
		var head := HBoxContainer.new()
		var bar := ColorRect.new()
		bar.color = ACCENT
		bar.custom_minimum_size = Vector2(3, 16)
		head.add_child(bar)
		var lbl := Label.new()
		lbl.text = title.to_upper()
		lbl.add_theme_font_size_override("font_size", FONT_LABEL)
		lbl.add_theme_color_override("font_color", TEXT_DIM)
		head.add_child(lbl)
		vb.add_child(head)

	return {"panel": panel, "body": vb}


static func heading(text: String, size: int = FONT_TITLE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", TEXT)
	return l


static func hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", FONT_SMALL)
	l.add_theme_color_override("font_color", TEXT_MUTED)
	return l


static func status_dot(color: Color, size: float = 10.0) -> Panel:
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(size, size)
	var st := StyleBoxFlat.new()
	st.bg_color = color
	st.set_corner_radius_all(int(size / 2.0))
	dot.add_theme_stylebox_override("panel", st)
	return dot


## Build a status colour from a component's simulation status string.
static func status_color(status: String) -> Color:
	match status:
		"full":
			return OK
		"partial":
			return WARN
		"visual":
			return TEXT_MUTED
		_:
			return TEXT_MUTED
