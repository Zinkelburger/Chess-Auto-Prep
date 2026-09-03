"""What an agent actually wants to ask about a bughouse position.

Three shapes of question, on top of :mod:`engine` and :mod:`board`:

  ``analyse``   one search of one position, optionally MultiPV, so you get the
                engine's ranked list of joint actions in a single pass.
  ``compare``   a named list of candidate moves, each played and then handed
                to the opponent to answer. This is the honest way to test
                "which of *these* moves is best" — MultiPV only ranks what the
                search chose to visit.
  ``playout``   the engine on both sides for a few joint plies, which is the
                only way to see the piece flow a line actually produces.

A word on the score, because it is not a chess engine's score. Hivemind
reports ``180·tan(1.56·Q)`` of an MCTS Q-value that starts at −1 and is pulled
towards the truth by visits, so at small node counts every score carries a
large negative offset — the balanced starting position reads about −2.3, not
0.00. Within one search at one budget the ordering is meaningful and the gaps
are meaningful; across budgets, or against a chess engine's pawns, they are
not. Everything here therefore compares like with like: one budget, one
perspective, one batch.
"""

from __future__ import annotations

from dataclasses import dataclass

import chess

from .board import BOARD_NAMES, DualBoard, IllegalMove, board_index, parse_move_list, san
from .engine import HivemindEngine, JointMove, SearchResult, shared

DEFAULT_MOVETIME_MS = 5000


@dataclass(frozen=True)
class Budget:
    """How hard to think. Nodes are reproducible; movetime is wall-clock."""

    movetime_ms: int | None = None
    nodes: int | None = None

    @classmethod
    def of(cls, movetime_ms: int | None = None, nodes: int | None = None) -> "Budget":
        if nodes:
            return cls(nodes=int(nodes))
        return cls(movetime_ms=int(movetime_ms or DEFAULT_MOVETIME_MS))

    def run(self, engine: HivemindEngine) -> SearchResult:
        return engine.search(movetime_ms=self.movetime_ms, nodes=self.nodes)

    def as_dict(self) -> dict:
        return {"nodes": self.nodes} if self.nodes else {"movetime_ms": self.movetime_ms}


def position_from(
    dual_fen: str | None = None,
    moves: object = None,
    team: str = "white",
) -> DualBoard:
    """A position written either as a dual FEN, a line of moves, or both."""
    colour = chess.BLACK if str(team).lower().startswith("b") else chess.WHITE
    dual = (
        DualBoard.from_dual_fen(dual_fen, team=colour)
        if dual_fen
        else DualBoard(team=colour)
    )
    for which, text in parse_move_list(moves):
        dual.push(which, text)
    return dual


def _search(
    engine: HivemindEngine,
    dual: DualBoard,
    *,
    team: chess.Color,
    time_advantage: bool,
    require_move_on: str,
    multipv: int,
    budget: Budget,
) -> SearchResult:
    engine.configure(
        team="white" if team == chess.WHITE else "black",
        time_advantage=time_advantage,
        require_move_on=require_move_on,
        multipv=multipv,
    )
    engine.set_position(dual.dual_fen)
    return budget.run(engine)


def _named(dual: DualBoard, which: int, uci: str | None) -> str | None:
    """A joint half rendered as SAN, so a reader sees `Nxf7+` not `f5f7`."""
    if uci is None:
        return None
    try:
        board = dual.boards[which]
        return san(board, board.parse_uci(uci))
    except Exception:
        return uci


def describe_joint(dual: DualBoard, move: JointMove | None) -> dict | None:
    if move is None:
        return None
    return {
        "A": _named(dual, 0, move.a) or "sit",
        "B": _named(dual, 1, move.b) or "sit",
        "uci": str(move),
    }


def analyse(
    *,
    dual_fen: str | None = None,
    moves: object = None,
    team: str = "white",
    time_advantage: bool = False,
    require_move_on: str = "none",
    multipv: int = 1,
    movetime_ms: int | None = None,
    nodes: int | None = None,
    engine: HivemindEngine | None = None,
) -> dict:
    """One search. With ``multipv`` > 1 the engine's ranked root moves come
    back too, which is the cheapest way to see its shortlist."""
    dual = position_from(dual_fen, moves, team)
    budget = Budget.of(movetime_ms, nodes)
    engine = engine or shared()
    result = _search(
        engine,
        dual,
        team=dual.team,
        time_advantage=time_advantage,
        require_move_on=require_move_on,
        multipv=multipv,
        budget=budget,
    )
    return {
        "position": dual.describe(),
        "budget": budget.as_dict(),
        "settings": {
            "team": "white" if dual.team == chess.WHITE else "black",
            "time_advantage": time_advantage,
            "require_move_on": require_move_on,
        },
        "best": describe_joint(dual, result.best),
        "score": result.top.score if result.top else None,
        "depth": result.top.depth if result.top else 0,
        "nodes": result.top.nodes if result.top else 0,
        "lines": [
            {
                **line.as_dict(),
                "best": describe_joint(dual, line.pv[0] if line.pv else None),
            }
            for line in result.lines
        ],
        "note": SCORE_NOTE,
    }


