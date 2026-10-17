"""End-to-end MCP integration tests for CircuitForge 3D (Tests A-J).

These tests exercise the real MCP protocol through the official MCP Python SDK
client against the real adapter process. They do not test internal Python
functions in isolation.

Run:
    set CIRCUITFORGE_GODOT=<godot console exe>
    set CIRCUITFORGE_PROJECT=<repo with project.godot>
    mcp_server/.venv/Scripts/python mcp_server/tests/test_mcp_integration.py

Exit code 0 = all tests passed.
"""

from __future__ import annotations

import anyio
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
MCP_SERVER_DIR = HERE.parent
REPO_ROOT = MCP_SERVER_DIR.parent
VENV_PY = Path(sys.executable)
GODOT = os.environ.get("CIRCUITFORGE_GODOT", "")
PROJECT = os.environ.get("CIRCUITFORGE_PROJECT", str(REPO_ROOT))

sys.path.insert(0, str(MCP_SERVER_DIR))

from mcp import ClientSession  # noqa: E402
from mcp.client.stdio import stdio_client, StdioServerParameters  # noqa: E402

RESULTS: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail else ""))


def env() -> dict[str, str]:
    return {
        **os.environ,
        "CIRCUITFORGE_GODOT": GODOT,
        "CIRCUITFORGE_PROJECT": PROJECT,
        "PYTHONPATH": str(MCP_SERVER_DIR),
        "PYTHONUNBUFFERED": "1",
    }


def server_params() -> StdioServerParameters:
    return StdioServerParameters(command=str(VENV_PY), args=["-m", "circuitforge_mcp"],
                                 cwd=str(MCP_SERVER_DIR), env=env())


def sc(res) -> dict:
    return res.structured_content or {}


async def call_ok(s, name, args=None) -> dict:
    res = await s.call_tool(name, args or {})
    assert not res.is_error, f"{name} failed: {res.structured_content or res.content}"
    return sc(res)


async def call_err(s, name, args=None) -> dict:
    res = await s.call_tool(name, args or {})
    assert res.is_error, f"{name} unexpectedly succeeded"
    return sc(res)


