"""One bughouse game played in virtual time.

Engines are far faster than people, so wall-clock time says nothing about how
a seat would fare on a real clock. The arena owns four simulated clocks
instead, and every move costs the mover a sampled amount of virtual time no
matter how long the engine really took. Results stay reproducible like a
fixed-node test, but sitting now costs exactly what it costs at a real table.

Time model, all integers in milliseconds:

* Both boards run concurrently. On each board exactly one seat is on turn, and
  its clock is running, whether it is thinking or sitting.
* A seat that comes on turn thinks for ``move_cost`` and then decides, seeing
  the position as it stands at that moment (pieces its partner sent meanwhile
  included). It either moves or sits.
* A sitting seat wakes ``react_cost`` after any move on the other board, and
  immediately when its team's time advantage flips; nothing else changes what
  it sees, so it is not asked again until then. Its clock runs throughout.
* A clock that reaches zero loses for its team.

Time advantage uses Hivemind's training definition (src/domain/board2planes.py
in the Hivemind repository): a
team is up on time when its board-A seat has more time than its diagonal
opponent, the same-colour seat on board B.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Protocol

import chess

from .referee import (BOARD_A, BOARD_B, BOARDS, Bughouse, IllegalMove,
                      seat_team, team_name)

SEAT_NAMES = ("A-white", "A-black", "B-white", "B-black")


def seat_index(board: int, color: chess.Color) -> int:
    return board * 2 + (0 if color == chess.WHITE else 1)


def seat_of(index: int) -> tuple[int, chess.Color]:
    return index // 2, chess.WHITE if index % 2 == 0 else chess.BLACK


@dataclass(frozen=True)
class ClockConfig:
    initial_ms: int = 120_000
    move_cost_ms: tuple[int, int] = (1_500, 2_500)
    react_cost_ms: int = 500

    def __post_init__(self) -> None:
        low, high = self.move_cost_ms
        if self.initial_ms <= 0 or low <= 0 or high < low or self.react_cost_ms < 0:
            raise ValueError(f"invalid clock configuration: {self}")


@dataclass
class SeatView:
    """What a player is shown when asked to decide."""
    game: Bughouse
    board: int
    color: chess.Color
    team: chess.Color
    time_advantage: bool
    clocks_ms: tuple[int, int, int, int]
    now_ms: int
    sitting: bool


class Player(Protocol):
    name: str

    def new_game(self, board: int, color: chess.Color) -> None: ...

    def decide(self, view: SeatView) -> str | None:
        """A UCI move for ``view.board``, or ``None`` to sit."""


@dataclass
class GameResult:
    winner: chess.Color | None
    termination: str
    duration_ms: int
    clocks_ms: list[int]
    moves: list[str]
    events: list[dict] = field(default_factory=list)
    decisions: list[int] = field(default_factory=lambda: [0, 0])
    sits: list[int] = field(default_factory=lambda: [0, 0])
    sit_ms: list[int] = field(default_factory=lambda: [0, 0])
    advantage_decisions: list[int] = field(default_factory=lambda: [0, 0])
    error: str | None = None

    def to_json(self) -> dict:
        return {
            "winner": None if self.winner is None else team_name(self.winner),
            "termination": self.termination,
            "duration_ms": self.duration_ms,
            "clocks_ms": self.clocks_ms,
            "moves": self.moves,
            "decisions": {"white": self.decisions[chess.WHITE], "black": self.decisions[chess.BLACK]},
            "sits": {"white": self.sits[chess.WHITE], "black": self.sits[chess.BLACK]},
            "sit_ms": {"white": self.sit_ms[chess.WHITE], "black": self.sit_ms[chess.BLACK]},
            "advantage_decisions": {
                "white": self.advantage_decisions[chess.WHITE],
                "black": self.advantage_decisions[chess.BLACK]},
            "error": self.error,
            "events": self.events,
        }


class MoveCosts:
    """Seeded think costs, keyed by seat and that seat's move number so the
    two games of an opening pair charge every seat the same sequence."""

    def __init__(self, config: ClockConfig, key: str):
        self.config = config
        self.key = key

    def sample(self, seat: int, move_number: int) -> int:
        low, high = self.config.move_cost_ms
        if low == high:
            return low
        return random.Random(f"{self.key}:{seat}:{move_number}").randint(low, high)


def time_advantage(clocks: list[int], team: chess.Color) -> bool:
    return clocks[seat_index(BOARD_A, team)] > clocks[seat_index(BOARD_B, team)]


def play_game(game: Bughouse,
              players: dict[int, Player],
              config: ClockConfig,
              cost_key: str = "0",
              max_decisions: int = 20_000,
              record_events: bool = True,
              on_event=None) -> GameResult:
    """Play ``game`` to a result. ``players`` maps seat index to player."""
    costs = MoveCosts(config, cost_key)
    clocks = [config.initial_ms] * 4
    now = 0
    moves_made = [0] * 4
    sitting = [False, False]
    sit_since = [0, 0]
    result = GameResult(None, "", 0, clocks, [])

    for index, player in players.items():
        player.new_game(*seat_of(index))

    def to_move(board: int) -> int:
        return seat_index(board, game.turn(board))

    pending: list[int | None] = [costs.sample(to_move(b), 0) for b in BOARDS]

    def log(kind: str, board: int | None, seat: int | None, **extra) -> None:
        if not (record_events or on_event):
            return
        event = {"t": now, "kind": kind,
                 "seat": None if seat is None else SEAT_NAMES[seat],
                 "clocks": list(clocks), **extra}
        if board is not None:
            event["board"] = "AB"[board]
        if record_events:
            result.events.append(event)
        if on_event:
            on_event(event)

    def finish(winner: chess.Color | None, termination: str) -> GameResult:
        result.winner = winner
        result.termination = termination
        result.duration_ms = now
        result.clocks_ms = list(clocks)
        result.moves = game.engine_moves()
        for board in BOARDS:
            if sitting[board]:
                result.sit_ms[seat_team(board, game.turn(board))] += now - sit_since[board]
        log("end", None, None, winner=None if winner is None else team_name(winner),
            termination=termination)
        return result

    def terminal(first: chess.Color) -> GameResult | None:
        for team in (first, not first):
            if game.is_checkmate(team, time_advantage(clocks, team)):
                return finish(not team, "checkmate")
        if game.is_draw():
            return finish(None, "draw")
        return None

    def advantage_flip(team: chess.Color) -> int | None:
        a = seat_index(BOARD_A, team)
        b = seat_index(BOARD_B, team)
        lead = clocks[a] - clocks[b]
        slope = (1 if to_move(BOARD_B) == b else 0) - (1 if to_move(BOARD_A) == a else 0)
        if lead > 0 and slope < 0:
            return now + lead            # lead hits zero: no longer ahead
        if lead <= 0 and slope > 0:
            return now - lead + 1        # first millisecond strictly ahead
        return None

    done = terminal(chess.WHITE)
    if done:
        return done

    decisions = 0
    while True:
        # (time, priority, subject, kind): a flag beats a flip beats a move at
        # the same millisecond; board A breaks the remaining ties.
        candidates = []
        for board in BOARDS:
            candidates.append((now + clocks[to_move(board)], 0, board, "flag"))
        for team in (chess.WHITE, chess.BLACK):
            flip = advantage_flip(team)
            if flip is not None:
                candidates.append((flip, 1, 0 if team == chess.WHITE else 1, "flip"))
        for board in BOARDS:
            if pending[board] is not None:
                candidates.append((pending[board], 2, board, "decide"))
        when, _, subject, kind = min(candidates)

        elapsed = when - now
        for board in BOARDS:
            clocks[to_move(board)] -= elapsed
        now = when

        if kind == "flag":
            seat = to_move(subject)
            clocks[seat] = 0
            log("flag", subject, seat)
            return finish(not seat_team(subject, game.turn(subject)), "flag")

        if kind == "flip":
            team = chess.WHITE if subject == 0 else chess.BLACK
            log("flip", None, None, team=team_name(team),
                advantage=time_advantage(clocks, team))
            for board in BOARDS:
                if sitting[board] and seat_team(board, game.turn(board)) == team:
                    pending[board] = now
            done = terminal(team)
            if done:
                return done
            continue

        board = subject
        seat = to_move(board)
        color = game.turn(board)
        team = seat_team(board, color)
        advantage = time_advantage(clocks, team)
        decisions += 1
        if decisions > max_decisions:
            return finish(None, "decision limit")
        result.decisions[team] += 1
        result.advantage_decisions[team] += int(advantage)
        view = SeatView(game.copy(), board, color, team, advantage,
                        tuple(clocks), now, sitting[board])
        try:
            uci = players[seat].decide(view)
        except Exception as error:  # engine crash: no result, not a loss
            result.error = f"{SEAT_NAMES[seat]}: {error}"
            return finish(None, "error")

        if uci is None:
            if not sitting[board]:
                sitting[board] = True
                sit_since[board] = now
            result.sits[team] += 1
            pending[board] = None
            log("sit", board, seat, advantage=advantage)
            continue

        try:
            game.push(board, uci)
        except IllegalMove as error:
            result.error = f"{SEAT_NAMES[seat]}: {error}"
            log("illegal", board, seat, uci=uci)
            return finish(not team, "illegal move")
        if sitting[board]:
            result.sit_ms[team] += now - sit_since[board]
            sitting[board] = False
        moves_made[seat] += 1
        log("move", board, seat, uci=uci, advantage=advantage)

        next_seat = to_move(board)
        pending[board] = now + costs.sample(next_seat, moves_made[next_seat])
        other = 1 - board
        if sitting[other]:
            wake = now + config.react_cost_ms
            if pending[other] is None or wake < pending[other]:
                pending[other] = wake

        done = terminal(seat_team(board, game.turn(board)))
        if done:
            return done
