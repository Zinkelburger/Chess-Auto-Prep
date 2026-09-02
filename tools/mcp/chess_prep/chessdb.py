"""ChessDB (chessdb.cn) lookups for the opening tools.

One question, asked of one endpoint: *every move the database knows from
this position, scored*. The answer is what the in-app mainline book is built
from, and it is the one source here that can say a move is **good** rather
than **played** — Maia and the game databases report what people do; ChessDB
reports what holds up. That is the difference between "nobody plays 7.Bg5"
and "7.Bg5 is level with the main move and your file has no answer to it".

Zero dependencies: `urllib` and the standard library. The fetch is
injectable so tests never touch the network, and answers are cached per
position for the life of the server because a tree walk asks about the same
positions many times over.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable

from .tools import ToolError

CDB_URL = "http://www.chessdb.cn/cdb.php"
USER_AGENT = "chess-auto-prep-mcp/1.0"

#: A URL to a response body. Tests pass a fake.
Fetch = Callable[[str], str]

#: Default window for "a reply as good as the best one", in centipawns.
DEFAULT_WINDOW_CP = 50


def fen4(fen: str) -> str:
    """Board, side, castling, en passant — what ChessDB keys on."""
    return " ".join(fen.split()[:4])


def _http_fetch(url: str, timeout: float = 20.0) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read().decode("utf-8", errors="replace")
    except urllib.error.URLError as e:  # includes HTTPError
        raise ToolError(f"ChessDB unreachable: {e}") from e


def parse_queryall(body: str) -> list[dict[str, Any]]:
    """Moves from a `queryall` JSON body, best first. Empty when the
    database does not know the position (`status` is `unknown`, `nobestmove`,
    or the body is not the JSON we expect)."""
    text = body.strip()
    if not text:
        return []
    try:
        decoded = json.loads(text)
    except json.JSONDecodeError:
        return []
    if not isinstance(decoded, dict) or decoded.get("status") != "ok":
        return []
    raw = decoded.get("moves")
    if not isinstance(raw, list):
        return []

    moves: list[dict[str, Any]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        uci = str(entry.get("uci") or "")
        if not uci:
            continue
        try:
            score = int(entry.get("score"))
        except (TypeError, ValueError):
            continue
        move: dict[str, Any] = {
            "uci": uci,
            "san": str(entry.get("san") or ""),
            "score_cp": score,
        }
        note = entry.get("note")
        if note:
            move["note"] = str(note)
        rank = entry.get("rank")
        if isinstance(rank, int):
            move["rank"] = rank
        moves.append(move)

    # Score decides; the sort is stable so exact ties keep ChessDB's order.
    moves.sort(key=lambda m: -m["score_cp"])
    return moves


def within(moves: list[dict[str, Any]], window_cp: int) -> list[dict[str, Any]]:
    """The moves scoring within `window_cp` of the best, best first."""
    if not moves:
        return []
    top = moves[0]["score_cp"]
    return [m for m in moves if top - m["score_cp"] <= window_cp]


class ChessDbClient:
    def __init__(self, fetch: Fetch | None = None) -> None:
        self._fetch = fetch or _http_fetch
        self._cache: dict[str, list[dict[str, Any]]] = {}
        self.requests = 0

    def query(self, fen: str) -> list[dict[str, Any]]:
        """Every move ChessDB knows from `fen`, best first; empty on a miss.
        Raises ToolError when the server cannot be reached at all — a miss
        and an outage need opposite handling, and only one is an answer."""
        key = fen4(fen)
        cached = self._cache.get(key)
        if cached is not None:
            return cached
        url = f"{CDB_URL}?action=queryall&json=1&board={urllib.parse.quote(key)}"
        self.requests += 1
        moves = parse_queryall(self._fetch(url))
        self._cache[key] = moves
        return moves


def client_for(registry: Any) -> ChessDbClient:
    """The registry's shared client — created on first use, replaced by tests."""
    client = getattr(registry, "_chessdb", None)
    if client is None:
        client = ChessDbClient()
        registry._chessdb = client
    return client


