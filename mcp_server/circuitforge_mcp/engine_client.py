"""Local engine client for CircuitForge 3D.

The MCP adapter is a thin translator: it speaks MCP on stdio to the client, and
speaks the versioned "circuitforge-local-api/1" line-JSON protocol to a headless
Godot process that hosts the application service layer.

Two connection modes:

* **spawn** (default): start our own headless engine process. The engine prints
  a one-line READY banner on its stdout containing the TCP port and a random
  per-run auth token; we then talk to it over a loopback socket.
* **attach**: if ``CIRCUITFORGE_API_PORT`` and ``CIRCUITFORGE_API_TOKEN`` are set,
  connect to an already-running engine instead of spawning one.

Security: the engine binds loopback only and requires the token on every call.
This adapter never executes shell commands from tool arguments.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

ADAPTER_VERSION = "0.1.0"
LOCAL_API_PROTOCOL = "circuitforge-local-api/1"
READY_TOKEN = "CIRCUITFORGE-API-READY"


class EngineError(RuntimeError):
    """A structured error raised by the engine or the transport."""

    def __init__(self, code: str, message: str, suggested_action: str = "") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.suggested_action = suggested_action

    def to_dict(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "message": self.message,
            "suggested_action": self.suggested_action,
        }


def _repo_root() -> Path:
    # <repo>/mcp_server/circuitforge_mcp/engine_client.py  -> parents[2] == repo
    return Path(__file__).resolve().parents[2]


def find_godot() -> str | None:
    explicit = os.environ.get("CIRCUITFORGE_GODOT")
    if explicit:
        return explicit
    for name in ("godot", "godot4", "Godot", "godot.exe"):
        found = shutil.which(name)
        if found:
            return found
    return None


def find_project() -> str | None:
    explicit = os.environ.get("CIRCUITFORGE_PROJECT")
    if explicit:
        return explicit
    root = _repo_root()
    if (root / "project.godot").exists():
        return str(root)
    return None


class EngineClient:
    def __init__(
        self,
        godot: str | None = None,
        project: str | None = None,
        port: int | None = None,
        token: str | None = None,
        startup_timeout: float = 60.0,
        call_timeout: float = 60.0,
    ) -> None:
        self.godot = godot or find_godot()
        self.project = project or find_project()
        self.port = int(port) if port else None
        self.token = token
        self.startup_timeout = startup_timeout
        self.call_timeout = call_timeout

        self._proc: subprocess.Popen | None = None
        self._sock: socket.socket | None = None
        self._rf = None
        self._lock = threading.Lock()
        self._out_queue: queue.Queue[str | None] = queue.Queue()
        self._id = 0
        self._started = False

    # -- lifecycle ---------------------------------------------------------
    def start(self) -> "EngineClient":
        if self._started:
            return self
        if self.port and self.token:
            self._connect()
        else:
            self._spawn()
        self._started = True
        return self

    def _spawn(self) -> None:
        if not self.godot:
            raise EngineError(
                "ENGINE_UNAVAILABLE",
                "Godot was not found.",
                "Set CIRCUITFORGE_GODOT to the Godot 4.7 executable (prefer the console build on Windows).",
            )
        if not self.project:
            raise EngineError(
                "ENGINE_UNAVAILABLE",
                "The CircuitForge project folder was not found.",
                "Set CIRCUITFORGE_PROJECT to the folder containing project.godot.",
            )
        cmd = [
            self.godot, "--headless", "--path", self.project,
            "--script", "res://scripts/api/api_server.gd", "--",
            "--port", "0", "--disconnect-grace", "3",
        ]
        creation = 0
        if sys.platform == "win32":
            creation = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self._proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, creationflags=creation,
        )
        threading.Thread(target=self._pump, args=(self._proc.stdout, True), daemon=True).start()
        threading.Thread(target=self._pump, args=(self._proc.stderr, False), daemon=True).start()

        deadline = time.time() + self.startup_timeout
        while time.time() < deadline:
            try:
                line = self._out_queue.get(timeout=0.5)
            except queue.Empty:
                if self._proc.poll() is not None:
                    raise EngineError(
                        "ENGINE_UNAVAILABLE",
                        "The engine process exited before it was ready.",
                        "Check CIRCUITFORGE_GODOT and run the engine manually to see errors.",
                    )
                continue
            if line is None:
                continue
            if line.startswith(READY_TOKEN):
                meta = json.loads(line[len(READY_TOKEN):].strip())
                self.port = int(meta["port"])
                self.token = str(meta["token"])
                self._connect()
                return
        raise EngineError(
            "ENGINE_TIMEOUT",
            "The engine did not become ready in time.",
            "Check that Godot 4.7 starts and that the project imports without errors.",
        )

    def _pump(self, pipe, is_stdout: bool) -> None:
        try:
            for line in pipe:
                text = line.rstrip("\n")
                if is_stdout:
                    self._out_queue.put(text)
                elif text:
                    print(f"[engine] {text}", file=sys.stderr)
        finally:
            if is_stdout:
                self._out_queue.put(None)

    def _connect(self) -> None:
        deadline = time.time() + self.startup_timeout
        last: Exception | None = None
        while time.time() < deadline:
            try:
                self._sock = socket.create_connection(("127.0.0.1", self.port), timeout=self.call_timeout)
                self._sock.settimeout(self.call_timeout)
                self._rf = self._sock.makefile("r", encoding="utf-8", newline="\n")
                return
            except OSError as exc:  # noqa: PERF203
                last = exc
                time.sleep(0.2)
        raise EngineError("ENGINE_UNAVAILABLE", f"Could not connect to the engine: {last}",
                          "Ensure nothing blocks loopback connections.")

    def close(self) -> None:
        try:
            if self._sock is not None:
                self.call("shutdown", {})
        except Exception:
            pass
        for closer in (self._rf, self._sock):
            try:
                if closer is not None:
                    closer.close()
            except Exception:
                pass
        if self._proc is not None:
            try:
                self._proc.wait(timeout=5)
            except Exception:
                self._proc.kill()
        self._started = False

    # -- protocol ----------------------------------------------------------
    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        if self._sock is None or self._rf is None:
            raise EngineError("ENGINE_UNAVAILABLE", "The engine is not connected.",
                              "Restart the MCP server.")
        with self._lock:
            self._id += 1
            req = {"jsonrpc": "2.0", "id": self._id, "auth": self.token,
                   "method": method, "params": params or {}}
            try:
                self._sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
                raw = self._rf.readline()
            except socket.timeout as exc:
                raise EngineError("SIMULATION_TIMEOUT",
                                  f"Engine call '{method}' timed out.",
                                  "Reduce the workload (shorter transient, fewer samples).") from exc
            except OSError as exc:
                raise EngineError("ENGINE_UNAVAILABLE", f"Lost the engine connection: {exc}",
                                  "Restart the MCP server.") from exc
            if not raw:
                raise EngineError("ENGINE_UNAVAILABLE", "The engine closed the connection.",
                                  "Restart the MCP server.")
            resp = json.loads(raw)
            if "error" in resp and resp["error"]:
                err = resp["error"]
                raise EngineError(str(err.get("code", -32603)), str(err.get("message", "engine error")))
            return resp.get("result", {"success": False,
                                       "error": {"code": "INTERNAL", "message": "Empty engine result."}})

    def ping(self) -> bool:
        try:
            return bool(self.call("ping", {}).get("success"))
        except EngineError:
            return False
