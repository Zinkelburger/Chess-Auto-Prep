"""FEN-keyed opening tree over a PGN, for agent queries.

Chessable / repertoire files are path trees: 1.d4 Nf6 2.e3 c5 lives on a
different branch from 1.d4 c5 2.e3 Nf6 even though the positions are the
same. This module indexes every ply by a 4-field FEN (en passant only when
a capture is legal, matching the Flutter `canonicalizeFen4` + dartchess
convention) so a query by either move order sees the same continuations,
and a position the PGN never reached still lists legal moves that
*transpose into* a known FEN.

Requires `python-chess`. Stockfish is optional and only used by pgn_eval /
pgn_audit (`STOCKFISH` env or a binary on PATH).
"""

from __future__ import annotations

import io
import os
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .chessdb import DEFAULT_WINDOW_CP, client_for as chessdb_client, within
from .tools import ToolError

_CHESS_ERR = (
    "Opening-tree tools need python-chess. Install with: pip install python-chess"
)

_NULL_SANS = frozenset({"--", "Z0", "0000", "@@@@"})
_NULL_TOKEN_RE = re.compile(r"\b(Z0|0000|@@@@)\b")
_MOVE_NUM_RE = re.compile(r"^\d+\.+$")
_RESULT_TOKENS = frozenset({"*", "1-0", "0-1", "1/2-1/2"})
_NAG_NAMES = {
    1: "good",
    2: "mistake",
    3: "brilliant",
    4: "blunder",
    5: "interesting",
    6: "dubious",
    7: "forced",
    10: "equal",
    14: "white better",
    15: "black better",
    16: "white much better",
    17: "black much better",
    18: "white winning",
    19: "black winning",
}


def _require_chess():
    try:
        import chess  # noqa: F401
        import chess.pgn  # noqa: F401
    except ImportError as e:
        raise ToolError(_CHESS_ERR) from e


def fen4(board) -> str:
    """4-field FEN; EP square only when a capture is actually legal."""
    import chess

    ep = chess.square_name(board.ep_square) if board.has_legal_en_passant() else "-"
    parts = board.fen().split()
    parts[3] = ep
    return " ".join(parts[:4])


def parse_move_list(raw: Any) -> list[str]:
    """Accept a SAN list or a PGN-ish string ('1. d4 Nf6 2. c4')."""
    if raw is None:
        return []
    if isinstance(raw, list):
        return [str(t).strip() for t in raw if str(t).strip()]
    text = str(raw)
    text = re.sub(r"\{[^}]*\}", " ", text)
    tokens = text.replace("\n", " ").split()
    out: list[str] = []
    for tok in tokens:
        t = tok.strip(".,")
        if not t or t in _RESULT_TOKENS:
            continue
        if t.isdigit() or _MOVE_NUM_RE.fullmatch(tok) or _MOVE_NUM_RE.fullmatch(t):
            continue
        if t.startswith("$"):
            continue
        out.append(t)
    return out


def _truncate(text: str, limit: int = 400) -> str:
    text = " ".join(text.split())
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def _chapter_label(headers) -> str:
    white = (headers.get("White") or "").strip()
    black = (headers.get("Black") or "").strip()
    if white and black and white != black:
        return f"{white} — {black}"
    return white or black or "(untitled)"


def _score_from_result(result: str) -> float | None:
    r = (result or "*").strip()
    if r in ("*", ""):
        return None
    if r == "1-0":
        return 1.0
    if r == "0-1":
        return 0.0
    return 0.5


def _promote_dummy_mainline(game) -> None:
    """Chessable intro: `1. Z0 (1. d4 …)` → promote the real lesson."""
    import chess

    if len(game.variations) != 2:
        return
    dummy = game.variations[0]
    if dummy.move != chess.Move.null():
        return
    if dummy.variations:
        return
    promoted = game.variations[1]
    carried = (dummy.comment or "").strip()
    if carried:
        promoted.comment = f"{carried} {promoted.comment}".strip()
    game.variations.pop(0)


