"""Turning Hivemind's raw score into a number a reader can act on.

Hivemind reports ``180·tan(1.56·Q)`` of an MCTS value, and that value is not
an evaluation of the position alone. It carries a large offset that the network
reads mostly off its ``TimeAdvantage`` input: the bit alone is worth about
±0.58 of Q, more than a queen, so a *balanced* position reads about −0.58 from
both seats when neither team may sit.

The offset is **not a constant**. It is the network's estimate of what the
clock advantage is worth *in this position*, so it is large in a piece-rich
opening and small in a bare endgame. Measured across exactly symmetric
two-board positions — identical FEN on both boards, so the true value is 0 by
symmetry — it ranged from −0.31 to −0.67 of Q:

    position (all dead equal)      raw score    offset (Q)
    the opening                       −2.29        −0.575
    a symmetric Italian               −3.07        −0.672
    a mirrored king-and-pawn end      −0.93        −0.337

Subtracting one fixed number therefore reported the drawn ending as more than
a pawn up. So it is measured instead. Writing each team's reported value as
``q = ±advantage + offset``, two searches of the same position give both:

    offset    = (q_ours + q_theirs) / 2
    advantage = (q_ours − q_theirs) / 2

That also handles the asymmetric case for free: when we may sit and they may
not, the two searches genuinely agree (+0.58 / −0.58), the offset comes out at
zero, and the clock advantage stays in the advantage where it belongs.

One more thing the arithmetic has to get right: the shift belongs in Q, not in
the score. The tangent is about two and a half times steeper at the offset than
it is at zero, so taking the offset off the raw score inflates every advantage
— and by a different factor under each clock stance, which made the same
position move when only the stance changed.
"""

from __future__ import annotations

import math

TANGENT_SCALE = 180.0
TANGENT_RATE = 1.56

SIT_BIT_Q = 0.5814
"""What the ``TimeAdvantage`` bit alone is worth to the network, in Q.

Measured: a balanced position reads cp −230 with the option off and +230 with
it on, from either seat, at every node count tried — ``atan(230/180)/1.56``
either way.
"""


def to_q(cp: int | float | None) -> float | None:
    """The MCTS value behind a centipawn score, recovered exactly.

    The tangent inverts without a fitted constant, which is why this is not
    Lichess's ``2/(1+exp(-0.00368·cp))-1``: that curve is *fitted* to Stockfish
    centipawns because Stockfish has no win probability to ask for. Hivemind
    has one.
    """
    return None if cp is None else math.atan(cp / TANGENT_SCALE) / TANGENT_RATE


def to_score(q: float) -> float:
    """Back to the engine's scale, in pawn-like units. Not pawns.

    Clamped before the tangent, which runs away to infinity at ±1 — past about
    ±10 the distinction is "winning" either way, and a mate prints as a mate.
    """
    return TANGENT_SCALE * math.tan(TANGENT_RATE * max(-0.9, min(0.9, q))) / 100.0


def assumed_offset(we_may_sit: bool, they_may_sit: bool) -> float:
    """The offset a level position would give, for use before measuring.

    Each team reads its own bit as ±[SIT_BIT_Q], and the offset is the average
    of the two — so it is −0.58 when neither team may sit and zero when exactly
    one may. A rule derived from the same measurement, not a second constant.
    """
    return (
        (SIT_BIT_Q if we_may_sit else -SIT_BIT_Q)
        + (SIT_BIT_Q if they_may_sit else -SIT_BIT_Q)
    ) / 2


def measure_offset(ours_cp: int | None, theirs_cp: int | None) -> float | None:
    """The offset both searches of one position agree on.

    None when either side is a mate, which carries no usable value.
    """
    ours, theirs = to_q(ours_cp), to_q(theirs_cp)
    if ours is None or theirs is None:
        return None
    return (ours + theirs) / 2


def evaluate(cp: int | None, mate: int | None, offset: float) -> dict:
    """One line read against an offset, from the searched team's seat."""
    if mate is not None:
        return {
            "advantage": None,
            "advantage_score": None,
            "win_percent": 100.0 if mate >= 0 else 0.0,
            "mate": mate,
        }
    q = to_q(cp)
    if q is None:
        return {
            "advantage": None,
            "advantage_score": None,
            "win_percent": None,
            "mate": None,
        }
    advantage = max(-1.0, min(1.0, q - offset))
    return {
        "advantage": round(advantage, 3),
        "advantage_score": round(to_score(advantage), 2),
        "win_percent": round(max(0.0, min(100.0, 50 * (1 + advantage))), 1),
        "mate": None,
    }
