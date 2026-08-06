"""MCP stdio server: newline-delimited JSON-RPC 2.0 over stdin/stdout.

Zero dependencies by design — this has to start reliably from an MCP client's
`command`/`args` with nothing installed.
"""

from __future__ import annotations

import json
import sys
import traceback
from typing import Any, TextIO

from .tools import Registry, ToolError

SERVER_NAME = "chess-prep"
SERVER_VERSION = "1.0.0"
DEFAULT_PROTOCOL = "2024-11-05"


class Server:
    def __init__(
        self, stdin: TextIO | None = None, stdout: TextIO | None = None
    ) -> None:
        self.stdin = stdin or sys.stdin
        self.stdout = stdout or sys.stdout
        self.registry = Registry()

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
                    "serverInfo": {
                        "name": SERVER_NAME,
                        "version": SERVER_VERSION,
                    },
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
        except ToolError as e:
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


def main() -> None:
    Server().serve_forever()