SCORE_NOTE = (
    "Hivemind's score is an MCTS Q-value on a tangent scale, biased negative at "
    "low node counts: a balanced position reads about -2.3 at a few thousand "
    "nodes, not 0.00. Compare moves within one call at one budget; do not read "
    "the absolute number as pawns."
)


def compare(
    *,
    candidates: list[str],
    board: str = "A",
    dual_fen: str | None = None,
    moves: object = None,
    team: str = "white",
    time_advantage: bool = False,
    force_reply: bool = True,
    movetime_ms: int | None = None,
    nodes: int | None = None,
    engine: HivemindEngine | None = None,
) -> dict:
    """Plays each candidate on ``board`` and asks the *opponent* to answer it.

    Every candidate is searched the same way from the same seat, so the column
    to read is the ordering: a lower score for the opponent is a better move
    for us. The opponent's own best reply comes back with it, which is usually
    the more useful half of the answer.
    """
    start = position_from(dual_fen, moves, team)
    which = board_index(board)
    name = BOARD_NAMES[which]
    budget = Budget.of(movetime_ms, nodes)
    engine = engine or shared()
    opponent = not start.team

    rows: list[dict] = []
    for text in candidates:
        after = start.copy()
        try:
            ply = after.push(name, text)
        except IllegalMove as e:
            rows.append({"move": text, "error": str(e)})
            continue
        result = _search(
            engine,
            after,
            # The seat changes hands: whoever must answer is now "the team".
            team=opponent if which == 0 else start.team,
            time_advantage=time_advantage,
            require_move_on=name if force_reply else "none",
            multipv=1,
            budget=budget,
        )
        rows.append(
            {
                "move": ply.san,
                "uci": ply.uci,
                "their_score": result.top.score if result.top else None,
                "their_cp": result.top.score_cp if result.top else None,
                "their_mate": result.top.mate if result.top else None,
                "their_best_reply": describe_joint(after, result.best),
                "their_pv": [str(m) for m in (result.top.pv if result.top else [])][:6],
                "dual_fen": after.dual_fen,
            }
        )

    ranked = sorted(
        (r for r in rows if "error" not in r),
        key=lambda r: _sort_key(r),
    )
    return {
        "position": start.describe(),
        "board": name,
        "budget": budget.as_dict(),
        "ranked": ranked + [r for r in rows if "error" in r],
        "best": ranked[0]["move"] if ranked else None,
        "note": (
            "Ranked by the opponent's score after the move, ascending — lower "
            "is better for us. " + SCORE_NOTE
        ),
    }


def _sort_key(row: dict) -> tuple:
    """Mate for them sorts worst, mate for us best; otherwise by their score."""
    mate = row.get("their_mate")
    if mate is not None:
        return (1, -mate) if mate > 0 else (-1, mate)
    return (0, row.get("their_cp") if row.get("their_cp") is not None else 0)


def playout(
    *,
    plies: int = 6,
    dual_fen: str | None = None,
    moves: object = None,
    team: str = "white",
    time_advantage: bool = False,
    movetime_ms: int | None = None,
    nodes: int | None = None,
    engine: HivemindEngine | None = None,
) -> dict:
    """The engine on both sides for ``plies`` joint actions.

    Each side is asked in turn, so the piece flow is real: what one team
    captures lands in the other board's reserve before the next question.
    """
    dual = position_from(dual_fen, moves, team)
    budget = Budget.of(movetime_ms, nodes)
    engine = engine or shared()
    played: list[dict] = []

    for index in range(plies):
        mover = dual.team if index % 2 == 0 else not dual.team
        if not _can_move(dual, mover):
            # Neither seat of this team is on turn. Asking the engine would
            # only burn a search to be told to sit.
            played.append({"team": _team_name(dual, mover), "action": "no move"})
            continue
        result = _search(
            engine,
            dual,
            team=mover,
            time_advantage=time_advantage,
            require_move_on="none",
            multipv=1,
            budget=budget,
        )
        if result.best is None or result.best.is_empty:
            played.append({"team": _team_name(dual, mover), "action": "sit"})
            continue
        entry = {
            "team": _team_name(dual, mover),
            "score": result.top.score if result.top else None,
            **{k: v for k, v in (describe_joint(dual, result.best) or {}).items()},
        }
        for board_i, name in enumerate(BOARD_NAMES):
            half = result.best.half(board_i)
            if half is None:
                continue
            try:
                dual.push(name, half)
            except IllegalMove as e:
                entry["error"] = str(e)
        played.append(entry)

    return {
        "plies": played,
        "final": dual.describe(),
        "budget": budget.as_dict(),
        "note": SCORE_NOTE,
    }


def _can_move(dual: DualBoard, colour: chess.Color) -> bool:
    """Whether the team holding [colour] on board A is on turn anywhere.

    A team is two seats — `colour` on A and the other colour on B — so it has
    a move exactly when one of those two boards is waiting on it.
    """
    return dual.boards[0].turn == colour or dual.boards[1].turn != colour


def _team_name(dual: DualBoard, colour: chess.Color) -> str:
    ours = colour == dual.team
    side = "white" if colour == chess.WHITE else "black"
    return f"{'us' if ours else 'them'} ({side} on A)"