@dataclass
class MoveStat:
    games: int = 0
    wins: int = 0
    draws: int = 0
    losses: int = 0
    comments: list[str] = field(default_factory=list)
    nags: list[int] = field(default_factory=list)
    chapters: list[str] = field(default_factory=list)

    def add(
        self,
        score: float | None,
        comment: str,
        nags: list[int],
        chapter: str,
    ) -> None:
        self.games += 1
        if score is not None:
            if score >= 0.9:
                self.wins += 1
            elif score <= 0.1:
                self.losses += 1
            else:
                self.draws += 1
        if comment:
            clipped = _truncate(comment)
            if clipped not in self.comments and len(self.comments) < 8:
                self.comments.append(clipped)
        for nag in nags:
            if nag not in self.nags:
                self.nags.append(nag)
        if chapter and chapter not in self.chapters and len(self.chapters) < 8:
            self.chapters.append(chapter)

    def to_dict(self, san: str, via_transposition: bool = False) -> dict:
        out: dict[str, Any] = {
            "san": san,
            "games": self.games,
            "wins": self.wins,
            "draws": self.draws,
            "losses": self.losses,
            "via_transposition": via_transposition,
        }
        if self.comments:
            out["comments"] = self.comments
        if self.nags:
            out["nags"] = [
                {"id": n, "name": _NAG_NAMES.get(n, f"${n}")} for n in self.nags
            ]
        if self.chapters:
            out["chapters"] = self.chapters
        return out


@dataclass
class FenStat:
    games: int = 0
    wins: int = 0
    draws: int = 0
    losses: int = 0
    moves: dict[str, MoveStat] = field(default_factory=dict)
    comments: list[str] = field(default_factory=list)
    sample_paths: list[list[str]] = field(default_factory=list)
    chapters: list[str] = field(default_factory=list)

    def add_visit(self, score: float | None, chapter: str, path: list[str]) -> None:
        self.games += 1
        if score is not None:
            if score >= 0.9:
                self.wins += 1
            elif score <= 0.1:
                self.losses += 1
            else:
                self.draws += 1
        if chapter and chapter not in self.chapters and len(self.chapters) < 12:
            self.chapters.append(chapter)
        if path and len(self.sample_paths) < 5 and path not in self.sample_paths:
            self.sample_paths.append(list(path))


