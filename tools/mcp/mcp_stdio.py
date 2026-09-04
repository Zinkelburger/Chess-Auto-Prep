"""MCP stdio transport: newline-delimited JSON-RPC 2.0 over stdin/stdout.

Zero dependencies by design — an MCP client starts a server from a bare
`command`/`args` with nothing installed, so the wire layer cannot need a
package. It is shared by every server under `tools/mcp/`; a server supplies a
registry (`definitions()` and `call(name, args)`), its name, and the exception
class that means "the caller asked for something impossible" rather than "the
server broke".
"""

from __future__ import annotations

import json
import sys
import traceback
from typing import Any, Protocol, TextIO

DEFAULT_PROTOCOL = "2024-11-05"


class ToolRegistry(Protocol):
    def definitions(self) -> list[dict]: ...
    def call(self, name: str, args: dict) -> Any: ...


class StdioServer:
    def __init__(
        self,
        registry: ToolRegistry,
        *,
        name: str,
        version: str = "1.0.0",
        tool_error: type[BaseException] = Exception,
        stdin: TextIO | None = None,
        stdout: TextIO | None = None,
    ) -> None:
        self.registry = registry
        self.name = name
        self.version = version
        self.tool_error = tool_error
        self.stdin = stdin or sys.stdin
        self.stdout = stdout or sys.stdout

    # ── Wire ───────────────────────────────────────────────────────────────

    def _send(self, message: dict) -> None:
        # ensure_ascii keeps the transport safe regardless of the client's
        # stdout encoding; the tool text is full of arrows and em dashes.
        self.stdout.write(json.dumps(message, ensure_ascii=True) + "\n")
        self.stdout.flush()

    def _reply(self, request_id: Any, result: dict) -> None:
        self._send({"jsonrpc": "2.0", "id": request_id, "result": result})

    def _error(self, request_id: Any, code: int, message: str) -> None:
        self._send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": code, "message": message},
            }
        )

    @staticmethod
    def _text_result(value: Any, is_error: bool = False) -> dict:
        text = value if isinstance(value, str) else json.dumps(value, indent=2)
        result: dict[str, Any] = {"content": [{"type": "text", "text": text}]}
        if is_error:
            result["isError"] = True
        return result

    # ── Methods ────────────────────────────────────────────────────────────

    def handle(self, message: dict) -> None:
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") or {}

        # Notifications carry no id and must not be answered.
        if request_id is None:
            return

        if method == "initialize":
            requested = params.get("protocolVersion")
            self._reply(
                request_id,
                {
                    "protocolVersion": (
                        requested
                        if isinstance(requested, str)
                        else DEFAULT_PROTOCOL
                    ),
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": self.name, "version": self.version},
                },
            )
        elif method == "tools/list":
            self._reply(request_id, {"tools": self.registry.definitions()})
        elif method == "tools/call":
            self._handle_call(request_id, params)
        elif method == "ping":
            self._reply(request_id, {})
        else:
            self._error(request_id, -32601, f"Method not found: {method}")

    def _handle_call(self, request_id: Any, params: dict) -> None:
        name = params.get("name")
        if not name:
            self._error(request_id, -32602, "Missing tool name.")
            return

        try:
            result = self.registry.call(name, params.get("arguments") or {})
            self._reply(request_id, self._text_result(result))
        except self.tool_error as e:
            # Tool-level failures come back as readable content, not transport
            # errors, so the model can read them and correct itself.
            self._reply(request_id, self._text_result(f"Error: {e}", True))
        except Exception as e:  # noqa: BLE001 - a tool must not kill the server
            detail = traceback.format_exc(limit=3)
            self._reply(
                request_id,
                self._text_result(f"Error: {type(e).__name__}: {e}\n{detail}", True),
            )

    # ── Loop ───────────────────────────────────────────────────────────────

    def serve_forever(self) -> None:
        try:
            for line in self.stdin:
                stripped = line.strip()
                if not stripped:
                    continue

                try:
                    message = json.loads(stripped)
                except json.JSONDecodeError:
                    self._send(
                        {
                            "jsonrpc": "2.0",
                            "id": None,
                            "error": {"code": -32700, "message": "Parse error"},
                        }
                    )
                    continue

                try:
                    self.handle(message)
                except Exception as e:  # noqa: BLE001 - never die on one message
                    request_id = message.get("id")
                    if request_id is not None:
                        self._error(request_id, -32603, f"{type(e).__name__}: {e}")
        finally:
            close = getattr(self.registry, "close", None)
            if close is not None:
                close()
