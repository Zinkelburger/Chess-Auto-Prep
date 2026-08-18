"""Local MCP server: tournament identity/pairing, plus PGN opening-tree query.

Identity tools are zero-dependency. Opening-tree tools (`pgn_open` and friends)
need python-chess (`pip install -r tools/mcp/requirements.txt`).
"""

from .server import Server, main

__all__ = ["Server", "main"]
