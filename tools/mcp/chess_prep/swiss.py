"""A USCF-approximate Swiss pairing engine and a Monte Carlo event simulator.

Pure Python: no engine, no network, no app. Deterministic given a seed, so
tests can assert exact pairings and the simulator is reproducible.

## Fidelity, and why approximate is the right target

The pairer implements the load-bearing parts of USCF Chapter 29: score
groups, the top-half/bottom-half cross-pairing that makes round 1 nearly
deterministic, no-repeat pairings, color equalization and alternation,
pair-downs from odd score groups, and the odd-field bye.

It deliberately does *not* implement the full transposition and interchange
limits (the 80-point and 200-point rules), rating-floor special cases, or TD
discretion. Those matter for a defensible official wall chart; they do not
measurably move a *probability distribution* over opponents, because the
uncertainty in who actually wins each game dominates them by a wide margin.

Where a constraint genuinely cannot be satisfied, the pairing is emitted with
``forced=True`` rather than silently violated or dropped.

## Why sampling rather than prediction

Predicting a specific pairing sheet is not achievable: withdrawals, late
entries, family/club withholds, half-point byes and TD discretion all move
it, and none are knowable in advance. But prep does not need the sheet — it
needs P(face this person), which is stable under exactly that noise. Running
the whole event thousands of times and counting opponents gives that
directly, and every source of mess above enters as a parameter rather than as
an unmodelled error.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Iterable, Sequence

from .roster import Roster, RosterEntry

# ── Pairing model ───────────────────────────────────────────────────────────

WHITE = "white"
BLACK = "black"


@dataclass(frozen=True)
class Pairing:
    board: int
    white_id: str
    black_id: str
    #: True when no legal pairing existed and a constraint had to be violated.
    forced: bool = False

    def involves(self, player_id: str) -> bool:
        return player_id in (self.white_id, self.black_id)

    def opponent_of(self, player_id: str) -> str | None:
        if player_id == self.white_id:
            return self.black_id
        if player_id == self.black_id:
            return self.white_id
        return None

    def color_of(self, player_id: str) -> str | None:
        if player_id == self.white_id:
            return WHITE
        if player_id == self.black_id:
            return BLACK
        return None


@dataclass(frozen=True)
class ByeAssignment:
    player_id: str
    points: float
    #: A requested half-point bye, as opposed to the odd-field full point.
    requested: bool


@dataclass
class RoundPairings:
    round: int
    pairings: list[Pairing] = field(default_factory=list)
    byes: list[ByeAssignment] = field(default_factory=list)

    def for_player(self, player_id: str) -> Pairing | None:
        for p in self.pairings:
            if p.involves(player_id):
                return p
        return None

    def has_bye(self, player_id: str) -> bool:
        return any(b.player_id == player_id for b in self.byes)

    @property
    def forced_count(self) -> int:
        return sum(1 for p in self.pairings if p.forced)


@dataclass(frozen=True)
class SwissSeed:
    id: str
    rating: int
    half_point_bye_rounds: frozenset[int] = frozenset()
    initial_score: float = 0.0


@dataclass(frozen=True)
class SwissStanding:
    player_id: str
    score: float
    rating: int
    color_balance: int


@dataclass(frozen=True)
class PairingConstraint:
    """Two entrants who must never be paired (family, club-mates, TD order)."""

    a: str
    b: str
    reason: str | None = None

    def involves(self, x: str, y: str) -> bool:
        return (self.a == x and self.b == y) or (self.a == y and self.b == x)


@dataclass(frozen=True)
class SwissRules:
    rounds: int = 5
    #: Accelerated pairings: the initial top half carries a virtual point for
    #: the first ``accelerated_rounds`` rounds. Announced by the organizer;
    #: never auto-detected.
    accelerated: bool = False
    accelerated_rounds: int = 2
    constraints: tuple[PairingConstraint, ...] = ()


class _PlayerState:
    __slots__ = (
        "id",
        "rating",
        "initial_seed",
        "half_point_bye_rounds",
        "score",
        "opponents",
        "color_balance",
        "last_color",
        "had_full_point_bye",
    )

    def __init__(
        self,
        id: str,
        rating: int,
        initial_seed: int,
        half_point_bye_rounds: frozenset[int],
        score: float,
    ) -> None:
        self.id = id
        self.rating = rating
        self.initial_seed = initial_seed
        self.half_point_bye_rounds = half_point_bye_rounds
        self.score = score
        self.opponents: set[str] = set()
        self.color_balance = 0  # whites − blacks
        self.last_color: str | None = None
        self.had_full_point_bye = False


# Among the first N legal candidates prefer one whose color preference opposes
# ours; beyond that the rating distortion outweighs the color benefit — the
# same trade-off the rulebook's transposition limits encode.
_COLOR_SEARCH_WINDOW = 4


class SwissPairer:
    """Pairs one event round by round. Deterministic given its inputs."""

    def __init__(self, seeds: Iterable[SwissSeed], rules: SwissRules = SwissRules()):
        self.rules = rules
        self._players: list[_PlayerState] = []
        self._by_id: dict[str, _PlayerState] = {}
        self._rounds_paired = 0

        # Seed order defines the initial rating list, which accelerated
        # pairings and round-1 colors both key off. Ties break by id so the
        # order is total and every simulator trial agrees.
        ordered = sorted(seeds, key=lambda s: (-s.rating, s.id))
        for i, s in enumerate(ordered):
            state = _PlayerState(
                id=s.id,
                rating=s.rating,
                initial_seed=i,
                half_point_bye_rounds=frozenset(s.half_point_bye_rounds),
                score=s.initial_score,
            )
            self._players.append(state)
            self._by_id[s.id] = state

    @property
    def rounds_paired(self) -> int:
        return self._rounds_paired

    @property
    def player_count(self) -> int:
        return len(self._players)

    def score_of(self, player_id: str) -> float:
        p = self._by_id.get(player_id)
        return p.score if p else 0.0

    def standings(self) -> list[SwissStanding]:
        ordered = sorted(self._players, key=lambda p: (-p.score, -p.rating, p.id))
        return [
            SwissStanding(p.id, p.score, p.rating, p.color_balance) for p in ordered
        ]

    # ── Round pairing ──────────────────────────────────────────────────────

    def next_round(self) -> RoundPairings:
        rnd = self._rounds_paired + 1

        byes: list[ByeAssignment] = []
        pool: list[_PlayerState] = []
        for p in self._players:
            if rnd in p.half_point_bye_rounds:
                byes.append(ByeAssignment(p.id, 0.5, requested=True))
            else:
                pool.append(p)

        # Odd field → one full-point bye, to the lowest-rated player in the
        # lowest score group who has not already had one.
        if len(pool) % 2 == 1:
            candidate = self._select_bye_player(pool)
            if candidate is not None:
                pool.remove(candidate)
                candidate.had_full_point_bye = True
                byes.append(ByeAssignment(candidate.id, 1.0, requested=False))

        pairings = self._pair_pool(pool, rnd)
        self._rounds_paired = rnd
        return RoundPairings(round=rnd, pairings=pairings, byes=byes)

    def record_results(
        self, sheet: RoundPairings, white_scores: dict[str, float]
    ) -> None:
        """Apply a round's results. ``white_scores`` maps each board's white
        player id to the points White scored (1.0 / 0.5 / 0.0); byes in
        ``sheet`` are applied automatically."""
        for p in sheet.pairings:
            white = self._by_id.get(p.white_id)
            black = self._by_id.get(p.black_id)
            if white is None or black is None:
                continue
            ws = white_scores.get(p.white_id, 0.5)
            white.score += ws
            black.score += 1.0 - ws
            white.opponents.add(black.id)
            black.opponents.add(white.id)
            white.color_balance += 1
            black.color_balance -= 1
            white.last_color = WHITE
            black.last_color = BLACK

        for b in sheet.byes:
            state = self._by_id.get(b.player_id)
            if state is not None:
                state.score += b.points

    # ── Internals ──────────────────────────────────────────────────────────

    def _select_bye_player(self, pool: list[_PlayerState]) -> _PlayerState | None:
        eligible = [p for p in pool if not p.had_full_point_bye] or list(pool)
        if not eligible:
            return None
        # Lowest score first, then lowest rating.
        return min(eligible, key=lambda p: (p.score, p.rating, p.id))

    def _effective_score(self, p: _PlayerState, rnd: int) -> float:
        rules = self.rules
        if not rules.accelerated or rnd > rules.accelerated_rounds:
            return p.score
        top_half = p.initial_seed < (len(self._players) + 1) // 2
        return p.score + (1.0 if top_half else 0.0)

    def _pair_pool(self, pool: list[_PlayerState], rnd: int) -> list[Pairing]:
        if not pool:
            return []

        groups: dict[float, list[_PlayerState]] = {}
        for p in pool:
            groups.setdefault(self._effective_score(p, rnd), []).append(p)

        pairings: list[Pairing] = []
        carried: list[_PlayerState] = []
        board = 1

        for score in sorted(groups, reverse=True):
            group = carried + groups[score]
            carried = []
            _sort_for_pairing(group)

            # An odd group pairs down its lowest-ranked player.
            if len(group) % 2 == 1:
                carried.append(group.pop())

            # Players this group could not pair legally also drop down, which
            # is what a TD does rather than forcing a rematch.
            deferred: list[_PlayerState] = []
            board = self._cross_pair(group, pairings, board, deferred)
            carried.extend(deferred)

        # Out of score groups to drop into: only here do we accept illegal
        # pairings, and they are flagged as forced.
        if len(carried) >= 2:
            _sort_for_pairing(carried)
            board = self._force_pair(carried, pairings, board)

        return pairings

    def _force_pair(
        self, rest: list[_PlayerState], out: list[Pairing], start_board: int
    ) -> int:
        board = start_board
        for i in range(0, len(rest) - 1, 2):
            a, b = rest[i], rest[i + 1]
            white, black = self._assign_colors(a, b, board)
            out.append(
                Pairing(board, white.id, black.id, forced=not self._is_legal(a, b))
            )
            board += 1
        return board

    def _cross_pair(
        self,
        group: list[_PlayerState],
        out: list[Pairing],
        start_board: int,
        deferred: list[_PlayerState],
    ) -> int:
        """Split ``group`` in half and pair each top-half player against the
        rating-appropriate bottom-half player, transposing when that pairing
        is illegal. Candidates are removed from the pool as they are used so a
        transposition can never disturb a board already emitted."""
        board = start_board
        if len(group) < 2:
            deferred.extend(group)
            return board

        half = len(group) // 2
        top = group[:half]
        bottom = group[half:]

        for a in top:
            idx = self._find_partner(a, bottom)
            if idx is None:
                deferred.append(a)
                continue
            b = bottom.pop(idx)
            white, black = self._assign_colors(a, b, board)
            out.append(Pairing(board, white.id, black.id))
            board += 1

        deferred.extend(bottom)
        return board

    def _find_partner(self, a: _PlayerState, bottom: list[_PlayerState]) -> int | None:
        fallback: int | None = None
        examined = 0
        for j, b in enumerate(bottom):
            if not self._is_legal(a, b):
                continue
            if fallback is None:
                fallback = j
            if _colors_compatible(a, b):
                return j
            examined += 1
            if examined >= _COLOR_SEARCH_WINDOW:
                break
        return fallback

    def _is_legal(self, a: _PlayerState, b: _PlayerState) -> bool:
        if a.id == b.id or b.id in a.opponents:
            return False
        return not any(c.involves(a.id, b.id) for c in self.rules.constraints)

    @staticmethod
    def _assign_colors(
        a: _PlayerState, b: _PlayerState, board: int
    ) -> tuple[_PlayerState, _PlayerState]:
        """Equalize imbalance first, then alternate, then fall back to
        alternating down the boards (the round-1 convention)."""
        if a.color_balance != b.color_balance:
            # The player who has had more Blacks is due White.
            return (a, b) if a.color_balance < b.color_balance else (b, a)
        if a.last_color != b.last_color:
            if a.last_color == BLACK:
                return (a, b)
            if b.last_color == BLACK:
                return (b, a)
        return (a, b) if board % 2 == 1 else (b, a)


def _sort_for_pairing(group: list[_PlayerState]) -> None:
    group.sort(key=lambda p: (-p.score, -p.rating, p.id))


def _color_preference(p: _PlayerState) -> int:
    """+1 = due White, −1 = due Black, 0 = no preference. Equalization
    outranks alternation, matching USCF 29E."""
    if p.color_balance < 0:
        return 1
    if p.color_balance > 0:
        return -1
    if p.last_color == BLACK:
        return 1
    if p.last_color == WHITE:
        return -1
    return 0


def _colors_compatible(a: _PlayerState, b: _PlayerState) -> bool:
    pa, pb = _color_preference(a), _color_preference(b)
    return pa == 0 or pb == 0 or pa != pb


# ── Simulation ──────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class SimulationConfig:
    #: 2000 puts the standard error on a mid-range probability near one
    #: percentage point, well inside what the rating model can claim.
    trials: int = 2000
    seed: int = 20260806
    #: Draw rate between equally-rated players; scaled down as the gap widens.
    draw_rate: float = 0.30
    #: Rating for unrated entrants. Field median when None.
    unrated_rating: int | None = None


@dataclass
class OpponentProbability:
    player_id: str
    prob_any: float
    prob_as_white: float
    prob_as_black: float
    prob_by_round: list[float]

    @property
    def most_likely_round(self) -> int | None:
        if not self.prob_by_round or max(self.prob_by_round) <= 0:
            return None
        return self.prob_by_round.index(max(self.prob_by_round)) + 1

    def to_dict(self) -> dict:
        return {
            "player_id": self.player_id,
            "prob_any": round(self.prob_any, 4),
            "prob_as_white": round(self.prob_as_white, 4),
            "prob_as_black": round(self.prob_as_black, 4),
            "prob_by_round": [round(p, 4) for p in self.prob_by_round],
            "most_likely_round": self.most_likely_round,
        }


@dataclass
class SimulationResult:
    opponents: list[OpponentProbability]
    trials: int
    rounds: int
    expected_score: float
    bye_prob: float
    mean_forced_pairings: float = 0.0
    notes: list[str] = field(default_factory=list)

    def top_by_coverage(self, coverage: float) -> list[OpponentProbability]:
        """Smallest prefix of the ranked opponents carrying ``coverage`` of the
        total pairing mass."""
        total = sum(o.prob_any for o in self.opponents)
        if total <= 0:
            return []
        target = total * coverage
        out: list[OpponentProbability] = []
        acc = 0.0
        for o in self.opponents:
            out.append(o)
            acc += o.prob_any
            if acc >= target:
                break
        return out

    def to_dict(self) -> dict:
        return {
            "trials": self.trials,
            "rounds": self.rounds,
            "expected_score": round(self.expected_score, 3),
            "bye_prob": round(self.bye_prob, 4),
            "mean_forced_pairings": round(self.mean_forced_pairings, 3),
            "notes": list(self.notes),
            "opponents": [o.to_dict() for o in self.opponents],
        }


def _sample_result(
    white_rating: int, black_rating: int, base_draw_rate: float, rng: random.Random
) -> float:
    """One game result from White's perspective. Elo gives the expectation;
    the draw rate is scaled by closeness, and win/loss split the remainder so
    the mean still equals the Elo expectation."""
    expected = 1.0 / (1.0 + 10 ** ((black_rating - white_rating) / 400.0))
    closeness = 1.0 - abs(2 * expected - 1)
    p_draw = min(max(base_draw_rate * closeness, 0.0), 1.0)
    p_win = min(max(expected - p_draw / 2, 0.0), 1.0 - p_draw)
    roll = rng.random()
    if roll < p_win:
        return 1.0
    if roll < p_win + p_draw:
        return 0.5
    return 0.0


def _resolve_ratings(
    field_: Sequence[RosterEntry], config: SimulationConfig, notes: list[str]
) -> dict[str, int]:
    rated = sorted(e.rating for e in field_ if e.rating is not None)
    fallback = config.unrated_rating
    if fallback is None:
        fallback = rated[len(rated) // 2] if rated else 1200
    unrated = len(field_) - len(rated)
    if unrated > 0:
        origin = "configured" if config.unrated_rating is not None else "field median"
        notes.append(f"{unrated} unrated entrant(s) seeded at {fallback} ({origin}).")
    return {e.id: (e.rating if e.rating is not None else fallback) for e in field_}


def _active(roster: Roster) -> list[RosterEntry]:
    return [e for e in roster.entries if not e.withdrawn]


def _section_of(roster: Roster, entry: RosterEntry) -> list[RosterEntry]:
    active = _active(roster)
    if not entry.section:
        return active
    return [e for e in active if e.section == entry.section]


def _constraints(roster: Roster) -> tuple[PairingConstraint, ...]:
    out = []
    for c in roster.constraints:
        a, b = str(c.get("a", "")), str(c.get("b", ""))
        if a and b:
            out.append(PairingConstraint(a, b, c.get("reason")))
    return tuple(out)


def simulate(roster: Roster, config: SimulationConfig = SimulationConfig()) -> SimulationResult:
    """Simulate ``roster`` and return per-opponent pairing probabilities for
    the entrant flagged ``is_me``."""
    notes: list[str] = []
    me = roster.me
    if me is None:
        return SimulationResult(
            opponents=[],
            trials=0,
            rounds=0,
            expected_score=0.0,
            bye_prob=0.0,
            notes=[
                "No entrant is marked as you, so there is no reference point "
                "for pairing probabilities. Mark yourself on the roster first."
            ],
        )

    field_ = _section_of(roster, me)
    if len(field_) < 2:
        return SimulationResult(
            opponents=[],
            trials=0,
            rounds=roster.rounds,
            expected_score=0.0,
            bye_prob=0.0,
            notes=[
                f'Section "{me.section or "open"}" has {len(field_)} entrant(s) — '
                "nothing to simulate."
            ],
        )
    sections = roster.sections
    if sections:
        if not me.section:
            # Over-including is the safe direction, but claiming we filtered
            # when we did not would be a lie the user acts on.
            notes.append(
                f"You have no section, but this event has {len(sections)} "
                f"({', '.join(sections)}). Simulating against ALL {len(field_)} "
                "entrants, which will include players you cannot be paired "
                "with. Set your section for accurate pairing probabilities."
            )
        elif len(sections) > 1:
            notes.append(
                f'Simulating section "{me.section}" only '
                f"({len(field_)} of {len(_active(roster))} entrants)."
            )

    ratings = _resolve_ratings(field_, config, notes)
    rounds = roster.rounds
    rules = SwissRules(
        rounds=rounds,
        accelerated=roster.accelerated,
        constraints=_constraints(roster),
    )

    face_count: dict[str, int] = {}
    face_white: dict[str, int] = {}
    face_black: dict[str, int] = {}
    face_by_round: dict[str, list[int]] = {}
    bye_trials = 0
    score_total = 0.0
    forced_total = 0

    rng = random.Random(config.seed)

    for _ in range(config.trials):
        # Sample who actually shows up. You are always present.
        present = [
            e
            for e in field_
            if e.is_me or e.attendance_prob >= 1.0 or rng.random() < e.attendance_prob
        ]
        if len(present) < 2:
            continue

        pairer = SwissPairer(
            (
                SwissSeed(
                    id=e.id,
                    rating=ratings[e.id],
                    half_point_bye_rounds=frozenset(e.half_point_byes),
                )
                for e in present
            ),
            rules,
        )

        faced_this_trial: set[str] = set()
        got_bye = False

        for r in range(1, rounds + 1):
            sheet = pairer.next_round()
            forced_total += sheet.forced_count

            mine = sheet.for_player(me.id)
            if mine is None:
                if sheet.has_bye(me.id):
                    got_bye = True
            else:
                opp = mine.opponent_of(me.id)
                assert opp is not None
                faced_this_trial.add(opp)
                face_by_round.setdefault(opp, [0] * rounds)[r - 1] += 1
                if mine.color_of(me.id) == WHITE:
                    face_white[opp] = face_white.get(opp, 0) + 1
                else:
                    face_black[opp] = face_black.get(opp, 0) + 1

            results = {
                p.white_id: _sample_result(
                    ratings.get(p.white_id, 1200),
                    ratings.get(p.black_id, 1200),
                    config.draw_rate,
                    rng,
                )
                for p in sheet.pairings
            }
            pairer.record_results(sheet, results)

        for opp in faced_this_trial:
            face_count[opp] = face_count.get(opp, 0) + 1
        if got_bye:
            bye_trials += 1
        score_total += pairer.score_of(me.id)

    trials = config.trials
    opponents = [
        OpponentProbability(
            player_id=pid,
            prob_any=count / trials,
            prob_as_white=face_white.get(pid, 0) / trials,
            prob_as_black=face_black.get(pid, 0) / trials,
            prob_by_round=[c / trials for c in face_by_round.get(pid, [0] * rounds)],
        )
        for pid, count in face_count.items()
    ]
    opponents.sort(key=lambda o: (-o.prob_any, o.player_id))

    return SimulationResult(
        opponents=opponents,
        trials=trials,
        rounds=rounds,
        expected_score=score_total / trials if trials else 0.0,
        bye_prob=bye_trials / trials if trials else 0.0,
        mean_forced_pairings=forced_total / trials if trials else 0.0,
        notes=notes,
    )


__all__ = [
    "BLACK",
    "WHITE",
    "ByeAssignment",
    "OpponentProbability",
    "Pairing",
    "PairingConstraint",
    "RoundPairings",
    "SimulationConfig",
    "SimulationResult",
    "SwissPairer",
    "SwissRules",
    "SwissSeed",
    "SwissStanding",
    "simulate",
]
