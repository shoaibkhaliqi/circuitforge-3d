import sys

from . import server as srv


def _run(coro):
    import anyio
    return anyio.run(coro)


def _count(result):
    items = getattr(result, "tools", None) or getattr(result, "resources", None) or getattr(result, "prompts", None)
    return len(items) if items is not None else len(result)


def selftest() -> int:
    print("CircuitForge 3D MCP adapter — selftest")
    print(f"  godot   = {srv.find_godot()}")
    print(f"  project = {srv.find_project()}")
    try:
        engine = srv.get_engine()
        info = engine.call("get_simulator_info")
        print(f"  engine  = ok  app={info.get('application')} v={info.get('application_version')} "
              f"proto={info.get('api_protocol')} port=127.0.0.1:{engine.port}")
    except Exception as exc:
        print(f"  engine  = FAILED: {exc}")
        srv.close_engine()
        return 1
    try:
        print(f"  tools     = {_count(_run(srv.mcp.list_tools))}")
        print(f"  resources = {_count(_run(srv.mcp.list_resources))}")
        print(f"  prompts   = {_count(_run(srv.mcp.list_prompts))}")
    except Exception as exc:
        print(f"  introspection failed: {exc}")
    srv.close_engine()
    print("selftest OK")
    return 0


def main() -> None:
    if "--selftest" in sys.argv[1:]:
        raise SystemExit(selftest())
    srv.main()


if __name__ == "__main__":
    main()