async def main() -> int:
    print("CircuitForge 3D — MCP integration tests\n")
    if not GODOT:
        print("  SKIP  CIRCUITFORGE_GODOT is not set; integration tests require Godot.")
        record("Setup", False, "CIRCUITFORGE_GODOT not set")
        return 2

    async with stdio_client(server_params()) as (read, write):
        async with ClientSession(read, write) as s:
            # ---------------------------------------------------- Test A
            try:
                init = await s.initialize()
                tools = await s.list_tools()
                names = {t.name for t in tools.tools}
                required = {"get_simulator_info", "get_capabilities", "get_component_catalog",
                            "get_project_summary", "list_components", "get_component",
                            "get_connections", "get_node_voltage", "get_branch_current",
                            "get_simulation_results", "create_project", "add_component",
                            "update_component_parameters", "move_component", "remove_component",
                            "connect_terminals", "disconnect_connection", "validate_circuit",
                            "get_edit_preview", "run_dc_simulation", "run_transient_simulation",
                            "get_simulation_status", "stop_simulation", "get_waveform_data",
                            "save_project", "load_project", "list_example_projects",
                            "load_example_project", "get_diagnostics", "get_solver_info",
                            "get_catalog_facets", "get_board_pinout",
                            "get_pin_states", "set_pin_levels"}
                missing = required - names
                schemas_ok = all(isinstance(t.input_schema, dict) for t in tools.tools)
                record("A. Server initialization", init.server_info.name == "circuitforge-3d" and not missing and schemas_ok,
                       f"{len(names)} tools, missing={sorted(missing)}")
                res = await s.list_resources()
                prompts = await s.list_prompts()
                record("A2. Resources & prompts discovered", len(res.resources) >= 6 and len(prompts.prompts) >= 6,
                       f"resources={len(res.resources)} prompts={len(prompts.prompts)}")
            except Exception as exc:
                record("A. Server initialization", False, repr(exc))
                return 1

            # ---------------------------------------------------- Test B
            try:
                info = await call_ok(s, "get_simulator_info")
                caps = await call_ok(s, "get_capabilities")
                cat = await call_ok(s, "get_component_catalog")
                summary = await call_ok(s, "get_project_summary")
                ok = (info.get("application") == "CircuitForge 3D" and "operations" in caps
                      and cat.get("count", 0) >= 10 and "component_count" in summary)
                record("B. Read-only discovery", ok,
                       f"app={info.get('application')} components={cat.get('count')} summary_ok={bool(summary)}")
            except Exception as exc:
                record("B. Read-only discovery", False, repr(exc))

            # ---------------------------------------------------- Test B2
            try:
                facets = await call_ok(s, "get_catalog_facets")
                full = await call_ok(s, "get_component_catalog", {"status": "full"})
                sim = await call_ok(s, "get_component_catalog", {"simulatable_only": True})
                i2c = await call_ok(s, "get_component_catalog", {"protocol": "I2C"})
                statuses = set(facets.get("statuses", []))
                ok = (facets.get("count", 0) >= 100
                      and {"full", "partial", "planned"} <= statuses
                      and full.get("count", 0) >= 10
                      and all(it["simulation_status"] == "full" for it in full["items"])
                      and all(it["simulatable"] for it in sim["items"])
                      and all("I2C" in it["protocols"] for it in i2c["items"])
                      and not facets.get("validation_errors"))
                record("B2. Catalog discovery (facets/filters/status)", ok,
                       f"count={facets.get('count')} full={full.get('count')} "
                       f"simulatable={sim.get('count')} i2c={i2c.get('count')}")
            except Exception as exc:
                record("B2. Catalog discovery (facets/filters/status)", False, repr(exc))

            # ---------------------------------------------------- Test B3
            try:
                pin = await call_ok(s, "get_board_pinout", {"type": "arduino_uno_r3"})
                counts = pin.get("counts", {})
                groups = pin.get("groups", {})
                ok = (pin.get("type") == "arduino_uno_r3"
                      and pin.get("pin_count", 0) >= 20
                      and counts.get("ground", 0) >= 1
                      and counts.get("power", 0) >= 1
                      and isinstance(groups, dict)
                      and "GND" in groups.get("ground", [])
                      and bool(pin.get("references")))
                record("B3. Board pinout metadata", ok,
                       f"pins={pin.get('pin_count')} counts={counts}")
            except Exception as exc:
                record("B3. Board pinout metadata", False, repr(exc))

            # ---------------------------------------------------- Test B4
            try:
                await call_ok(s, "set_pin_levels", {"levels": {}})
                record("B4. Virtual pin control", False, "empty levels unexpectedly succeeded")
            except Exception:
                pass
            try:
                await call_ok(s, "create_project", {"name": "MCP-PinDemo"})
                pin_id = (await call_ok(s, "add_component", {"component_type": "mcu_pin"}))["component_id"]
                await call_ok(s, "set_pin_levels", {"levels": {pin_id: 1.0}})
                states = await call_ok(s, "get_pin_states")
                entry = next((p for p in states.get("pins", []) if p.get("component_id") == pin_id), None)
                ok = (states.get("count", 0) >= 1 and entry is not None
                      and entry.get("state") == "high" and entry.get("level") == 1.0
                      and bool(entry.get("signal_node")))
                record("B4. Virtual pin control (mcu_pin Level A)", ok,
                       f"count={states.get('count')} state={entry.get('state') if entry else None}")
            except Exception as exc:
                record("B4. Virtual pin control (mcu_pin Level A)", False, repr(exc))

            # ---------------------------------------------------- Test C
            try:
                await call_ok(s, "create_project", {"name": "MCP-Integration"})
                v = (await call_ok(s, "add_component", {"component_type": "vsource", "parameters": {"v": 5.0}}))["component_id"]
                r = (await call_ok(s, "add_component", {"component_type": "resistor", "parameters": {"r": 1000.0}}))["component_id"]
                g = (await call_ok(s, "add_component", {"component_type": "ground"}))["component_id"]
                await call_ok(s, "connect_terminals", {"a": {"kind": "pin", "component": v, "pin": 0},
                                                       "b": {"kind": "pin", "component": r, "pin": 0}})
                await call_ok(s, "connect_terminals", {"a": {"kind": "pin", "component": v, "pin": 1},
                                                       "b": {"kind": "pin", "component": g, "pin": 0}})
                await call_ok(s, "connect_terminals", {"a": {"kind": "pin", "component": r, "pin": 1},
                                                       "b": {"kind": "pin", "component": g, "pin": 0}})
                comp = await call_ok(s, "get_component", {"component_id": r})
                conns = await call_ok(s, "get_connections")
                resolved = comp["component"]["component_id"] == r and len(comp["component"]["node_ids"]) == 2
                wires = len(conns["wires"]) == 3
                record("C. Create and inspect circuit", resolved and wires,
                       f"ids={v},{r},{g} wires={len(conns['wires'])}")
                globals()["_ids"] = (v, r, g)
            except Exception as exc:
                record("C. Create and inspect circuit", False, repr(exc))

            # ---------------------------------------------------- Test D
            try:
                dc = await call_ok(s, "run_dc_simulation")
                v, r, g = globals()["_ids"]
                node = [k for k, val in dc["node_voltages"].items() if k != "0"][0]
                nv = await call_ok(s, "get_node_voltage", {"node": node})
                bc = await call_ok(s, "get_branch_current", {"branch": r})
                diags = await call_ok(s, "get_diagnostics")
                ok = (abs(dc["node_voltages"][node] - 5.0) < 1e-6
                      and abs(dc["element_currents"][r] - 0.005) < 1e-9
                      and abs(nv["voltage"] - 5.0) < 1e-6
                      and abs(bc["current"] - 0.005) < 1e-9)
                record("D. Simulate and measure", ok,
                       f"node={dc['node_voltages'][node]:.4f}V I(R)={dc['element_currents'][r]*1000:.4f}mA diag={diags['status']}")
            except Exception as exc:
                record("D. Simulate and measure", False, repr(exc))

            # ---------------------------------------------------- Test E
            try:
                v, r, g = globals()["_ids"]
                await call_ok(s, "update_component_parameters", {"component_id": r, "parameters": {"r": 2000.0}})
                dc = await call_ok(s, "run_dc_simulation")
                ok = abs(dc["element_currents"][r] - 0.0025) < 1e-9
                record("E. Parameter change (1k->2k => 5mA->2.5mA)", ok,
                       f"I(R)={dc['element_currents'][r]*1000:.4f}mA")
            except Exception as exc:
                record("E. Parameter change", False, repr(exc))

            # ---------------------------------------------------- Test F
            try:
                e1 = await call_err(s, "add_component", {"component_type": "flux-capacitor"})
                e2 = await call_err(s, "update_component_parameters", {"component_id": r, "parameters": {"r": -5}})
                e3 = await call_err(s, "connect_terminals", {"a": {"kind": "pin", "component": "NOPE", "pin": 0},
                                                             "b": {"kind": "hole", "id": "a1"}})
                e4 = await call_err(s, "get_node_voltage", {"node": "no-such-node"})
                codes = {e1["error"]["code"], e2["error"]["code"], e3["error"]["code"], e4["error"]["code"]}
                expected = {"UNKNOWN_COMPONENT_TYPE", "INVALID_PARAMETER", "INVALID_CONNECTION", "UNKNOWN_NODE"}
                # Project must be unchanged (still 3 components, resistor still 2000).
                comp = await call_ok(s, "get_component", {"component_id": r})
                intact = abs(comp["component"]["parameters"]["r"] - 2000.0) < 1e-9
                record("F. Invalid input is safe", expected <= codes and intact, f"codes={sorted(codes)}")
            except Exception as exc:
                record("F. Invalid input", False, repr(exc))

            # ---------------------------------------------------- Test G
            try:
                saved = await call_ok(s, "save_project", {"path": "mcp_integration_test"})
                await call_ok(s, "create_project", {"name": "Empty"})
                empty = await call_ok(s, "list_components")
                await call_ok(s, "load_project", {"path": "mcp_integration_test"})
                comps = await call_ok(s, "list_components")
                dc = await call_ok(s, "run_dc_simulation")
                v, r, g = globals()["_ids"]
                ok = (empty["count"] == 0 and comps["count"] == 3
                      and abs(dc["element_currents"][r] - 0.0025) < 1e-9)
                record("G. Persistence (save/reopen/simulate)", ok,
                       f"saved={Path(saved['path']).name} count={comps['count']} I(R)={dc['element_currents'][r]*1000:.4f}mA")
            except Exception as exc:
                record("G. Persistence", False, repr(exc))

            # ---------------------------------------------------- Test H
            try:
                v, r, g = globals()["_ids"]
                summary = await call_ok(s, "get_project_summary")
                stale = summary["revision"]
                await call_ok(s, "add_component", {"component_type": "capacitor", "parameters": {"c": 1e-6}})
                conflict = await call_err(s, "update_component_parameters",
                                          {"component_id": r, "parameters": {"r": 4700.0}, "expected_revision": stale})
                ok = conflict["error"]["code"] == "OPERATION_CONFLICT"
                record("H. Concurrency (stale revision rejected)", ok, f"code={conflict['error']['code']}")
                await call_ok(s, "remove_component", {"component_id": (await call_ok(s, "list_components", {"type_filter": "capacitor"}))["items"][0]["component_id"], "confirm": True})
            except Exception as exc:
                record("H. Concurrency", False, repr(exc))

    # ---------------------------------------------------- Test I (raw transport)
    try:
        proc = subprocess.Popen(
            [str(VENV_PY), "-m", "circuitforge_mcp"],
            cwd=str(MCP_SERVER_DIR), env=env(),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        init_req = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                               "clientInfo": {"name": "raw-test", "version": "0"}}}
        proc.stdin.write(json.dumps(init_req) + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        parsed = json.loads(line)
        proto_ok = parsed.get("result", {}).get("serverInfo", {}).get("name") == "circuitforge-3d"
        proc.stdin.close()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        stderr = proc.stderr.read()
        stdout_clean = parsed is not None  # parsed means it was valid JSON
        stderr_has_diag = "[circuitforge-3d]" in stderr
        record("I. Transport correctness (stdio)", proto_ok and stdout_clean and stderr_has_diag,
               f"stdout_json={stdout_clean} stderr_diag={stderr_has_diag}")
    except Exception as exc:
        record("I. Transport correctness", False, repr(exc))

    # ---------------------------------------------------- Test J (offline)
    try:
        os.environ["HTTP_PROXY"] = "http://127.0.0.1:9"
        os.environ["HTTPS_PROXY"] = "http://127.0.0.1:9"
        async with stdio_client(server_params()) as (read, write):
            async with ClientSession(read, write) as s:
                await s.initialize()
                await call_ok(s, "create_project", {"name": "Offline"})
                await call_ok(s, "add_component", {"component_type": "vsource", "parameters": {"v": 5.0}})
                r = (await call_ok(s, "add_component", {"component_type": "resistor"}))["component_id"]
                g = (await call_ok(s, "add_component", {"component_type": "ground"}))["component_id"]
                v = (await call_ok(s, "list_components", {"type_filter": "vsource"}))["items"][0]["component_id"]
                await call_ok(s, "connect_terminals", {"a": {"kind": "pin", "component": v, "pin": 0}, "b": {"kind": "pin", "component": r, "pin": 0}})
                await call_ok(s, "connect_terminals", {"a": {"kind": "pin", "component": v, "pin": 1}, "b": {"kind": "pin", "component": g, "pin": 0}})
                await call_ok(s, "connect_terminals", {"a": {"kind": "pin", "component": r, "pin": 1}, "b": {"kind": "pin", "component": g, "pin": 0}})
                dc = await call_ok(s, "run_dc_simulation")
                ok = abs(dc["element_currents"][r] - 0.005) < 1e-9
        record("J. Offline loopback operation", ok, "simulated with unroutable proxy; all IPC loopback")
    except Exception as exc:
        record("J. Offline loopback operation", False, repr(exc))

    passed = sum(1 for _, ok, _ in RESULTS if ok)
    total = len(RESULTS)
    print(f"\nRESULT: {passed} / {total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(anyio.run(main))