class OpeningGraph:
    def __init__(self, path: str, max_ply: int = 50) -> None:
        self.path = path
        self.max_ply = max_ply
        self.positions: dict[str, FenStat] = {}
        self.games = 0
        self.skipped = 0
        self.chapters: list[str] = []

    def _pos(self, key: str) -> FenStat:
        return self.positions.setdefault(key, FenStat())

    def load(self, text: str, include_variations: bool = True) -> None:
        import chess
        import chess.pgn

        prepared = _NULL_TOKEN_RE.sub("--", text)
        handle = io.StringIO(prepared)
        while True:
            try:
                game = chess.pgn.read_game(handle)
            except Exception:
                self.skipped += 1
                break
            if game is None:
                break
            _promote_dummy_mainline(game)
            chapter = _chapter_label(game.headers)
            if chapter not in self.chapters:
                self.chapters.append(chapter)
            score = _score_from_result(game.headers.get("Result", "*"))
            try:
                board = game.board()
            except Exception:
                self.skipped += 1
                continue
            self.games += 1
            start_key = fen4(board)
            self._pos(start_key).add_visit(score, chapter, [])
            self._walk(
                board,
                game,
                [],
                0,
                chapter,
                score,
                include_variations,
                chess,
            )

    def _walk(
        self,
        board,
        node,
        path: list[str],
        ply: int,
        chapter: str,
        score: float | None,
        include_variations: bool,
        chess_mod,
    ) -> None:
        if ply >= self.max_ply:
            return
        parent_key = fen4(board)
        variations = list(node.variations)
        for i, child in enumerate(variations):
            if not include_variations and i > 0:
                break
            move = child.move
            if move is None:
                continue
            is_null = move == chess_mod.Move.null()
            try:
                san = "--" if is_null else board.san(move)
            except Exception:
                continue
            comment = (child.comment or "").strip()
            nags = sorted(int(n) for n in child.nags)
            if i > 0:
                self._pos(parent_key).add_visit(score, chapter, path)
            try:
                board.push(move)
            except Exception:
                continue
            dest_key = fen4(board)
            dest_path = path if is_null else path + [san]
            dest = self._pos(dest_key)
            dest.add_visit(score, chapter, dest_path)
            if comment:
                clipped = _truncate(comment)
                if clipped not in dest.comments and len(dest.comments) < 8:
                    dest.comments.append(clipped)
            if not is_null:
                parent = self._pos(parent_key)
                parent.moves.setdefault(san, MoveStat()).add(
                    score, comment, nags, chapter
                )
            self._walk(
                board,
                child,
                dest_path,
                ply + (0 if is_null else 1),
                chapter,
                score,
                include_variations,
                chess_mod,
            )
            board.pop()

    def play(self, sans: list[str], start_fen: str | None = None):
        import chess

        board = chess.Board(start_fen) if start_fen else chess.Board()
        played: list[str] = []
        for san in sans:
            if san in _NULL_SANS:
                board.push(chess.Move.null())
                continue
            try:
                move = board.parse_san(san)
            except Exception as e:
                raise ToolError(
                    f'Illegal or unparsed SAN "{san}" after {" ".join(played) or "start"}: {e}'
                ) from e
            board.push(move)
            played.append(san)
        return board, played

    def query(self, board, played: list[str]) -> dict[str, Any]:
        key = fen4(board)
        stat = self.positions.get(key)
        in_book = stat is not None
        played_sans = set(stat.moves) if stat else set()
        moves = []
        if stat:
            moves = [
                m.to_dict(san)
                for san, m in sorted(
                    stat.moves.items(), key=lambda kv: -kv[1].games
                )
            ]
        transposing = []
        for move in board.legal_moves:
            try:
                san = board.san(move)
            except Exception:
                continue
            if san in played_sans:
                continue
            board.push(move)
            dest_key = fen4(board)
            dest_stat = self.positions.get(dest_key)
            board.pop()
            if dest_stat is None:
                continue
            row = {
                "san": san,
                "games": dest_stat.games,
                "via_transposition": True,
                "fen": dest_key,
            }
            if dest_stat.sample_paths:
                row["transposes_to"] = dest_stat.sample_paths[0]
            if dest_stat.chapters:
                row["chapters"] = dest_stat.chapters[:6]
            transposing.append(row)
        transposing.sort(key=lambda r: -r["games"])

        out: dict[str, Any] = {
            "fen": board.fen(),
            "fen4": key,
            "in_book": in_book,
            "ply": len(played),
            "to_move": "white" if board.turn else "black",
            "moves_played": played,
            "games": stat.games if stat else 0,
            "moves": moves,
            "transposing_moves": transposing,
        }
        if stat:
            if stat.comments:
                out["comments"] = stat.comments
            if stat.sample_paths:
                out["incoming_paths"] = stat.sample_paths
            if stat.chapters:
                out["chapters"] = stat.chapters
            out["wins"] = stat.wins
            out["draws"] = stat.draws
            out["losses"] = stat.losses
        return out

    def walk(self, sans: list[str]) -> dict[str, Any]:
        import chess

        board = chess.Board()
        start = self.query(board, [])
        plies = [
            {
                "ply": 0,
                "san": None,
                "in_book": start["in_book"],
                "via_transposition": False,
                "fen4": start["fen4"],
                "to_move": start["to_move"],
                "book_replies": [m["san"] for m in start["moves"][:12]],
                "transposing_in": [m["san"] for m in start["transposing_moves"][:12]],
            }
        ]
        played: list[str] = []
        left_book_at: int | None = None
        for i, san in enumerate(sans, start=1):
            before = self.query(board, played)
            in_played = any(m["san"] == san for m in before["moves"])
            in_transp = any(m["san"] == san for m in before["transposing_moves"])
            try:
                move = board.parse_san(san)
            except Exception as e:
                raise ToolError(f'Illegal SAN "{san}" at ply {i}: {e}') from e
            board.push(move)
            played.append(san)
            after = self.query(board, played)
            if not after["in_book"] and left_book_at is None:
                left_book_at = i
            plies.append(
                {
                    "ply": i,
                    "san": san,
                    "in_book": after["in_book"],
                    "via_transposition": bool(in_transp and not in_played),
                    "played_from_this_move_order": in_played,
                    "fen4": after["fen4"],
                    "to_move": after["to_move"],
                    "games": after["games"],
                    "book_replies": [m["san"] for m in after["moves"][:12]],
                    "transposing_in": [m["san"] for m in after["transposing_moves"][:12]],
                    "chapters": after.get("chapters", [])[:6],
                    "comments": after.get("comments", [])[:3],
                }
            )
        return {
            "in_book_at_end": plies[-1]["in_book"],
            "left_book_at_ply": left_book_at,
            "plies": plies,
        }


