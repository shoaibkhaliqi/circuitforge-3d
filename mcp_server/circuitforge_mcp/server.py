"""CircuitForge 3D MCP server.

Exposes the simulator's application service layer to MCP-compatible AI agents
over stdio. All circuit state lives in a single authoritative engine process that
this adapter drives through the versioned local API; the adapter never touches
graphics or scene internals.

Transport: stdio only. Protocol messages go to stdout; every diagnostic goes to
stderr. There is no network listener in this process.
"""

from __future__ import annotations

import json
import sys
import threading
from contextlib import asynccontextmanager
from typing import Any

import anyio
from mcp.server.mcpserver import MCPServer
from mcp_types import CallToolResult, TextContent, ToolAnnotations

from .engine_client import (
    ADAPTER_VERSION,
    LOCAL_API_PROTOCOL,
    EngineClient,
    EngineError,
    find_godot,
    find_project,
)

SERVER_NAME = "circuitforge-3d"
SERVER_VERSION = "0.1.0"

_engine: EngineClient | None = None
_engine_guard = threading.Lock()


# ---------------------------------------------------------------------------
# Engine plumbing
# ---------------------------------------------------------------------------

def get_engine() -> EngineClient:
    global _engine
    with _engine_guard:
        if _engine is None:
            _engine = EngineClient()
            _engine.start()
        return _engine


def close_engine() -> None:
    global _engine
    with _engine_guard:
        if _engine is not None:
            _engine.close()
            _engine = None


