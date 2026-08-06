"""Standalone MCP server for Chess Auto Prep tournament identity work.

Runs with no Flutter app: directory lookup, US Chess API, entry-list parsing
and identity proposals all operate on data files. Chess computation (clash,
prep, engine work) stays in the app and is reached through
`tools/mcp/chess_prep_mcp.mjs`.
"""

from .server import Server, main

__all__ = ["Server", "main"]