class GraphCache:
    def __init__(self) -> None:
        self._graphs: dict[str, OpeningGraph] = {}

    def load(
        self,
        path: str,
        *,
        reload: bool = False,
        include_variations: bool = True,
        max_ply: int = 50,
    ) -> OpeningGraph:
        resolved = str(Path(path).expanduser().resolve())
        if not reload and resolved in self._graphs:
            return self._graphs[resolved]
        p = Path(resolved)
        if not p.is_file():
            raise ToolError(f"PGN not found: {resolved}")
        graph = OpeningGraph(resolved, max_ply=max_ply)
        graph.load(p.read_text(encoding="utf-8", errors="replace"), include_variations)
        self._graphs[resolved] = graph
        return graph

    def get(self, path: str) -> OpeningGraph:
        resolved = str(Path(path).expanduser().resolve())
        graph = self._graphs.get(resolved)
        if graph is None:
            return self.load(resolved)
        return graph


def _find_stockfish() -> str:
    env = os.environ.get("STOCKFISH")
    if env and Path(env).is_file():
        return env
    for name in (
        "stockfish",
        "stockfish-ubuntu-x86-64",
        "stockfish-windows.exe",
        "stockfish-macos",
    ):
        found = shutil.which(name)
        if found:
            return found
    here = Path(__file__).resolve()
    repo = here.parents[3]
    for candidate in (
        repo / "assets" / "executables" / "stockfish-ubuntu-x86-64",
        repo / "assets" / "executables" / "stockfish",
    ):
        if candidate.is_file():
            return str(candidate)
    raise ToolError(
        "Stockfish not found. Set STOCKFISH to the binary, or install it on PATH."
    )


def _eval_board(board, depth: int, multipv: int) -> list[dict]:
    import chess
    import chess.engine

    engine_path = _find_stockfish()
    try:
        engine = chess.engine.SimpleEngine.popen_uci(engine_path)
    except Exception as e:
        raise ToolError(f"Could not start Stockfish at {engine_path}: {e}") from e
    try:
        info = engine.analyse(
            board,
            chess.engine.Limit(depth=depth),
            multipv=max(1, multipv),
        )
    finally:
        engine.quit()
    if isinstance(info, dict):
        info = [info]
    lines = []
    for entry in info:
        pv = entry.get("pv") or []
        score = entry.get("score")
        if score is None:
            continue
        pov = score.white()
        mate = pov.mate()
        cp = None if mate is not None else pov.score()
        sans: list[str] = []
        tmp = board.copy()
        for mv in pv[:16]:
            try:
                sans.append(tmp.san(mv))
                tmp.push(mv)
            except Exception:
                break
        lines.append(
            {
                "san": sans[0] if sans else None,
                "pv": sans,
                "score_cp_white": cp,
                "mate_white": mate,
            }
        )
    return lines


def _int_arg(args: dict, key: str, default: int) -> int:
    """An integer argument where 0 is a real value, not "unset"."""
    value = args.get(key)
    return default if value is None else int(value)


def _schema(properties: dict, required: list[str] | None = None) -> dict:
    schema: dict[str, Any] = {
        "type": "object",
        "properties": properties,
        "additionalProperties": False,
    }
    if required:
        schema["required"] = required
    return schema


def _s(desc: str) -> dict:
    return {"type": "string", "description": desc}


def _i(desc: str) -> dict:
    return {"type": "integer", "description": desc}


def _b(desc: str) -> dict:
    return {"type": "boolean", "description": desc}