def call_engine(method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """Call the engine, converting any failure into a structured error result."""
    try:
        return get_engine().call(method, params or {})
    except EngineError as exc:
        return {"success": False, "error": exc.to_dict()}
    except Exception as exc:  # pragma: no cover - defensive
        return {
            "success": False,
            "error": {
                "code": "ENGINE_UNAVAILABLE",
                "message": f"Unexpected adapter error: {exc}",
                "suggested_action": "Restart the MCP server and check its stderr log.",
            },
        }


def _ok(payload: dict[str, Any]) -> CallToolResult:
    return CallToolResult(
        content=[TextContent(type="text", text=json.dumps(payload, indent=2, default=str))],
        structured_content=payload,
        is_error=False,
    )


def _err(payload: dict[str, Any]) -> CallToolResult:
    error = payload.get("error") if isinstance(payload, dict) else None
    if not isinstance(error, dict):
        error = {"code": "INTERNAL", "message": str(payload)}
        payload = {"success": False, "error": error}
    return CallToolResult(
        content=[TextContent(type="text", text=json.dumps(payload, indent=2, default=str))],
        structured_content=payload,
        is_error=True,
    )


def _wrap(result: dict[str, Any]) -> CallToolResult:
    if isinstance(result, dict) and result.get("success"):
        return _ok(result)
    return _err(result)


def _ro() -> ToolAnnotations:
    return ToolAnnotations(read_only_hint=True, open_world_hint=False)


def _edit(destructive: bool = False) -> ToolAnnotations:
    return ToolAnnotations(read_only_hint=False, destructive_hint=destructive, open_world_hint=False)


@asynccontextmanager
async def lifespan(_server: MCPServer):
    print(f"[{SERVER_NAME}] starting; godot={find_godot()} project={find_project()}",
          file=sys.stderr)
    try:
        await anyio.to_thread.run_sync(get_engine)
        print(f"[{SERVER_NAME}] engine ready on 127.0.0.1:{get_engine().port}", file=sys.stderr)
    except Exception as exc:
        print(f"[{SERVER_NAME}] engine unavailable: {exc}", file=sys.stderr)
    try:
        yield {}
    finally:
        close_engine()
        print(f"[{SERVER_NAME}] stopped", file=sys.stderr)


mcp = MCPServer(
    name=SERVER_NAME,
    title="CircuitForge 3D",
    description="Inspect, edit and simulate 3D breadboard circuits with a real MNA solver.",
    version=SERVER_VERSION,
    instructions=(
        "CircuitForge 3D drives a real modified-nodal-analysis circuit solver. "
        "Use get_component_catalog to discover components, add_component + "
        "connect_terminals to build a circuit, validate_circuit to check it, then "
        "run_dc_simulation / run_transient_simulation and read results with "
        "get_node_voltage, get_branch_current or get_simulation_results. "
        "All ids are stable; prefer ids over names. Editing tools support "
        "optimistic concurrency via expected_revision (read it from "
        "get_project_summary). Destructive tools require confirm=true."
    ),
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# A. Application discovery
# ---------------------------------------------------------------------------

@mcp.tool(annotations=_ro(), structured_output=True)
def get_simulator_info() -> dict[str, Any]:
    """Return simulator identity, versions, capabilities and current state."""
    res = call_engine("get_simulator_info")
    if res.get("success"):
        res["mcp_server"] = SERVER_NAME
        res["mcp_adapter_version"] = ADAPTER_VERSION
        res["local_api_protocol"] = LOCAL_API_PROTOCOL
        res["transport"] = "stdio"
    return _wrap(res)


@mcp.tool(annotations=_ro(), structured_output=True)
def get_capabilities() -> dict[str, Any]:
    """Return a machine-readable list of supported operations and their limits."""
    res = call_engine("get_capabilities")
    if res.get("success"):
        res["mcp_adapter_version"] = ADAPTER_VERSION
    return _wrap(res)


@mcp.tool(annotations=_ro(), structured_output=True)
def get_component_catalog(
    category: str = "",
    search: str = "",
    subcategory: str = "",
    status: str = "",
    protocol: str = "",
    interface: str = "",
    manufacturer: str = "",
    mounting: str = "",
    arduino_compatible: bool = False,
    simulatable_only: bool = False,
    limit: int = 0,
    offset: int = 0,
) -> dict[str, Any]:
    """List component definitions (type id, pins, parameters, ranges, models, status).

    Args:
        category: Optional category filter (e.g. "Passive", "Board").
        search: Optional case-insensitive search over name/id/keywords/description.
        subcategory: Optional subcategory filter (e.g. "Environmental").
        status: Optional simulation-status filter: full/partial/visual/external/planned.
        protocol: Optional protocol filter (e.g. "I2C", "SPI").
        interface: Optional interface filter (e.g. "USB").
        manufacturer: Optional manufacturer filter.
        mounting: Optional mounting filter: tht/smd/module/board/device/virtual.
        arduino_compatible: Only return Arduino-compatible parts.
        simulatable_only: Only return parts with a working solver model (full/partial).
        limit: Max items to return (0 = all).
        offset: Pagination offset.
    """
    filters = {
        "subcategory": subcategory, "status": status, "protocol": protocol,
        "interface": interface, "manufacturer": manufacturer, "mounting": mounting,
        "arduino_compatible": arduino_compatible, "simulatable_only": simulatable_only,
        "limit": limit, "offset": offset,
    }
    return _wrap(call_engine("get_component_catalog",
                             {"category": category, "search": search, "filters": filters}))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_catalog_facets() -> dict[str, Any]:
    """Return catalog facets (categories, statuses, protocols, ...) and validation errors."""
    return _wrap(call_engine("get_catalog_facets"))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_board_pinout(type: str) -> dict[str, Any]:
    """Return a development board's documented pin map, grouped by type.

    Covers Arduino, ESP, Pico, Raspberry Pi, STM32, Teensy and similar boards.
    The pin map is descriptive metadata (name, electrical type, header position);
    it does not imply the board is simulated.

    Args:
        type: Board type id (e.g. "arduino_uno_r3", "esp32_devkit_v1").
    """
    return _wrap(call_engine("get_board_pinout", {"type": type}))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_pin_states() -> dict[str, Any]:
    """Return the state of every virtual MCU pin (mcu_pin) in the circuit.

    Each entry gives the pin's level (-1 = high-Z input, 0 = low, 1 = high), its
    logic voltage and output resistance, the node it drives, and its solved
    voltage when a DC simulation is available. Stage A pins are ideal drivers;
    they do not run firmware.
    """
    return _wrap(call_engine("get_pin_states"))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_firmware_capabilities() -> dict[str, Any]:
    """Report whether optional firmware execution is available.

    The firmware backend is external and optional: it runs a compiled Arduino
    Intel-HEX on avr8js (MIT) through Node. Returns availability, the engine and
    its license, the boards covered (AVR/Arduino only) and, when unavailable, why
    (e.g. Node not installed). Nothing GPL is bundled.
    """
    return _wrap(call_engine("get_firmware_capabilities"))


@mcp.tool(annotations=_ro(), structured_output=True)
def run_firmware(
    hex_path: str,
    ms: int = 2000,
    attach_devices: bool = False,
    analog_map: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Run a compiled Arduino HEX and return its digital pin activity and UART output.

    This is the open-loop (Stage B) workflow: no analog feedback yet. Compile a
    sketch first, e.g. `arduino-cli compile --fqbn arduino:avr:uno --output-dir
    build/blink firmware/sketches/blink`, then pass the `.hex` path. Returns the
    pin transitions (time in ms, level 0/1), the pins the firmware touched, any
    bytes the sketch printed to Serial (USART0) as `serial` / `serial_lines`, and
    I2C/SPI bus traces (`i2c` transactions with address/data, `i2c_addresses`,
    `spi_bytes`).

    With `attach_devices=True` the circuit's device components (currently the
    `pcf8574`, using its `state`/`inputs`/`address` parameters) are attached to the
    emulated bus, so firmware can *read* them (device -> firmware feedback, e.g.
    `Wire.requestFrom`); the response adds `devices` and `attached_devices`. With
    no devices the harness only ACKs I2C and reads return 0xFF.

    With `analog_map` the circuit is solved and each mapped `mcu_analog_in`
    component's node voltage is fed to the firmware's ADC, so `analogRead()` reads
    the real circuit (circuit -> firmware analog feedback). The map is firmware
    analog pin -> component id, e.g. `{"A0": "AIN1"}`; the response adds `adc` and
    `analog_inputs`.

    Args:
        hex_path: Path to an Intel-HEX produced for an AVR board.
        ms: Emulated run length in milliseconds (1..10000).
        attach_devices: Attach the circuit's bus devices so firmware can read them.
        analog_map: Firmware analog pin -> `mcu_analog_in` component id.
    """
    return _wrap(call_engine("run_firmware", {
        "hex_path": hex_path, "ms": ms, "attach_devices": attach_devices,
        "analog_map": analog_map or {},
    }))


# ---------------------------------------------------------------------------
# B. Circuit inspection
# ---------------------------------------------------------------------------

@mcp.tool(annotations=_ro(), structured_output=True)
def get_project_summary() -> dict[str, Any]:
    """Return project id, counts, validation status, simulation state and revision."""
    return _wrap(call_engine("get_project_summary"))


@mcp.tool(annotations=_ro(), structured_output=True)
def list_components(type_filter: str = "", limit: int = 500, offset: int = 0) -> dict[str, Any]:
    """List components with ids, types, parameters, positions and terminals."""
    return _wrap(call_engine("list_components", {"type_filter": type_filter, "limit": limit, "offset": offset}))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_component(component_id: str) -> dict[str, Any]:
    """Return the full definition of one component, including its node ids."""
    return _wrap(call_engine("get_component", {"component_id": component_id}))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_connections() -> dict[str, Any]:
    """Return all electrical connections, the pin->node map and net names."""
    return _wrap(call_engine("get_connections"))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_node_voltage(node: str) -> dict[str, Any]:
    """Return the latest simulated voltage (V) for a node, or an error if none."""
    return _wrap(call_engine("get_node_voltage", {"node": node}))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_branch_current(branch: str) -> dict[str, Any]:
    """Return the latest branch current (A) for a component id, with direction."""
    return _wrap(call_engine("get_branch_current", {"branch": branch}))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_simulation_results(filter: str = "", limit: int = 500, offset: int = 0) -> dict[str, Any]:
    """Return the latest result summary, node voltages and branch currents.

    Args:
        filter: "" (all), "nodes" or "branches".
        limit: Maximum entries per section.
        offset: Pagination offset.
    """
    return _wrap(call_engine("get_simulation_results", {"filter": filter, "limit": limit, "offset": offset}))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_circuit_text() -> dict[str, Any]:
    """Return a short natural-language description of the current circuit."""
    return _wrap(call_engine("get_circuit_text"))


# ---------------------------------------------------------------------------
# C. Circuit editing
# ---------------------------------------------------------------------------

@mcp.tool(annotations=_edit(), structured_output=True)
def create_project(name: str = "Untitled", operation_id: str = "") -> dict[str, Any]:
    """Create a new empty project (replaces the current one).

    Args:
        name: Project name.
        operation_id: Optional idempotency key for safe retries.
    """
    return _wrap(call_engine("create_project", {"name": name, "operation_id": operation_id}))


@mcp.tool(annotations=_edit(), structured_output=True)
def add_component(
    component_type: str,
    name: str = "",
    holes: list[str] | None = None,
    orientation: float = 0.0,
    parameters: dict[str, Any] | None = None,
    operation_id: str = "",
) -> dict[str, Any]:
    """Add a component and return its stable id.

    Args:
        component_type: Type id from get_component_catalog (e.g. "resistor").
        name: Optional human label.
        holes: Optional breadboard holes, one per pin (e.g. ["a1","a2"]). Pins
            left as "" can be connected later with connect_terminals.
        orientation: Rotation in radians.
        parameters: Parameter overrides (e.g. {"r": 1000}). Units are SI.
        operation_id: Optional idempotency key for safe retries.
    """
    return _wrap(call_engine("add_component", {
        "component_type": component_type, "name": name, "holes": holes or [],
        "orientation": orientation, "parameters": parameters or {}, "operation_id": operation_id,
    }))


@mcp.tool(annotations=_edit(), structured_output=True)
def update_component_parameters(
    component_id: str,
    parameters: dict[str, Any],
    expected_revision: int | None = None,
) -> dict[str, Any]:
    """Update one or more parameters (SI units). Rejects invalid values entirely.

    Args:
        component_id: Target component id.
        parameters: Parameters to set (e.g. {"r": 2000}).
        expected_revision: Optional optimistic-concurrency guard.
    """
    return _wrap(call_engine("update_component_parameters", {
        "component_id": component_id, "parameters": parameters,
        "expected_revision": expected_revision,
    }))


@mcp.tool(annotations=_edit(), structured_output=True)
def set_pin_levels(
    levels: dict[str, float],
    simulate: bool = False,
    expected_revision: int | None = None,
) -> dict[str, Any]:
    """Drive one or more virtual MCU pins, optionally re-running the DC solve.

    Pin-level simulation without firmware: set a `mcu_pin` component's level and
    read the effect on the circuit.

    Args:
        levels: Map of mcu_pin component_id -> level (1 = high, 0 = low,
            -1 = high-impedance input).
        simulate: Run a DC simulation afterwards and return the result.
        expected_revision: Optional optimistic-concurrency guard.
    """
    return _wrap(call_engine("set_pin_levels", {
        "levels": levels, "simulate": simulate, "expected_revision": expected_revision,
    }))


@mcp.tool(annotations=_edit(), structured_output=True)
def apply_firmware_pins(
    hex_path: str,
    pin_map: dict[str, str],
    ms: int = 2000,
    at_ms: float = -1.0,
    simulate: bool = False,
    expected_revision: int | None = None,
) -> dict[str, Any]:
    """Drive real `mcu_pin` components from firmware output at one instant.

    Runs the firmware, samples each mapped pin's level at `at_ms` (default: the end
    of the run) and applies it to the matching `mcu_pin`, optionally re-solving DC.
    This bridges firmware to the Stage-A ideal pin model; it is open-loop (the
    circuit does not feed back into the firmware).

    Args:
        hex_path: Path to a compiled Arduino Intel-HEX.
        pin_map: Firmware pin -> mcu_pin component_id, e.g. {"13": "P1"} ("13",
            "D13" and "A0" are accepted).
        ms: Emulated run length in milliseconds (1..10000).
        at_ms: Sample time in ms; -1 means the end of the run.
        simulate: Run a DC simulation after applying the levels.
        expected_revision: Optional optimistic-concurrency guard.
    """
    return _wrap(call_engine("apply_firmware_pins", {
        "hex_path": hex_path, "pin_map": pin_map, "ms": ms, "at_ms": at_ms,
        "simulate": simulate, "expected_revision": expected_revision,
    }))


@mcp.tool(annotations=_edit(), structured_output=True)
def apply_firmware_device(
    hex_path: str,
    component_id: str,
    ms: int = 2000,
    simulate: bool = False,
    expected_revision: int | None = None,
) -> dict[str, Any]:
    """Feed firmware I2C traffic into a peripheral device model.

    Runs the firmware, takes the last byte it wrote to the device's I2C address and
    sets the device `state` from it (for a PCF8574: P0..P7 follow the byte's bits),
    optionally re-solving DC. This is open-loop (no device feedback into firmware).

    Args:
        hex_path: Path to a compiled Arduino Intel-HEX.
        component_id: Target device component id (currently a `pcf8574`).
        ms: Emulated run length in milliseconds (1..10000).
        simulate: Run a DC simulation after applying the device state.
        expected_revision: Optional optimistic-concurrency guard.
    """
    return _wrap(call_engine("apply_firmware_device", {
        "hex_path": hex_path, "component_id": component_id, "ms": ms,
        "simulate": simulate, "expected_revision": expected_revision,
    }))


@mcp.tool(annotations=_edit(), structured_output=True)
def move_component(
    component_id: str,
    holes: list[str] | None = None,
    orientation: float | None = None,
    expected_revision: int | None = None,
) -> dict[str, Any]:
    """Move/reorient a component without silently breaking its connectivity.

    Args:
        component_id: Target component id.
        holes: New breadboard hole per pin.
        orientation: New rotation in radians.
        expected_revision: Optional optimistic-concurrency guard.
    """
    return _wrap(call_engine("move_component", {
        "component_id": component_id, "holes": holes or [],
        "orientation": orientation, "expected_revision": expected_revision,
    }))


@mcp.tool(annotations=_edit(destructive=True), structured_output=True)
def remove_component(
    component_id: str,
    confirm: bool = False,
    expected_revision: int | None = None,
    operation_id: str = "",
) -> dict[str, Any]:
    """Remove a component (destructive). Requires confirm=true.

    Returns the connections that will be/were affected. Call once without
    confirm to preview, then again with confirm=true.
    """
    return _wrap(call_engine("remove_component", {
        "component_id": component_id, "confirm": confirm,
        "expected_revision": expected_revision, "operation_id": operation_id,
    }))


@mcp.tool(annotations=_edit(), structured_output=True)
def connect_terminals(
    a: dict[str, Any],
    b: dict[str, Any],
    expected_revision: int | None = None,
) -> dict[str, Any]:
    """Connect two terminals and return the connection id and affected nodes.

    Args:
        a: Endpoint, e.g. {"kind":"pin","component":"R1","pin":0} or
           {"kind":"hole","id":"a1"}.
        b: Second endpoint.
        expected_revision: Optional optimistic-concurrency guard.
    """
    return _wrap(call_engine("connect_terminals", {"a": a, "b": b, "expected_revision": expected_revision}))


@mcp.tool(annotations=_edit(destructive=True), structured_output=True)
def disconnect_connection(connection_id: str, expected_revision: int | None = None) -> dict[str, Any]:
    """Remove one connection (wire). Does not touch unrelated wires."""
    return _wrap(call_engine("disconnect_connection", {
        "connection_id": connection_id, "expected_revision": expected_revision,
    }))


@mcp.tool(annotations=_edit(destructive=True), structured_output=True)
def clear_circuit(confirm: bool = False, expected_revision: int | None = None) -> dict[str, Any]:
    """Remove every component and wire (destructive). Requires confirm=true."""
    return _wrap(call_engine("clear_circuit", {"confirm": confirm, "expected_revision": expected_revision}))


@mcp.tool(annotations=_ro(), structured_output=True)
def validate_circuit() -> dict[str, Any]:
    """Validate the circuit; returns structured errors, warnings and info."""
    return _wrap(call_engine("validate_circuit"))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_edit_preview(operation: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
    """Return a structural preview of a proposed change (no electrical prediction)."""
    return _wrap(call_engine("get_edit_preview", {"operation": operation, "arguments": arguments or {}}))


# ---------------------------------------------------------------------------
# D. Simulation
# ---------------------------------------------------------------------------

@mcp.tool(annotations=_ro(), structured_output=True)
def run_dc_simulation() -> dict[str, Any]:
    """Run a DC operating-point solve and return node voltages and branch currents."""
    return _wrap(call_engine("run_dc_simulation"))


@mcp.tool(annotations=_ro(), structured_output=True)
def run_transient_simulation(
    t_start: float = 0.0,
    t_stop: float = 0.5,
    dt: float = 0.001,
    probes: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Run a bounded transient simulation (backward-Euler).

    Args:
        t_start: Start time in seconds.
        t_stop: Stop time in seconds (must be > t_start).
        dt: Time step in seconds (must be > 0).
        probes: Optional probes, e.g. [{"kind":"node","target":"0"}] or
            [{"kind":"current","target":"R1"}].
    """
    return _wrap(call_engine("run_transient_simulation", {
        "t_start": t_start, "t_stop": t_stop, "dt": dt, "probes": probes or [],
    }))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_simulation_status() -> dict[str, Any]:
    """Return idle/running/completed/failed plus the last result id."""
    return _wrap(call_engine("get_simulation_status"))


@mcp.tool(annotations=_edit(), structured_output=True)
def stop_simulation() -> dict[str, Any]:
    """Request a safe stop of the current simulation."""
    return _wrap(call_engine("stop_simulation"))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_waveform_data(target: str, kind: str = "node", max_samples: int = 2000) -> dict[str, Any]:
    """Return bounded waveform samples for a node or component from the last transient.

    Args:
        target: A probe target from the last transient (node id or component id).
        kind: "node" (volts) or "current" (amps).
        max_samples: Maximum returned samples (downsampled).
    """
    return _wrap(call_engine("get_waveform_data", {"target": target, "kind": kind, "max_samples": max_samples}))


# ---------------------------------------------------------------------------
# E. Persistence
# ---------------------------------------------------------------------------

@mcp.tool(annotations=_edit(), structured_output=True)
def save_project(path: str = "", expected_revision: int | None = None) -> dict[str, Any]:
    """Save the project atomically inside the approved directory.

    Args:
        path: Optional filename relative to user://projects (empty = auto-name).
        expected_revision: Optional optimistic-concurrency guard.
    """
    return _wrap(call_engine("save_project", {"path": path, "expected_revision": expected_revision}))


@mcp.tool(annotations=_edit(), structured_output=True)
def load_project(path: str, expected_revision: int | None = None) -> dict[str, Any]:
    """Load a project from an approved path or a bundled example (res://data/examples)."""
    return _wrap(call_engine("load_project", {"path": path, "expected_revision": expected_revision}))


@mcp.tool(annotations=_ro(), structured_output=True)
def list_example_projects() -> dict[str, Any]:
    """List bundled example circuits with descriptions and component counts."""
    return _wrap(call_engine("list_example_projects"))


@mcp.tool(annotations=_edit(), structured_output=True)
def load_example_project(name: str) -> dict[str, Any]:
    """Load a bundled example by name (see list_example_projects)."""
    return _wrap(call_engine("load_example_project", {"name": name}))


# ---------------------------------------------------------------------------
# F. Diagnostics
# ---------------------------------------------------------------------------

@mcp.tool(annotations=_ro(), structured_output=True)
def get_diagnostics() -> dict[str, Any]:
    """Return structured diagnostics with codes, severity and suggested actions."""
    return _wrap(call_engine("get_diagnostics"))


@mcp.tool(annotations=_ro(), structured_output=True)
def get_solver_info() -> dict[str, Any]:
    """Return solver capabilities, tolerances, models and convergence info."""
    return _wrap(call_engine("get_solver_info"))


# ---------------------------------------------------------------------------
# Resources (read-only, reflect live state)
# ---------------------------------------------------------------------------

@mcp.resource("circuit://current/summary", mime_type="application/json",
              description="Live project summary.")
def resource_summary() -> str:
    return json.dumps(call_engine("get_project_summary"), indent=2, default=str)


@mcp.resource("circuit://current/components", mime_type="application/json",
              description="Live component list.")
def resource_components() -> str:
    return json.dumps(call_engine("list_components"), indent=2, default=str)


@mcp.resource("circuit://current/connections", mime_type="application/json",
              description="Live connections and pin->node map.")
def resource_connections() -> str:
    return json.dumps(call_engine("get_connections"), indent=2, default=str)


@mcp.resource("circuit://current/diagnostics", mime_type="application/json",
              description="Live diagnostics.")
def resource_diagnostics() -> str:
    return json.dumps(call_engine("get_diagnostics"), indent=2, default=str)


@mcp.resource("circuit://catalog/components", mime_type="application/json",
              description="Component catalog.")
def resource_catalog() -> str:
    return json.dumps(call_engine("get_component_catalog"), indent=2, default=str)


@mcp.resource("circuit://documentation/units", mime_type="text/plain",
              description="Unit and engineering-notation reference.")
def resource_units() -> str:
    return (
        "CircuitForge 3D uses SI base units everywhere in tool inputs/outputs.\n"
        "Parameter units: resistance=ohm, capacitance=F, inductance=H, voltage=V,\n"
        "current=A, time=s, frequency=Hz. Logic vdd/vth in V, rout in ohm.\n"
        "Human-facing strings also accept engineering notation: 4.7k, 100n, 10m, 2M.\n"
        "Prefer plain SI numbers in MCP calls (e.g. 4700, 100e-9).\n"
    )


@mcp.resource("circuit://documentation/simulation-models", mime_type="text/plain",
              description="Supported device models and limitations.")
def resource_models() -> str:
    cats = call_engine("get_component_catalog")
    lines = ["Supported simulation models (per component type):"]
    if cats.get("success"):
        for item in cats.get("items", []):
            models = ", ".join(item.get("simulation_models", [])) or "none"
            lines.append(f"- {item['type']}: {models}")
    lines.append("")
    lines.append("Solver: modified nodal analysis; DC, backward-Euler transient; "
                 "Newton-Raphson with junction limiting for diodes/LEDs/zeners/logic.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Prompts (reusable workflow helpers; they do not replace simulation)
# ---------------------------------------------------------------------------

@mcp.prompt(name="explain_circuit", description="Explain the current circuit for a beginner.")
def prompt_explain_circuit() -> str:
    return ("Explain the current CircuitForge 3D circuit in beginner-friendly language. "
            "First call get_circuit_text, list_components and get_connections. Then run "
            "run_dc_simulation and read real node voltages/branch currents. Do not invent "
            "components or measurements.")


@mcp.prompt(name="find_disconnected_pins", description="Find pins with no electrical connection.")
def prompt_find_disconnected_pins() -> str:
    return ("Call get_diagnostics and get_connections. Report every pin whose net contains no "
            "other terminal and every wire with a dangling end, with the component ids and "
            "suggested fixes. Do not claim a simulation failure unless a solve actually failed.")


@mcp.prompt(name="diagnose_simulation_failure", description="Diagnose why a simulation fails.")
def prompt_diagnose() -> str:
    return ("The simulation fails or looks wrong. Call validate_circuit, get_diagnostics and "
            "get_connections. Check for a missing ground, floating nets and conflicting sources. "
            "Run run_dc_simulation and report the exact solver error if any.")


@mcp.prompt(name="calculate_expected_values", description="Compute expected values analytically.")
def prompt_expected() -> str:
    return ("List the components and supplies, then calculate the expected node voltages and "
            "branch currents by hand (Ohm's law, dividers, KCL). Clearly separate these "
            "analytical values from the simulated ones.")


@mcp.prompt(name="compare_with_analysis", description="Compare simulation against analysis.")
def prompt_compare() -> str:
    return ("Run run_dc_simulation, then compare each simulated node voltage and branch current "
            "against the analytical value. Report the differences and whether they are within a "
            "reasonable tolerance.")


@mcp.prompt(name="suggest_simpler_circuit", description="Suggest a simpler or safer circuit.")
def prompt_simplify() -> str:
    return ("Inspect the circuit, then suggest a simpler or safer equivalent (fewer components, "
            "avoiding over-current in LEDs). Use get_edit_preview for proposed changes; do not "
            "apply destructive edits without confirmation.")


@mcp.prompt(name="explain_component", description="Explain a single component to a beginner.")
def prompt_explain_component(component_type: str) -> str:
    return (f"Explain the '{component_type}' component to a beginner: what it does, its "
            "parameters and units, and a simple example. Use get_component_catalog for the "
            "authoritative parameter list.")


@mcp.prompt(name="generate_test_plan", description="Generate a test plan for a circuit.")
def prompt_test_plan() -> str:
    return ("Produce a test plan for the current circuit: build steps, expected analytical "
            "values, which MCP tools to call, and pass/fail criteria. Use expected_revision "
            "for concurrent-safety and avoid destructive tools.")


def main() -> None:
    mcp.run("stdio")


if __name__ == "__main__":  # pragma: no cover
    main()
