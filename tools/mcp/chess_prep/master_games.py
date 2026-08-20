"""Read access to the app's master-games database (The Week in Chess).

The Flutter app downloads TWIC issues into one SQLite file,
``master_games.db`` (see ``lib/services/master_games/``).  These tools read
that same file so an agent can ask "what do masters play here?", pull a
cited game, or list a player's recent games — without the app running and
without re-parsing PGN.

Schema (owned by the app; this side is read-only):

    games(id, twic, event, site, date, round, white, black, result,
          white_elo, black_elo, white_fide, black_fide, eco, ply_count,
          movetext)
    book(pos, move, ply, games, white_wins, draws, black_wins, elo_sum,
         elo_n, max_elo, last_year, top_game, recent_game)
    twic_issues(issue, games, imported_at)
    meta(key, value)

``games.movetext`` is a zlib blob compressed with the preset dictionary
stored under ``meta.key = 'movetext_dict'`` (``zlib.decompressobj(zdict=…)``);
a missing dictionary means plain zlib, and a TEXT value (pre-dictionary
files) is taken as-is.

``book.pos`` is a signed 64-bit FNV-1a over the 4-field FEN — the same
function as ``positionKey`` on the Dart side (``position_key.dart``); the two
are pinned to shared reference values in both test suites.
"""

from __future__ import annotations

import os
import sqlite3
import sys
import zlib
from pathlib import Path
from typing import Any

from .tools import ToolError

_FNV_OFFSET = 0xCBF29CE484222325
_FNV_PRIME = 0x100000001B3
_MASK64 = (1 << 64) - 1

MASTER_DB_NAME = "master_games.db"


def position_key(fen4: str) -> int:
    """Signed 64-bit FNV-1a of a 4-field FEN (must match Dart `positionKey`)."""
    h = _FNV_OFFSET
    for b in fen4.encode("utf-8"):
        h ^= b
        h = (h * _FNV_PRIME) & _MASK64
    return h - (1 << 64) if h >= (1 << 63) else h


def fen4_of(fen: str) -> str:
    """First four FEN fields, as the app's `canonicalizeFen4` does."""
    return " ".join(fen.split()[:4])


def master_db_path() -> Path:
    """Where the app keeps the database.  Override with CHESS_PREP_MASTER_DB."""
    override = os.environ.get("CHESS_PREP_MASTER_DB")
    if override:
        return Path(override).expanduser()
    home = Path.home()
    if sys.platform == "darwin":
        base = home / "Library" / "Application Support"
    elif sys.platform == "win32":
        appdata = os.environ.get("APPDATA")
        base = Path(appdata) if appdata else home / "AppData" / "Roaming"
    else:
        xdg = os.environ.get("XDG_DATA_HOME")
        base = Path(xdg) if xdg else home / ".local" / "share"
    return base / "com.example.chess_auto_prep" / MASTER_DB_NAME


