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
reports ``180·tan(1.56·Q)`` of an MCTS Q-value, and that carries a large
offset whose *sign depends on the* ``TimeAdvantage`` *option*: a balanced
position reads about −2.3 with the option off and about +2.3 with it on. See
:data:`LEVEL_BASELINE`. Every result here therefore reports ``relative`` — the
score with the right baseline removed, where 0.00 is level — alongside the
engine's raw number, and never compares two searches run under different
options. Within one search at one budget the ordering and the gaps are
meaningful; across budgets, or against a chess engine's pawns, they are not.
"""

from __future__ import annotations

from dataclasses import dataclass

import chess

from .board import BOARD_NAMES, DualBoard, IllegalMove, board_index, parse_move_list, san
from .engine import HivemindEngine, JointMove, Line, SearchResult, shared

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


LEVEL_BASELINE = {False: -2.30, True: 2.30}
"""Where a dead-level position sits on Hivemind's scale, per ``TimeAdvantage``.

Measured, not chosen, and the *sign flips with the bit*: the starting position
on both boards reads -2.33/-2.24 with the option off and +2.39/+2.26 with it
on, from either seat, at every node count we have tried. Subtracting one fixed
constant therefore mis-reads every ``time_advantage=True`` search by about 4.6
— which is exactly the size of the "sitting is worth a lot" illusion it used to
produce.
"""


def baseline_for(time_advantage: bool) -> float:
    """The zero point of the scale for a search run under this option."""
    return LEVEL_BASELINE[bool(time_advantage)]


def relative_score(cp: int | None, time_advantage: bool) -> float | None:
    """The score with the baseline taken out: 0.00 is level, + is good for us."""
    return None if cp is None else round(cp / 100.0 - baseline_for(time_advantage), 2)


def _score_note(time_advantage: bool) -> str:
    return (
        "Hivemind's score is an MCTS Q-value on a tangent scale with a large "
        f"offset: a balanced position reads about {baseline_for(time_advantage):+.2f} "
        f"with time_advantage={time_advantage}, not 0.00 — and that offset "
        "changes sign with the option, so scores from calls made under "
        "different time_advantage values are not comparable at all. Read "
        "`relative` (the score with the baseline removed, 0.00 = level) rather "
        "than `score`, and compare moves within one call at one budget."
    )


SCORE_NOTE = _score_note(False)


def by_strength(lines: list[Line]) -> list[Line]:
    """The engine's MultiPV block, reordered best-first by score.

    Hivemind ranks MultiPV by MCTS visit count, not by evaluation, so its
    rank 3 routinely scores better than its rank 2. Rank 1 is left pinned at
    the front because that is the line ``bestmove`` is aligned with — the
    engine's own solver-aware choice, which is not always its highest score.
    """
    def strength(line: Line) -> tuple:
        """Higher is better for the team that was searched."""
        if line.mate is not None:
            # We mate: best, and sooner is better. They mate: worst, and later
            # is less bad. Negating in both branches gives that ordering.
            return (2 if line.mate > 0 else 0, -line.mate)
        return (1, line.score_cp if line.score_cp is not None else 0)

    return lines[:1] + sorted(lines[1:], key=strength, reverse=True)


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
        "relative": relative_score(
            result.top.score_cp if result.top else None, time_advantage
        ),
        "baseline": baseline_for(time_advantage),
        "depth": result.top.depth if result.top else 0,
        "nodes": result.top.nodes if result.top else 0,
        # Best first by score, not by the engine's own MultiPV order — that is
        # an MCTS visit count, so rank 3 routinely outscores rank 2.
        "lines": [
            {
                **line.as_dict(),
                "relative": relative_score(line.score_cp, time_advantage),
                "best": describe_joint(dual, line.pv[0] if line.pv else None),
            }
            for line in by_strength(result.lines)
        ],
        "note": _score_note(time_advantage),
    }



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

    "The opponent" is decided by the position, not by the board: a candidate is
    played by whoever is on turn there, and the team that has to answer is the
    one holding the *other* seat on that board. See :func:`answering_team`.
    """
    start = position_from(dual_fen, moves, team)
    which = board_index(board)
    name = BOARD_NAMES[which]
    budget = Budget.of(movetime_ms, nodes)
    engine = engine or shared()
    answers = answering_team(start, which)

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
            team=answers,
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
                "their_relative": relative_score(
                    result.top.score_cp if result.top else None, time_advantage
                ),
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
        "answered_by": "white" if answers == chess.WHITE else "black",
        "note": (
            "Ranked by the opponent's score after the move, ascending — lower "
            "is better for us. `answered_by` names the team that was searched "
            "to produce it (a team is named by its colour on board A). "
            + _score_note(time_advantage)
        ),
    }


def answering_team(dual: DualBoard, which: int) -> chess.Color:
    """Which team has to answer a move played on board ``which``.

    A team is named by its colour on board A, and the two seats of a board
    belong to opposite teams. So the answer is not "the opponent of whoever
    called this" — it is derived from the position:

        board A   the mover is a colour on A, so the answering team is the
                  other colour on A: ``not mover``.
        board B   a colour on B belongs to the team playing the *other* colour
                  on A, so the mover's team is ``not mover`` and the answering
                  team is ``mover`` itself.

    Keying this off the board index instead — assuming A is always ours and B
    always our partner's — searches the wrong team whenever the caller hands in
    a position where the other side is on move there, which an odd-length line
    or any board-B candidate does.
    """
    mover = dual.boards[which].turn
    return (not mover) if which == 0 else mover


def _sort_key(row: dict) -> tuple:
    """Mate for them sorts worst, mate for us best; otherwise by their score.

    Within each mate group the *faster* mate sorts first, which for a mate
    against them (a negative number) means ordering by distance, not by the
    signed value: #-1 has to beat #-8.
    """
    mate = row.get("their_mate")
    if mate is not None:
        return (1, -mate) if mate > 0 else (-1, -mate)
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
            "relative": relative_score(
                result.top.score_cp if result.top else None, time_advantage
            ),
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
        "note": _score_note(time_advantage),
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
