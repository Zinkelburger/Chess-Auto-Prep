"""Reading the opening book: the query behind the explorer.

Everything here is read-only.  The book is a build artefact -- rebuild it,
never patch it -- and the app opens the same file the same way.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

from .paths import book_path
from .poskey import dual_key_fen, position_key


class BookMissing(Exception):
    def __init__(self, path: Path) -> None:
        super().__init__(
            f"no bughouse book at {path}\n"
            "Build one with:\n"
            "  python3 -m bughouse_db fetch\n"
            "  python3 -m bughouse_db index"
        )


def open_book(path: Path | None = None) -> sqlite3.Connection:
    target = path or book_path()
    if not target.exists():
        raise BookMissing(target)
    con = sqlite3.connect(f"file:{target}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def meta(con: sqlite3.Connection) -> dict[str, str]:
    return {r["key"]: r["value"] for r in con.execute("SELECT key, value FROM meta")}


def explore(con: sqlite3.Connection, fen_a: str, fen_b: str) -> dict:
    """Every recorded continuation from a two-board position.

    `move` keeps BPGN's board+mover letter, so a caller can tell a board A
    reply from a board B one without re-deriving whose turn it is where.
    Win rates are team-relative: `team_a` is WhiteA's pair.
    """
    key = position_key(dual_key_fen(fen_a, fen_b))
    node = con.execute("SELECT * FROM node WHERE pos = ?", (key,)).fetchone()
    rows = con.execute(
        "SELECT * FROM edge WHERE pos = ? ORDER BY games DESC", (key,)
    ).fetchall()
    total = node["games"] if node else sum(r["games"] for r in rows)
    moves = []
    for row in rows:
        moves.append(
            {
                "board": row["move"][0],
                "san": row["move"][2:],
                "games": row["games"],
                "team_a": row["team_a"],
                "team_b": row["team_b"],
                "draws": row["draws"],
                "unknown": row["unknown"],
                "play_rate": 100.0 * row["games"] / total if total else 0.0,
                "avg_elo": row["elo_sum"] // row["elo_n"] if row["elo_n"] else 0,
                "max_elo": row["max_elo"],
                "last_year": row["last_year"],
                "top_game": row["top_game"],
            }
        )
    return {
        "pos": key,
        "games": total,
        "team_a": node["team_a"] if node else 0,
        "team_b": node["team_b"] if node else 0,
        "draws": node["draws"] if node else 0,
        "unknown": node["unknown"] if node else 0,
        "moves": moves,
    }