# ── Tool ───────────────────────────────────────────────────────────────────


def _board_from_args(args: dict):
    import chess  # python-chess; the opening tools require it too

    from .opening import parse_move_list

    fen = args.get("fen")
    try:
        board = chess.Board(fen) if fen else chess.Board()
    except ValueError as e:
        raise ToolError(f"Bad FEN: {e}") from e
    played: list[str] = []
    for san in parse_move_list(args.get("moves")):
        try:
            board.push(board.parse_san(san))
        except ValueError as e:
            raise ToolError(f'Illegal SAN "{san}" after {" ".join(played)}: {e}') from e
        played.append(san)
    return board, played


def _int_arg(args: dict, key: str, default: int) -> int:
    """An integer argument where 0 is a real value, not "unset"."""
    value = args.get(key)
    return default if value is None else int(value)


def register_chessdb_tools(registry: Any) -> None:
    def chessdb_query(args: dict) -> dict:
        board, played = _board_from_args(args)
        window = _int_arg(args, "window_cp", DEFAULT_WINDOW_CP)
        with_replies = bool(args.get("with_replies", True))
        max_replies = _int_arg(args, "max_good_moves", 6)
        client = client_for(registry)

        moves = client.query(board.fen())
        stm = "white" if board.turn else "black"
        if not moves:
            return {
                "fen": board.fen(),
                "side_to_move": stm,
                "known": False,
                "moves": [],
                "note": "ChessDB does not know this position.",
            }

        good = within(moves, window)
        good_out = []
        for m in good[:max_replies]:
            entry = dict(m)
            if with_replies:
                child = board.copy()
                child.push_uci(m["uci"])
                replies = client.query(child.fen())
                if replies:
                    good_replies = within(replies, window)
                    entry["opponent_good_replies"] = len(good_replies)
                    entry["opponent_replies"] = [
                        {"san": r["san"], "score_cp": r["score_cp"]}
                        for r in good_replies[:8]
                    ]
                else:
                    entry["opponent_good_replies"] = None
            good_out.append(entry)

        return {
            "fen": board.fen(),
            "side_to_move": stm,
            "known": True,
            "best_cp": moves[0]["score_cp"],
            "window_cp": window,
            "good_count": len(good),
            "good_moves": good_out,
            "moves": moves[:12],
            "scores": (
                "score_cp is from the side to move's point of view, after the "
                "move. opponent_good_replies counts the replies scoring within "
                "window_cp of the opponent's best — fewer means a narrower book "
                "to learn for the same eval."
            ),
        }

    registry._add(
        "chessdb_query",
        "Ask ChessDB (chessdb.cn) for every move it knows from a position, "
        "scored best-first, plus the moves within window_cp of the best and "
        "how many good replies each of those leaves the opponent. Use it to "
        "compare two level candidates by how narrow the opponent's choice "
        "becomes, or to find a sound sideline no game database shows. Pass "
        "moves (any order, from the start) and/or a FEN.",
        {
            "type": "object",
            "properties": {
                "moves": {
                    "type": ["string", "array"],
                    "items": {"type": "string"},
                    "description": 'SAN list or movetext, e.g. "1. e4 e5 2. Nf3".',
                },
                "fen": {
                    "type": "string",
                    "description": "Start from this FEN instead of the standard start (moves are applied after it).",
                },
                "window_cp": {
                    "type": "integer",
                    "description": f"A move counts as good within this many cp of the best (default {DEFAULT_WINDOW_CP}).",
                },
                "with_replies": {
                    "type": "boolean",
                    "description": "Also count the opponent's good replies after each good move (one lookup each; default true).",
                },
                "max_good_moves": {
                    "type": "integer",
                    "description": "Cap on good moves given reply counts (default 6).",
                },
            },
            "additionalProperties": False,
        },
        chessdb_query,
    )


__all__ = [
    "ChessDbClient",
    "DEFAULT_WINDOW_CP",
    "client_for",
    "fen4",
    "parse_queryall",
    "register_chessdb_tools",
    "within",
]
