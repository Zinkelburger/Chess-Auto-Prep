"""MCP stdio server for the bughouse tools.

The wire layer is shared with the other servers under `tools/mcp/`; what is
here is this server's identity and its registry.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import TextIO

if __package__ in (None, ""):  # pragma: no cover - direct execution
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mcp_stdio import StdioServer  # noqa: E402

from .tools import Registry, ToolError  # noqa: E402

SERVER_NAME = "bughouse"
SERVER_VERSION = "1.0.0"


class Server(StdioServer):
    def __init__(
        self, stdin: TextIO | None = None, stdout: TextIO | None = None
    ) -> None:
        super().__init__(
            Registry(),
            name=SERVER_NAME,
            version=SERVER_VERSION,
            tool_error=ToolError,
            stdin=stdin,
            stdout=stdout,
        )


def main() -> None:
    try:
        Server().serve_forever()
    finally:
        from .engine import close_shared

        close_shared()
