#!/usr/bin/env python3
"""Talk to this repo's MCP servers from a shell. Stdlib only.

    mcp_tools.py check                   # does the server start and list its tools? exit 1 if not
    mcp_tools.py list [prefix]           # every tool on one line; `list expectimax` filters
    mcp_tools.py describe <tool>         # the full description and every argument
    mcp_tools.py call <tool> [k=v …]     # call one tool; values parse as JSON where they can

    mcp_tools.py --server bughouse list  # the same, against the bughouse server

Spawns `python3 tools/mcp/<server>/__main__.py` for one request, exactly as
`.mcp.json` does, so what this prints is what the `mcp__<server>__*` tools in
a Claude session do. `--server` (default `chess_prep`, also spelled
`chess-prep`) names any server directory under `tools/mcp/`. Reach for it when
the MCP is not attached to the session you are in (a subagent, a fresh clone
before the server is trusted), to read a tool's contract before calling it, or
to prove the server still starts after editing `tools/mcp/`.

Values: `k=v` is a string unless `v` parses as JSON, so `games=4` is a number,
`open_app=false` a bool, `moves="1. d4 Nf6"` a string, `engines='["a","b"]'`
a list. Set MCP_TOOLS_TIMEOUT (seconds, default 600) for long calls.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]  # .claude/skills/chess-prep-mcp → repo root
TIMEOUT = int(os.environ.get("MCP_TOOLS_TIMEOUT", "600"))

SERVER_NAME = "chess_prep"
SERVER = REPO / "tools/mcp/chess_prep/__main__.py"


def select_server(name: str) -> None:
    """Point every later call at `tools/mcp/<name>/`."""
    global SERVER_NAME, SERVER
    SERVER_NAME = name.replace("-", "_")
    SERVER = REPO / "tools/mcp" / SERVER_NAME / "__main__.py"

INIT = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "mcp_tools.py", "version": "1"},
    },
}


def rpc(requests: list[dict]) -> dict[int, dict]:
    """Send `requests` to a fresh server process; return replies by id."""
    if not SERVER.exists():
        sys.exit(f"server not found at {SERVER}")
    payload = "".join(json.dumps(r) + "\n" for r in requests)
    try:
        proc = subprocess.run(
            [sys.executable, str(SERVER)],
            input=payload,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            cwd=REPO,
        )
    except subprocess.TimeoutExpired:
        sys.exit(f"server did not answer within {TIMEOUT}s (MCP_TOOLS_TIMEOUT)")
    replies: dict[int, dict] = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if isinstance(msg, dict) and "id" in msg:
            replies[msg["id"]] = msg
    if not replies:
        err = proc.stderr.strip()[-2000:]
        sys.exit(
            f"server produced no JSON-RPC reply (exit {proc.returncode})"
            + (f":\n{err}" if err else "")
        )
    return replies


def list_tools() -> list[dict]:
    replies = rpc([INIT, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}])
    reply = replies.get(2) or {}
    if "error" in reply:
        sys.exit(f"tools/list failed: {reply['error']}")
    return reply.get("result", {}).get("tools", [])


def first_line(text: str) -> str:
    return text.strip().split("\n", 1)[0]


def parse_value(raw: str):
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def parse_kv(argv: list[str]) -> dict:
    args: dict = {}
    for item in argv:
        if "=" not in item:
            sys.exit(f"expected key=value, got {item!r}")
        k, v = item.split("=", 1)
        args[k] = parse_value(v)
    return args


def cmd_check() -> None:
    tools = list_tools()
    if not tools:
        sys.exit("server answered tools/list with no tools")
    print(f"{SERVER_NAME} MCP server answers tools/list ({len(tools)} tools)")


def cmd_list(prefix: str | None) -> None:
    for t in list_tools():
        if prefix and not t["name"].startswith(prefix):
            continue
        schema = t.get("inputSchema", {})
        required = schema.get("required") or []
        optional = [p for p in schema.get("properties", {}) if p not in required]
        sig = ", ".join(required + [f"[{p}]" for p in optional]) or "no args"
        print(f"{t['name']}({sig})\n    {first_line(t.get('description', ''))}")


def cmd_describe(name: str) -> None:
    for t in list_tools():
        if t["name"] != name:
            continue
        print(f"# {name}\n")
        print(t.get("description", "").strip(), "\n")
        schema = t.get("inputSchema", {})
        required = set(schema.get("required") or [])
        props = schema.get("properties", {})
        if not props:
            print("(no arguments)")
        for p, spec in props.items():
            flag = "required" if p in required else "optional"
            typ = spec.get("type", "any")
            print(f"- {p} ({typ}, {flag}): {spec.get('description', '').strip()}")
        return
    sys.exit(f"no tool named {name!r} — `mcp_tools.py list` shows them")


def cmd_call(name: str, argv: list[str]) -> None:
    args = parse_kv(argv)
    replies = rpc([
        INIT,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        },
    ])
    reply = replies.get(2) or {}
    if "error" in reply:
        sys.exit(f"error: {reply['error'].get('message', reply['error'])}")
    result = reply.get("result", {})
    for block in result.get("content", []):
        if block.get("type") == "text":
            print(block["text"])
        else:
            print(json.dumps(block, indent=1))
    if result.get("isError"):
        sys.exit(1)


def main(argv: list[str]) -> None:
    if argv and argv[0] == "--server":
        if len(argv) < 2:
            sys.exit("--server <name>")
        select_server(argv[1])
        argv = argv[2:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    if not SERVER.exists():
        sys.exit(f"no server at {SERVER} — `--server <name>` names a directory under tools/mcp/")
    cmd, rest = argv[0], argv[1:]
    if cmd == "check":
        cmd_check()
    elif cmd == "list":
        cmd_list(rest[0] if rest else None)
    elif cmd == "describe":
        if not rest:
            sys.exit("describe <tool>")
        cmd_describe(rest[0])
    elif cmd == "call":
        if not rest:
            sys.exit("call <tool> [k=v …]")
        cmd_call(rest[0], rest[1:])
    else:
        sys.exit(f"unknown command {cmd!r}\n{__doc__}")


if __name__ == "__main__":
    main(sys.argv[1:])