class MasterGamesDb:
    """Read-only handle over the app's database."""

    def __init__(self, path: Path | str | None = None) -> None:
        self.path = Path(path) if path else master_db_path()
        if not self.path.exists():
            raise ToolError(
                f"No master games database at {self.path}. Download it in the "
                "app (Settings → Master games database) or set "
                "CHESS_PREP_MASTER_DB."
            )
        self._conn = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
        self._conn.row_factory = sqlite3.Row
        self._zdict: bytes | None = None
        try:
            r = self._conn.execute(
                "SELECT value FROM meta WHERE key = 'movetext_dict'"
            ).fetchone()
            self._zdict = bytes(r[0]) if r and r[0] else None
        except sqlite3.OperationalError:
            self._zdict = None  # no `meta` table (older file)

    def _movetext(self, raw: Any) -> str:
        if raw is None:
            return ""
        if isinstance(raw, str):
            return raw
        data = bytes(raw)
        d = zlib.decompressobj(zdict=self._zdict) if self._zdict else zlib.decompressobj()
        return (d.decompress(data) + d.flush()).decode("utf-8", "replace")

    def close(self) -> None:
        self._conn.close()

    # ── Queries ───────────────────────────────────────────────────────────

    def stats(self) -> dict:
        c = self._conn
        games = c.execute("SELECT COUNT(*) FROM games").fetchone()[0]
        row = c.execute(
            "SELECT COUNT(*), MIN(issue), MAX(issue) FROM twic_issues"
        ).fetchone()
        return {
            "path": str(self.path),
            "games": games,
            "issues": row[0],
            "first_issue": row[1],
            "last_issue": row[2],
            "file_mb": round(self.path.stat().st_size / 1e6, 1),
        }

    def book(self, fen: str) -> list[dict]:
        """Master moves from a position, most played first."""
        rows = self._conn.execute(
            "SELECT move, games, white_wins, draws, black_wins, elo_sum, elo_n,"
            " max_elo, last_year, top_game, recent_game FROM book"
            " WHERE pos = ? ORDER BY games DESC, max_elo DESC",
            (position_key(fen4_of(fen)),),
        ).fetchall()
        out = []
        for r in rows:
            out.append(
                {
                    "uci": r["move"],
                    "games": r["games"],
                    "white_wins": r["white_wins"],
                    "draws": r["draws"],
                    "black_wins": r["black_wins"],
                    "avg_elo": round(r["elo_sum"] / r["elo_n"]) if r["elo_n"] else None,
                    "max_elo": r["max_elo"],
                    "last_year": r["last_year"],
                    "top_game_id": r["top_game"],
                    "recent_game_id": r["recent_game"],
                }
            )
        return out

    def game(self, game_id: int) -> dict | None:
        r = self._conn.execute(
            "SELECT * FROM games WHERE id = ?", (game_id,)
        ).fetchone()
        return _game_dict(r, self._movetext) if r else None

    def games_by_player(self, name: str, limit: int = 50) -> list[dict]:
        q = f"{name.strip()}%"
        rows = self._conn.execute(
            "SELECT * FROM games WHERE white LIKE ? COLLATE NOCASE"
            " OR black LIKE ? COLLATE NOCASE ORDER BY date DESC LIMIT ?",
            (q, q, limit),
        ).fetchall()
        return [_game_dict(r, self._movetext) for r in rows]


def _game_dict(r: sqlite3.Row, movetext: Any) -> dict:
    d = {k: r[k] for k in r.keys()}
    d["movetext"] = movetext(d.get("movetext"))
    d["citation"] = citation(d)
    d["pgn"] = game_pgn(d)
    return d


def _surname(name: str) -> str:
    s = name.split(",")[0].strip() if name else ""
    return s or "?"


def citation(g: dict) -> str:
    """`Aronian–So, Saint Louis 2026` — the app's citation format."""
    where = (g.get("site") or "").strip() or (g.get("event") or "").strip()
    year = (g.get("date") or "")[:4]
    place = " ".join(p for p in (where, year if year.isdigit() else "") if p)
    names = f"{_surname(g.get('white', ''))}–{_surname(g.get('black', ''))}"
    return f"{names}, {place}" if place else names


def game_pgn(g: dict) -> str:
    def tag(k: str, v: Any) -> str:
        return f'[{k} "{str(v).replace(chr(34), chr(92) + chr(34))}"]'

    lines = [
        tag("Event", g.get("event") or ""),
        tag("Site", g.get("site") or ""),
        tag("Date", g.get("date") or "????.??.??"),
        tag("Round", g.get("round") or "?"),
        tag("White", g.get("white") or ""),
        tag("Black", g.get("black") or ""),
        tag("Result", g.get("result") or "*"),
    ]
    if g.get("white_elo"):
        lines.append(tag("WhiteElo", g["white_elo"]))
    if g.get("black_elo"):
        lines.append(tag("BlackElo", g["black_elo"]))
    if g.get("eco"):
        lines.append(tag("ECO", g["eco"]))
    if g.get("twic"):
        lines.append(tag("Source", f"TWIC {g['twic']}"))
    return "\n".join(lines) + f"\n\n{g.get('movetext', '')} {g.get('result') or '*'}\n"


# ── MCP registration ──────────────────────────────────────────────────────


def _board_from(args: dict):
    """Position from `fen` and/or `moves` (SAN list or PGN-ish string)."""
    try:
        import chess
    except ImportError as e:  # pragma: no cover - env dependent
        raise ToolError(
            "master_book needs python-chess. Install with: pip install python-chess"
        ) from e
    from .opening import fen4, parse_move_list

    board = chess.Board(args["fen"]) if args.get("fen") else chess.Board()
    for san in parse_move_list(args.get("moves")):
        try:
            board.push_san(san)
        except ValueError as e:
            raise ToolError(f"Illegal move {san!r} in the given line.") from e
    return board, fen4(board)


