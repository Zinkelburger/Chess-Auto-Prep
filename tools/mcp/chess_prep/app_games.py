"""Read access to the user's own games database (``app_games.db``).

Every game the Flutter app downloads or imports — Player Analysis downloads
(``analysis:<player>``), the home games library (``library:<platform>_<user>``)
and the tactics archive (``tactics``) — is parsed once into this SQLite file
with indexed headers and an opening position index (first 30 plies), keyed
by the same FNV-1a position key as the master database.  These tools let an
agent ask "which of my games reached this position?" or "what did this
opponent play?" without touching PGN files.

Schema (owned by the app; read-only here):

    games(id, collection, game_key, white, black, result, date, played_at,
          speed, white_elo, black_elo, eco, headers_json, pgn, imported_at)
    positions(pos, game_id, ply)
    collections(collection, updated_at, meta_json)
"""

from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Any

from .master_games import fen4_of, master_db_path, position_key
from .tools import ToolError

APP_GAMES_DB_NAME = "app_games.db"


def app_games_db_path() -> Path:
    """Next to master_games.db in the app's support directory.  Override with
    CHESS_PREP_APP_GAMES_DB."""
    override = os.environ.get("CHESS_PREP_APP_GAMES_DB")
    if override:
        return Path(override).expanduser()
    return master_db_path().parent / APP_GAMES_DB_NAME


class AppGamesDb:
    def __init__(self, path: Path | str | None = None) -> None:
        self.path = Path(path) if path else app_games_db_path()
        if not self.path.exists():
            raise ToolError(
                f"No games database at {self.path}. It is created when the app "
                "downloads or imports games; or set CHESS_PREP_APP_GAMES_DB."
            )
        self._conn = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
        self._conn.row_factory = sqlite3.Row

    def close(self) -> None:
        self._conn.close()

    def collections(self) -> list[dict]:
        rows = self._conn.execute(
            "SELECT g.collection, COUNT(*) AS n, c.updated_at FROM games g"
            " LEFT JOIN collections c ON c.collection = g.collection"
            " GROUP BY g.collection ORDER BY n DESC"
        ).fetchall()
        return [
            {"collection": r["collection"], "games": r["n"], "updated_at": r["updated_at"]}
            for r in rows
        ]

    def games_at(self, fen: str, collection: str | None = None, limit: int = 50) -> list[dict]:
        sql = (
            "SELECT g.* FROM games g JOIN positions p ON p.game_id = g.id"
            " WHERE p.pos = ?"
        )
        args: list[Any] = [position_key(fen4_of(fen))]
        if collection:
            sql += " AND g.collection = ?"
            args.append(collection)
        sql += " ORDER BY g.played_at DESC, g.id DESC LIMIT ?"
        args.append(limit)
        return [_game(r) for r in self._conn.execute(sql, args).fetchall()]

    def by_player(self, name: str, collection: str | None = None, limit: int = 50) -> list[dict]:
        q = f"{name.strip()}%"
        sql = (
            "SELECT * FROM games WHERE (white LIKE ? COLLATE NOCASE"
            " OR black LIKE ? COLLATE NOCASE)"
        )
        args: list[Any] = [q, q]
        if collection:
            sql += " AND collection = ?"
            args.append(collection)
        sql += " ORDER BY played_at DESC, id DESC LIMIT ?"
        args.append(limit)
        return [_game(r) for r in self._conn.execute(sql, args).fetchall()]

    def game(self, game_id: int) -> dict | None:
        r = self._conn.execute("SELECT * FROM games WHERE id = ?", (game_id,)).fetchone()
        return _game(r) if r else None


def _game(r: sqlite3.Row) -> dict:
    d = {k: r[k] for k in r.keys()}
    try:
        d["headers"] = json.loads(d.pop("headers_json") or "{}")
    except json.JSONDecodeError:
        d["headers"] = {}
    return d


def register_app_games_tools(registry: Any) -> None:
    from .master_games import _board_from
    from .tools import _i, _obj, _s

    handles: dict[str, AppGamesDb] = {}

    def _db(args: dict) -> AppGamesDb:
        key = str(args.get("db") or "")
        if key not in handles:
            handles[key] = AppGamesDb(args.get("db"))
        return handles[key]

    def _brief(g: dict) -> dict:
        return {
            k: g.get(k)
            for k in ("id", "collection", "white", "black", "result", "date", "speed", "eco")
        }

    def my_games_status(args: dict) -> dict:
        db = _db(args)
        return {"path": str(db.path), "collections": db.collections()}

    def my_games_at(args: dict) -> dict:
        db = _db(args)
        board, f4 = _board_from(args)
        games = db.games_at(
            board.fen(), args.get("collection"), int(args.get("limit") or 50)
        )
        return {
            "fen": board.fen(),
            "fen4": f4,
            "count": len(games),
            "games": [_brief(g) for g in games],
        }

    def my_games_by_player(args: dict) -> dict:
        db = _db(args)
        name = (args.get("player") or "").strip()
        if not name:
            raise ToolError("Provide player (username or surname prefix).")
        games = db.by_player(name, args.get("collection"), int(args.get("limit") or 50))
        return {"player": name, "count": len(games), "games": [_brief(g) for g in games]}

    def my_game(args: dict) -> dict:
        db = _db(args)
        gid = args.get("id")
        if gid is None:
            raise ToolError("Provide id (from my_games_at / my_games_by_player).")
        g = db.game(int(gid))
        if g is None:
            raise ToolError(f"No game with id {gid}.")
        return g

    registry._add(
        "my_games_status",
        "Collections in the user's own games database (Player Analysis "
        "downloads, games library, tactics archive) with game counts.",
        _obj({"db": _s("Path to app_games.db (default: the app's)")}),
        my_games_status,
    )
    registry._add(
        "my_games_at",
        "The user's (or an analysed opponent's) games that reached a position "
        "in the opening, newest first. Give `moves` and/or `fen`; restrict "
        "with `collection` (e.g. 'analysis:chesscom_hikaru').",
        _obj(
            {
                "moves": _s("SAN list or PGN-ish string from the start position"),
                "fen": _s("Start from this FEN instead of the initial position"),
                "collection": _s("Only this collection (see my_games_status)"),
                "limit": _i("Max games (default 50)"),
                "db": _s("Path to app_games.db (default: the app's)"),
            }
        ),
        my_games_at,
    )
    registry._add(
        "my_games_by_player",
        "Games in the user's database where a player (username/surname prefix) "
        "had either colour, newest first.",
        _obj(
            {
                "player": _s("Username or surname prefix"),
                "collection": _s("Only this collection"),
                "limit": _i("Max games (default 50)"),
                "db": _s("Path to app_games.db (default: the app's)"),
            },
            ["player"],
        ),
        my_games_by_player,
    )
    registry._add(
        "my_game",
        "One game from the user's database by id: headers and full PGN.",
        _obj(
            {"id": _i("Game id"), "db": _s("Path to app_games.db (default: the app's)")},
            ["id"],
        ),
        my_game,
    )
