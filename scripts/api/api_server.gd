extends SceneTree
## CircuitForge 3D - local API host.
##
## Runs the application service layer head-less and exposes it over a
## line-delimited JSON protocol on a loopback TCP socket. This is the
## "circuitforge-local-api/1" transport used by the Python MCP adapter (and by
## integration tests). It never renders and needs no window.
##
## Launch:
##   godot --headless --path <project> --script res://scripts/api/api_server.gd \
##         -- --port 0 [--disconnect-grace 5] [--idle-timeout 0]
##
## The chosen port and a random per-run auth token are announced on stdout as:
##   CIRCUITFORGE-API-READY {"protocol":"...","port":N,"token":"..."}
##
## Protocol (one JSON object per line):
##   request : {"jsonrpc":"2.0","id":<n>,"auth":"<token>","method":"<name>","params":{...}}
##   response: {"jsonrpc":"2.0","id":<n>,"result":{...}}   (result.success tells success)
##             {"jsonrpc":"2.0","id":<n>,"error":{"code":<int>,"message":"..."}}
##
## Lifecycle: the host exits when the client sends `shutdown`, or when every
## authenticated client has disconnected for `disconnect-grace` seconds (so it
## never outlives the MCP adapter that spawned it).
##
## Security: binds loopback only, requires the token on every call, caps request
## size, refuses to run arbitrary code, and never exposes a public listener.

const AppService = preload("res://scripts/api/app_service.gd")

const MAX_LINE := 1000000
const READY_TOKEN := "CIRCUITFORGE-API-READY"

var _service
var _server := TCPServer.new()
var _conns: Array = []
var _token := ""
var _disconnect_grace := 5.0
var _idle_timeout := 0.0
var _last_activity := 0.0
var _disconnect_since := -1.0
var _ever_connected := false
var _quit := false


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var port := int(args.get("port", 0))
	_disconnect_grace = float(args.get("disconnect-grace", 5))
	_idle_timeout = float(args.get("idle-timeout", 0))
	var cr := Crypto.new()
	_token = cr.generate_random_bytes(16).hex_encode()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		printerr("CIRCUITFORGE-API-ERROR listen failed on port %d (%d)" % [port, err])
		quit(2)
		return
	_service = AppService.new()
	_last_activity = Time.get_ticks_msec() / 1000.0
	var ready := {
		"protocol": AppService.API_PROTOCOL,
		"app_version": AppService.APP_VERSION,
		"port": _server.get_local_port(),
		"token": _token,
	}
	print(READY_TOKEN + " " + JSON.stringify(ready))
	printerr("CircuitForge local API listening on 127.0.0.1:%d" % _server.get_local_port())


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := String(argv[i])
		if a.begins_with("--"):
			var key := a.substr(2)
			var val := ""
			if i + 1 < argv.size() and not String(argv[i + 1]).begins_with("--"):
				val = String(argv[i + 1])
				i += 1
			out[key] = val
		i += 1
	return out


func _process(_delta: float) -> bool:
	if _quit:
		return true
	_accept()
	_service_connections()
	_check_lifecycle()
	return false


func _accept() -> void:
	while true:
		var c := _server.take_connection()
		if c == null:
			return
		c.set_no_delay(true)
		_conns.append({"c": c, "buf": ""})
		_ever_connected = true
		_disconnect_since = -1.0


func _service_connections() -> void:
	for i in range(_conns.size() - 1, -1, -1):
		var entry: Dictionary = _conns[i]
		var c: StreamPeerTCP = entry.c
		c.poll()
		if c.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_conns.remove_at(i)
			continue
		var avail := c.get_available_bytes()
		if avail > 0:
			entry.buf = String(entry.buf) + c.get_utf8_string(avail)
			_last_activity = Time.get_ticks_msec() / 1000.0
		if String(entry.buf).length() > MAX_LINE:
			_send_error(c, null, -32600, "Request too large.")
			_conns.remove_at(i)
			continue
		while String(entry.buf).contains("\n"):
			var idx: int = String(entry.buf).find("\n")
			var line: String = String(entry.buf).substr(0, idx)
			entry.buf = String(entry.buf).substr(idx + 1)
			if line.strip_edges() != "":
				_handle(c, line)


func _check_lifecycle() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _conns.is_empty():
		if _ever_connected and _disconnect_since < 0.0:
			_disconnect_since = now
		if _ever_connected and _disconnect_grace >= 0.0 and _disconnect_since >= 0.0:
			if now - _disconnect_since > _disconnect_grace:
				_quit = true
	else:
		_disconnect_since = -1.0
	if _idle_timeout > 0.0 and now - _last_activity > _idle_timeout:
		_quit = true


# ---------------------------------------------------------------------------
# Request handling
# ---------------------------------------------------------------------------

func _handle(c: StreamPeerTCP, line: String) -> void:
	var req = JSON.parse_string(line)
	if typeof(req) != TYPE_DICTIONARY:
		_send_error(c, null, -32700, "Parse error: not a JSON object.")
		return
	var id = req.get("id", null)
	if String(req.get("auth", "")) != _token:
		_send_error(c, id, -32600, "Unauthorized.")
		return
	var method := String(req.get("method", ""))
	var params: Dictionary = req.get("params", {}) if typeof(req.get("params", {})) == TYPE_DICTIONARY else {}
	var result := _dispatch(method, params)
	if result.has("_proto_error"):
		_send_error(c, id, int(result._proto_error.code), String(result._proto_error.message))
		return
	_send_result(c, id, result)


