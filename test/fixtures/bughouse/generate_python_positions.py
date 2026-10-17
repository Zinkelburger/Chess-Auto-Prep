#!/usr/bin/env python3
"""Writes python_positions.json: two-board lines played by the Python tools.

The v2 bughouse lab reads books the Python tools write
(`tools/bughouse_db/hivemind_book.py`, `tools/bughouse_db/index.py`), keyed
by `poskey.position_key` of `DualBoard`'s FENs. The Dart tests replay each
line and check they reach the same dual FEN, the same SAN for every ply and
the same key, so a position the book holds is a position the lab finds.

    python3 test/fixtures/v2_bughouse/generate_python_positions.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / "tools" / "mcp"))
sys.path.insert(0, str(REPO / "tools"))

from bughouse.board import DualBoard  # noqa: E402
from bughouse_db.poskey import dual_key_fen, position_key  # noqa: E402

START = DualBoard().dual_fen

CASES = [
    ("", ""),
    ("", "A:e4"),
    ("", "A:e4 B:d4"),
    # A capture on board 1 lands in board 2's reserve, colour kept.
    ("", "A:e4 A:d5 A:exd5"),
    # Two kinds of piece in one reserve: the pocket order is what the key
    # canonicalises.
    ("", "A:e4 A:d5 A:exd5 A:Qxd5 A:Nc3 A:Qxg2 A:Bxg2"),
    # Drops, and a capture on board 2 feeding board 1.
    ("", "A:e4 A:d5 A:exd5 B:e4 B:P@d5 B:exd5"),
    # En passant is written only while it can be taken, then taken.
    ("", "A:e4 A:Nf6 A:e5 A:d5"),
    ("", "A:e4 A:Nf6 A:e5 A:d5 A:exd6"),
    # Castling, written e1g1 in UCI.
    ("", "A:e4 A:e5 A:Nf3 A:Nc6 A:Bc4 A:Bc5 A:O-O"),
    # A promoted queen is captured and goes over as a pawn.
    (
        "1r2k3/P7/8/8/8/8/1r6/4K3[] w - - 0 1|" + START.split("|")[1],
        "A:axb8=Q+ A:Rxb8",
    ),
]


def play(root: str, line: str) -> dict:
    dual = DualBoard.from_dual_fen(root) if root else DualBoard()
    plies = []
    for tag in line.split():
        board, text = tag.split(":", 1)
        ply = dual.push(board, text)
        plies.append({"board": ply.board, "san": ply.san, "uci": ply.uci})
    a, b = (board.fen() for board in dual.boards)
    key_fen = dual_key_fen(a, b)
    return {
        "root": root,
        "line": line,
        "plies": plies,
        "dual_fen": dual.dual_fen,
        "key_fen": key_fen,
        "key": position_key(key_fen),
    }


def main() -> None:
    cases = [play(root, line) for root, line in CASES]
    out = HERE / "python_positions.json"
    out.write_text(json.dumps({"cases": cases}, indent=1) + "\n")
    print(f"wrote {len(cases)} cases to {out}")


if __name__ == "__main__":
    main()