def register_opening_tools(registry: Any) -> None:
    cache: GraphCache = getattr(registry, "_opening_graphs", None) or GraphCache()
    registry._opening_graphs = cache

    def _graph(args: dict) -> OpeningGraph:
        path = args.get("path")
        if not path:
            raise ToolError("Provide path to a PGN file.")
        return cache.load(
            path,
            reload=bool(args.get("reload")),
            include_variations=args.get("include_variations", True),
            max_ply=int(args.get("max_ply") or 50),
        )

    def pgn_open(args: dict) -> dict:
        _require_chess()
        g = _graph(args)
        return {
            "path": g.path,
            "games": g.games,
            "skipped": g.skipped,
            "positions": len(g.positions),
            "chapters": g.chapters[:40],
            "chapter_count": len(g.chapters),
            "next_step": (
                "Call pgn_position or pgn_walk with the same path. "
                "Positions are keyed by FEN, so 1.d4 c5 2.e3 Nf6 and "
                "1.d4 Nf6 2.e3 c5 are the same query."
            ),
        }

    def pgn_position(args: dict) -> dict:
        _require_chess()
        g = cache.get(args.get("path") or "")
        sans = parse_move_list(args.get("moves"))
        start = args.get("fen")
        board, played = g.play(sans, start)
        result = g.query(board, played)
        result["path"] = g.path
        return result

    def pgn_walk(args: dict) -> dict:
        _require_chess()
        g = cache.get(args.get("path") or "")
        sans = parse_move_list(args.get("moves"))
        if not sans:
            raise ToolError("pgn_walk needs moves (SAN list or movetext).")
        result = g.walk(sans)
        result["path"] = g.path
        return result

    def pgn_eval(args: dict) -> dict:
        _require_chess()
        g = cache.get(args.get("path") or "")
        sans = parse_move_list(args.get("moves"))
        start = args.get("fen")
        board, played = g.play(sans, start)
        depth = int(args.get("depth") or 16)
        multipv = int(args.get("multipv") or 3)
        lines = _eval_board(board, depth=depth, multipv=multipv)
        pos = g.query(board, played)
        return {
            "fen": board.fen(),
            "fen4": pos["fen4"],
            "in_book": pos["in_book"],
            "book_moves": [m["san"] for m in pos["moves"][:8]],
            "depth": depth,
            "lines": lines,
        }

    def pgn_audit(args: dict) -> dict:
        _require_chess()
        import chess

        g = cache.get(args.get("path") or "")
        sans = parse_move_list(args.get("moves"))
        side = (args.get("side") or "white").lower()
        depth = int(args.get("depth") or 14)
        threshold = int(args.get("threshold_cp") or 80)
        max_positions = _int_arg(args, "max_positions", 20)
        check_mistakes = bool(args.get("check_mistakes", True))
        check_replies = bool(args.get("check_replies", True)) and side != "both"
        reply_window = _int_arg(args, "reply_window_cp", DEFAULT_WINDOW_CP)
        board = chess.Board()
        checkpoints: list[tuple[list[str], Any, FenStat]] = []
        # Positions where the *opponent* moves and the file has replies —
        # where a strong uncovered reply would be a hole.
        reply_points: list[tuple[list[str], Any, FenStat]] = []
        played: list[str] = []

        def note(path: list[str], b, stat: FenStat | None) -> None:
            if not stat:
                return
            stm = "white" if b.turn else "black"
            if side == "both" or side == stm:
                checkpoints.append((path, b.copy(), stat))
            elif check_replies and stat.moves:
                reply_points.append((path, b.copy(), stat))

        if sans:
            for san in sans:
                note(list(played), board, g.positions.get(fen4(board)))
                try:
                    board.push(board.parse_san(san))
                except Exception as e:
                    raise ToolError(f'Illegal SAN "{san}": {e}') from e
                played.append(san)
            note(list(played), board, g.positions.get(fen4(board)))
        else:
            # Heaviest in-book positions for the requested side.
            ranked = sorted(
                g.positions.items(), key=lambda kv: -kv[1].games
            )
            for key, stat in ranked:
                if not stat.moves:
                    continue
                b = chess.Board()
                # Reconstruct a board from a sample path when we have one.
                if not stat.sample_paths:
                    continue
                try:
                    b, path = g.play(stat.sample_paths[0])
                except ToolError:
                    continue
                if fen4(b) != key:
                    continue
                stm = "white" if b.turn else "black"
                if side != "both" and side != stm:
                    if check_replies and len(reply_points) < max_positions:
                        reply_points.append((path, b, stat))
                    continue
                checkpoints.append((path, b, stat))
                if len(checkpoints) >= max_positions:
                    break

        # Reply gaps first: a database lookup each, no engine needed, and the
        # answer stands even when Stockfish is not installed.
        gaps: list[dict] = []
        reply_status = "skipped" if not check_replies else "ok"
        replies_checked = 0
        engine_status = "ok" if check_mistakes else "skipped"
        engine_gap_status = "ok"
        if check_replies:
            client = chessdb_client(registry)
            chessdb_down = False
            for path, b, stat in reply_points[:max_positions]:
                known: list[dict] = []
                source = "chessdb"
                if not chessdb_down:
                    try:
                        known = client.query(b.fen())
                    except ToolError as e:
                        reply_status = f"chessdb unavailable: {e}"
                        chessdb_down = True
                # Stockfish stands in where the database has nothing: it
                # sees only multipv moves, but it knows every position.
                if not known and engine_gap_status == "ok":
                    try:
                        lines = _eval_board(b, depth=depth, multipv=3)
                    except ToolError as e:
                        engine_gap_status = f"unavailable: {e}"
                        lines = []
                    stm_sign = 1 if b.turn else -1
                    known = [
                        {
                            "san": ln["san"],
                            "uci": ln.get("uci", ""),
                            "score_cp": stm_sign * ln["score_cp_white"],
                        }
                        for ln in lines
                        if ln.get("score_cp_white") is not None and ln.get("san")
                    ]
                    known.sort(key=lambda m: -m["score_cp"])
                    source = "stockfish"
                if not known:
                    continue
                replies_checked += 1
                covered = set(stat.moves)
                good = within(known, reply_window)
                for m in good:
                    san = m["san"] or b.san(chess.Move.from_uci(m["uci"]))
                    if san in covered:
                        continue
                    gaps.append(
                        {
                            "moves": path,
                            "fen": b.fen(),
                            "uncovered_reply": san,
                            "score_cp": m["score_cp"],
                            "behind_best_cp": known[0]["score_cp"] - m["score_cp"],
                            "opponent_good_moves": len(good),
                            "source": source,
                            "file_replies": sorted(covered),
                            "chapters": stat.chapters[:4],
                        }
                    )
            if chessdb_down and engine_gap_status != "ok":
                reply_status = f"{reply_status}; engine {engine_gap_status}"
            # Sharp positions first: an uncovered level move where the
            # opponent has two is half their theory; where they have twelve
            # it is one more quiet move.
            gaps.sort(key=lambda g: (g["opponent_good_moves"], g["behind_best_cp"]))

        findings = []
        checked = 0
        for path, b, stat in checkpoints if check_mistakes else []:
            if checked >= max_positions:
                break
            if not stat.moves:
                continue
            stm = "white" if b.turn else "black"
            if side != "both" and side != stm:
                continue
            checked += 1
            book_move = max(stat.moves.items(), key=lambda kv: kv[1].games)[0]
            try:
                lines = _eval_board(b, depth=depth, multipv=3)
            except ToolError as e:
                engine_status = f"unavailable: {e}"
                checked -= 1
                break
            if not lines:
                continue
            best = lines[0]
            book_line = next((ln for ln in lines if ln.get("san") == book_move), None)
            best_cp = best.get("score_cp_white")
            book_cp = book_line.get("score_cp_white") if book_line else None
            if best.get("mate_white") is not None or (
                book_line and book_line.get("mate_white") is not None
            ):
                gap = None
                is_mistake = book_line is None or best.get("mate_white") != (
                    book_line.get("mate_white") if book_line else None
                )
            else:
                if best_cp is None or book_cp is None:
                    gap = None
                    is_mistake = book_line is None
                else:
                    # White-POV scores: a White-book move that is worse for
                    # White by more than the threshold is a mistake; same
                    # for Black with the sign flipped.
                    if stm == "white":
                        gap = best_cp - book_cp
                    else:
                        gap = book_cp - best_cp
                    is_mistake = gap >= threshold
            if is_mistake:
                findings.append(
                    {
                        "moves": path,
                        "fen": b.fen(),
                        "side": stm,
                        "book_move": book_move,
                        "engine_best": best.get("san"),
                        "engine_pv": best.get("pv"),
                        "gap_cp": gap,
                        "book_in_multipv": book_line is not None,
                        "chapters": stat.chapters[:4],
                    }
                )
        return {
            "path": g.path,
            "checked": checked,
            "mistakes": len(findings),
            "threshold_cp": threshold,
            "depth": depth,
            "engine": engine_status,
            "findings": findings,
            "reply_check": reply_status,
            "reply_positions_checked": replies_checked,
            "reply_window_cp": reply_window,
            "gaps": gaps,
            "reading": (
                "findings: your own book move is worse than the engine's. "
                "gaps: an opponent reply ChessDB (or, where it knows nothing, "
                "Stockfish MultiPV) scores within reply_window_cp of their best "
                "that the file does not answer — played or not. Sorted sharpest "
                "position first (fewest opponent_good_moves)."
            ),
        }

    _path = _s("Absolute path to a .pgn file.")
    _moves = {
        "type": ["string", "array"],
        "items": {"type": "string"},
        "description": 'SAN list or movetext, e.g. "1. d4 Nf6 2. c4 c5" or ["d4","Nf6"].',
    }

    registry._add(
        "pgn_open",
        "Load a PGN (Chessable course, repertoire, or game collection) into "
        "a FEN-keyed opening tree. Transpositions are merged: 1.d4 Nf6 2.e3 c5 "
        "and 1.d4 c5 2.e3 Nf6 are the same position. Call this once per file, "
        "then pgn_position / pgn_walk / pgn_eval / pgn_audit.",
        _schema(
            {
                "path": _path,
                "reload": _b("Re-parse even if this path is already loaded."),
                "include_variations": _b(
                    "Fold RAVs into the tree (default true; right for courses)."
                ),
                "max_ply": _i("Stop walking each line after this many plies (default 50)."),
            },
            ["path"],
        ),
        pgn_open,
    )
    registry._add(
        "pgn_position",
        "Query one position in a loaded PGN tree. Pass moves (any move order) "
        "or a FEN. Returns book continuations actually played from this FEN, "
        "plus legal moves that transpose into a known FEN even if that SAN "
        "was never played from this move order — e.g. after 1.d4 c5 2.e3, "
        "Nf6 appears because 1.d4 Nf6 2.e3 c5 is in the file.",
        _schema(
            {
                "path": _path,
                "moves": _moves,
                "fen": _s("Start from this FEN instead of the standard start (then apply moves)."),
            },
            ["path"],
        ),
        pgn_position,
    )
    registry._add(
        "pgn_walk",
        "Walk a candidate line ply by ply against a loaded PGN tree. Each ply "
        "says whether the position is in book, whether the move was a "
        "one-ply transposition, the book replies, and comments/chapters. Use "
        "this to ask 'what does this Colle file play against 1.d4 Nf6 2.c4 c5'.",
        _schema({"path": _path, "moves": _moves}, ["path", "moves"]),
        pgn_walk,
    )
    registry._add(
        "pgn_eval",
        "Run Stockfish on a position (end of `moves`, or `fen`). Returns MultiPV "
        "lines (White's POV) and the book moves at that FEN so you can compare.",
        _schema(
            {
                "path": _path,
                "moves": _moves,
                "fen": _s("Evaluate this FEN; moves are applied after it if both are set."),
                "depth": _i("Search depth (default 16)."),
                "multipv": _i("Number of engine lines (default 3)."),
            },
            ["path"],
        ),
        pgn_eval,
    )
    registry._add(
        "pgn_audit",
        "Audit a repertoire PGN two ways. Along `moves` (or, without them, the "
        "heaviest in-book positions): (1) where it is `side`'s turn, compare "
        "the file's most-played move with Stockfish and report ones worse by "
        "threshold_cp; (2) where it is the opponent's turn, ask ChessDB for "
        "replies scoring within reply_window_cp of their best and report any "
        "the file has no answer to — the sound sideline nobody plays yet. "
        "Part (2) needs no engine.",
        _schema(
            {
                "path": _path,
                "moves": _moves,
                "side": _s("Whose repertoire: 'white', 'black', or 'both' (default white; 'both' skips the reply check)."),
                "depth": _i("Search depth (default 14)."),
                "threshold_cp": _i("Flag a book move at least this many cp worse than the engine (default 80)."),
                "max_positions": _i("Cap on positions evaluated per check (default 20)."),
                "check_mistakes": _b("Compare the file's moves with Stockfish (default true; off needs no engine)."),
                "check_replies": _b("Look for uncovered strong opponent replies via ChessDB, falling back to Stockfish MultiPV where ChessDB knows nothing (default true)."),
                "reply_window_cp": _i(f"A reply counts as strong within this many cp of the opponent's best (default {DEFAULT_WINDOW_CP})."),
            },
            ["path"],
        ),
        pgn_audit,
    )


__all__ = [
    "OpeningGraph",
    "GraphCache",
    "fen4",
    "parse_move_list",
    "register_opening_tools",
]