func _dispatch(method: String, p: Dictionary) -> Dictionary:
	match method:
		"ping":
			return _service._ok({"pong": true})
		"get_simulator_info":
			return _service.get_simulator_info()
		"get_capabilities":
			return _service.get_capabilities()
		"get_component_catalog":
			return _service.get_component_catalog(String(p.get("category", "")), String(p.get("search", "")), p.get("filters", {}))
		"get_catalog_facets":
			return _service.get_catalog_facets()
		"get_board_pinout":
			return _service.get_board_pinout(String(p.get("type", p.get("board", ""))))
		"get_pin_states":
			return _service.get_pin_states()
		"set_pin_levels":
			return _service.set_pin_levels(p.get("levels", {}), bool(p.get("simulate", false)), p.get("expected_revision", null))
		"get_firmware_capabilities":
			return _service.get_firmware_capabilities()
		"run_firmware":
			return _service.run_firmware(String(p.get("hex_path", "")), int(p.get("ms", 2000)),
				bool(p.get("attach_devices", false)), p.get("analog_map", {}),
				p.get("pin_map", {}))
		"apply_firmware_pins":
			return _service.apply_firmware_pins(
				String(p.get("hex_path", "")), p.get("pin_map", {}),
				int(p.get("ms", 2000)), float(p.get("at_ms", -1.0)),
				bool(p.get("simulate", false)), p.get("expected_revision", null))
		"apply_firmware_device":
			return _service.apply_firmware_device(
				String(p.get("hex_path", "")), String(p.get("component_id", "")),
				int(p.get("ms", 2000)), bool(p.get("simulate", false)),
				p.get("expected_revision", null))
		"apply_firmware_pwm":
			return _service.apply_firmware_pwm(
				String(p.get("hex_path", "")), p.get("pin_map", {}),
				int(p.get("ms", 2000)), float(p.get("vlogic", 5.0)),
				bool(p.get("simulate", false)), p.get("expected_revision", null))
		"apply_firmware_servo":
			return _service.apply_firmware_servo(
				String(p.get("hex_path", "")), p.get("pin_map", {}),
				int(p.get("ms", 3000)), bool(p.get("simulate", false)),
				p.get("expected_revision", null))
		"get_project_summary":
			return _service.get_project_summary()
		"list_components":
			return _service.list_components(String(p.get("type_filter", p.get("component_type", ""))), int(p.get("limit", 500)), int(p.get("offset", 0)))
		"get_component":
			return _service.get_component(String(p.get("component_id", "")))
		"get_connections":
			return _service.get_connections()
		"get_node_voltage":
			return _service.get_node_voltage(String(p.get("node", p.get("node_id", ""))))
		"get_branch_current":
			return _service.get_branch_current(String(p.get("branch", p.get("component_id", ""))))
		"get_simulation_results":
			return _service.get_simulation_results(String(p.get("filter", "")), int(p.get("limit", 500)), int(p.get("offset", 0)))
		"get_simulation_status":
			return _service.get_simulation_status()
		"get_waveform_data":
			return _service.get_waveform_data(String(p.get("target", "")), String(p.get("kind", "node")), int(p.get("max_samples", 2000)))
		"get_diagnostics":
			return _service.get_diagnostics()
		"get_solver_info":
			return _service.get_solver_info()
		"get_circuit_text":
			return _service.get_circuit_text()
		"get_edit_preview":
			return _service.get_edit_preview(String(p.get("operation", "")), p.get("arguments", {}))
		"create_project":
			return _service.create_project(String(p.get("name", "Untitled")), String(p.get("operation_id", "")))
		"add_component":
			return _service.add_component(
				String(p.get("component_type", "")),
				String(p.get("name", "")),
				p.get("holes", []),
				float(p.get("orientation", 0.0)),
				p.get("parameters", {}),
				String(p.get("operation_id", "")))
		"update_component_parameters":
			return _service.update_component_parameters(String(p.get("component_id", "")), p.get("parameters", {}), p.get("expected_revision", null))
		"move_component":
			return _service.move_component(String(p.get("component_id", "")), p.get("holes", []), p.get("orientation", null), p.get("expected_revision", null))
		"remove_component":
			return _service.remove_component(String(p.get("component_id", "")), bool(p.get("confirm", false)), p.get("expected_revision", null), String(p.get("operation_id", "")))
		"connect_terminals":
			return _service.connect_terminals(p.get("a", {}), p.get("b", {}), p.get("expected_revision", null))
		"disconnect_connection":
			return _service.disconnect_connection(String(p.get("connection_id", "")), p.get("expected_revision", null))
		"clear_circuit":
			return _service.clear_circuit(bool(p.get("confirm", false)), p.get("expected_revision", null))
		"validate_circuit":
			return _service.get_diagnostics()
		"run_dc_simulation":
			return _service.run_dc_simulation()
		"run_transient_simulation":
			return _service.run_transient_simulation(
				float(p.get("t_start", 0.0)), float(p.get("t_stop", 0.5)),
				float(p.get("dt", 1e-3)), p.get("probes", []))
		"stop_simulation":
			return _service.stop_simulation()
		"save_project":
			return _service.save_project(String(p.get("path", "")), p.get("expected_revision", null))
		"load_project":
			return _service.load_project(String(p.get("path", "")), p.get("expected_revision", null))
		"list_example_projects":
			return _service.list_example_projects()
		"load_example_project":
			return _service.load_example_project(String(p.get("name", "")))
		"shutdown":
			_quit = true
			return _service._ok({"shutdown": true})
		_:
			return {"_proto_error": {"code": -32601, "message": "Method not found: " + method}}


func _send_result(c: StreamPeerTCP, id, result: Dictionary) -> void:
	c.put_data((JSON.stringify({"jsonrpc": "2.0", "id": id, "result": result}) + "\n").to_utf8_buffer())


func _send_error(c: StreamPeerTCP, id, code: int, message: String) -> void:
	c.put_data((JSON.stringify({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}) + "\n").to_utf8_buffer())