def register_master_games_tools(registry: Any) -> None:
    from .tools import _b, _i, _obj, _s

    handles: dict[str, MasterGamesDb] = {}

    def _db(args: dict) -> MasterGamesDb:
        key = str(args.get("db") or "")
        if key not in handles:
            handles[key] = MasterGamesDb(args.get("db"))
        return handles[key]

    def master_status(args: dict) -> dict:
        s = _db(args).stats()
        s["position_key_note"] = (
            "book.pos = signed 64-bit FNV-1a over the 4-field FEN; "
            "position_key() in chess_prep.master_games reproduces it."
        )
        return s

    def master_book(args: dict) -> dict:
        db = _db(args)
        board, f4 = _board_from(args)
        import chess

        moves = db.book(board.fen())
        limit = int(args.get("limit") or 12)
        total = sum(m["games"] for m in moves)
        out = []
        for m in moves[:limit]:
            mv = chess.Move.from_uci(m["uci"])
            san = board.san(mv) if mv in board.legal_moves else m["uci"]
            entry = dict(m)
            entry["san"] = san
            entry["share"] = round(m["games"] / total, 3) if total else None
            if args.get("cite", True):
                g = db.game(m["top_game_id"])
                if g:
                    entry["top_game"] = {
                        "id": g["id"],
                        "citation": g["citation"],
                        "result": g["result"],
                    }
            out.append(entry)
        return {
            "fen": board.fen(),
            "fen4": f4,
            "games": total,
            "moves": out,
            "next_step": (
                "master_game with an id returns that game's PGN; "
                "master_book again with moves extended walks deeper."
            ),
        }

    def master_game(args: dict) -> dict:
        db = _db(args)
        gid = args.get("id")
        if gid is None:
            raise ToolError("Provide id (from master_book or master_games).")
        g = db.game(int(gid))
        if g is None:
            raise ToolError(f"No game with id {gid}.")
        return g

    def master_games(args: dict) -> dict:
        db = _db(args)
        name = (args.get("player") or "").strip()
        if not name:
            raise ToolError("Provide player (surname, or 'Surname,Initials').")
        games = db.games_by_player(name, int(args.get("limit") or 30))
        brief = [
            {k: g[k] for k in ("id", "white", "black", "result", "date", "event", "eco")}
            for g in games
        ]
        return {"player": name, "count": len(brief), "games": brief}

    registry._add(
        "master_status",
        "Coverage of the app's local master-games database (TWIC): game "
        "count, issue range, file size. Read-only; the app owns the file.",
        _obj({"db": _s("Path to master_games.db (default: the app's)")}),
        master_status,
    )
    registry._add(
        "master_book",
        "What titled players play from a position: moves with game counts, "
        "W/D/L, average and top Elo, last year, and the strongest game that "
        "played each move (citation + id). Give `moves` from the start "
        "position and/or a `fen`. Positions are keyed by FEN, so move orders "
        "that transpose give the same answer.",
        _obj(
            {
                "moves": _s("SAN list or PGN-ish string, e.g. '1. d4 Nf6 2. c4'"),
                "fen": _s("Start from this FEN instead of the initial position"),
                "limit": _i("Max moves to return (default 12)"),
                "cite": _b("Include the strongest game per move (default true)"),
                "db": _s("Path to master_games.db (default: the app's)"),
            }
        ),
        master_book,
    )
    registry._add(
        "master_game",
        "One master game by id (from master_book/master_games): headers, "
        "movetext and full PGN.",
        _obj(
            {
                "id": _i("Game id"),
                "db": _s("Path to master_games.db (default: the app's)"),
            },
            ["id"],
        ),
        master_game,
    )
    registry._add(
        "master_games",
        "Recent master games of a player (surname prefix match on either "
        "colour), newest first.",
        _obj(
            {
                "player": _s("Surname, or 'Surname,Initials' as TWIC writes it"),
                "limit": _i("Max games (default 30)"),
                "db": _s("Path to master_games.db (default: the app's)"),
            },
            ["player"],
        ),
        master_games,
    )
