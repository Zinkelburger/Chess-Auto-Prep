"""Match statistics, ported from Hivemind's engine/src/tools/tournament.cc so
arena and in-engine tournament numbers mean the same thing.

Games come in opening pairs (same opening and think costs, teams swapped), and
the pair is the unit of evidence: pair scores cancel most of the opening's
bias, which is why the confidence interval and SPRT both run on pairs.

The ported SPRT scores each pair by its total points, not by the pentanomial
distribution of pair outcomes, so its error rates are not what its parameters
say. Fixed-sample runs (``--fixed-sample``) do not stop on it; they report the
``fixed_sample`` block built by :func:`pair_interval`, a Wilson score interval
on the mean pair score whose effective sample size comes from the pentanomial
dispersion (see that function for why).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

Z95 = 1.959963984540054


def score_to_elo(score: float) -> float | None:
    if not 0.0 < score < 1.0:
        return None
    return 400.0 * math.log10(score / (1.0 - score))


def expected_score(elo: float) -> float:
    return 1.0 / (1.0 + 10.0 ** (-elo / 400.0))


def score_interval(pair_scores: list[float], wins: int, losses: int,
                   draws: int) -> tuple[float, float] | None:
    """Paired normal approximation, or Wilson on games with under two pairs."""
    games = wins + losses + draws
    if games == 0:
        return None
    if len(pair_scores) >= 2:
        count = len(pair_scores)
        mean = sum(pair_scores) / count
        variance = sum((s - mean) ** 2 for s in pair_scores) / (count - 1)
        margin = Z95 * math.sqrt(variance / count)
        return max(0.0, mean - margin), min(1.0, mean + margin)
    score = (wins + 0.5 * draws) / games
    denominator = 1.0 + Z95 * Z95 / games
    center = (score + Z95 * Z95 / (2.0 * games)) / denominator
    margin = Z95 * math.sqrt(
        score * (1.0 - score) / games + Z95 * Z95 / (4.0 * games * games)) / denominator
    return max(0.0, center - margin), min(1.0, center + margin)


PENTANOMIAL_LABELS = ("0-2", "0.5-1.5", "1-1", "1.5-0.5", "2-0")
PSEUDOCOUNT = 0.5


def pair_interval(pair_scores: list[float], z: float = Z95,
                  pseudocount: float = PSEUDOCOUNT) -> tuple[float, float] | None:
    """A 95% interval for the expected pair score, with pairs as the unit.

    Each pair score is one of 0, 1/4, 1/2, 3/4, 1. A variable on [0, 1] with
    mean p has variance phi * p(1-p) for some dispersion 0 < phi <= 1 (phi = 1
    only when every pair is 0 or 1). The interval is the Wilson score interval
    for the observed mean with effective sample size n / phi, the design-effect
    form of Wilson. phi is estimated from the pentanomial after adding
    ``pseudocount`` (Jeffreys-style 1/2) to each of the five outcomes; the
    pseudocounts enter only the dispersion, never the point estimate, so the
    interval always contains the observed mean.

    Why this rather than the paired normal approximation: that one has zero
    width whenever all pair scores are equal (every pair 2-0, or every pair
    1-1), claiming certainty from a handful of pairs. Here an all-winning
    sample gives [L, 1] with L < 1, an all-losing one [0, U] with U > 0, and
    identical pair scores give a nonzero width that shrinks as pairs accumulate.
    A percentile bootstrap was rejected because, like the normal
    approximation, it collapses to a point on identical samples unless it is
    regularized, and it is not deterministic.
    """
    count = len(pair_scores)
    if count == 0:
        return None
    mean = sum(pair_scores) / count
    weights = [pseudocount] * 5
    for score in pair_scores:
        weights[int(round(4 * score))] += 1
    total = sum(weights)
    values = [k / 4 for k in range(5)]
    smoothed = sum(w * v for w, v in zip(weights, values)) / total
    variance = sum(w * (v - smoothed) ** 2 for w, v in zip(weights, values)) / total
    phi = variance / (smoothed * (1.0 - smoothed))
    effective = count / phi
    z2 = z * z
    denominator = 1.0 + z2 / effective
    center = (mean + z2 / (2.0 * effective)) / denominator
    half = z * math.sqrt(mean * (1.0 - mean) / effective
                         + z2 / (4.0 * effective * effective)) / denominator
    # The score interval contains the observed mean exactly; clamping to it
    # also keeps rounding from turning a 100% sample's upper bound into 0.99..9.
    return min(mean, max(0.0, center - half)), max(mean, min(1.0, center + half))


def elo_bounds(interval: tuple[float, float] | None) -> list[float | None] | None:
    """Elo for each end of a score interval; None where it is unbounded (0 or 1)."""
    if interval is None:
        return None
    return [score_to_elo(interval[0]), score_to_elo(interval[1])]


def percentile(values: list[float], fraction: float) -> float | None:
    """Nearest-rank percentile."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[rank - 1]


def latency_summary(latencies_ms: list[float]) -> dict:
    if not latencies_ms:
        return {"count": 0, "mean_ms": None, "median_ms": None, "p95_ms": None,
                "max_ms": None, "total_ms": 0.0}
    ordered = sorted(latencies_ms)
    middle = len(ordered) // 2
    median = (ordered[middle] if len(ordered) % 2
              else (ordered[middle - 1] + ordered[middle]) / 2.0)
    return {"count": len(ordered), "mean_ms": sum(ordered) / len(ordered),
            "median_ms": median, "p95_ms": percentile(ordered, 0.95),
            "max_ms": ordered[-1], "total_ms": sum(ordered)}


def contender_seats(contender_team: str) -> tuple[str, str]:
    return ("A-white", "B-black") if contender_team == "white" else ("A-black", "B-white")


def engine_behaviour(games: list[dict]) -> dict:
    """Per side: searches, nodes, search latency, passes and wake requests."""
    out = {}
    for role in ("contender", "baseline"):
        totals = {"searches": 0, "nodes": 0, "passes": 0, "mandatory_sits": 0,
                  "wake_requests": 0, "null_outputs": 0}
        latencies: list[float] = []
        for g in games:
            mine = contender_seats(g["contender_team"])
            for seat, stats in (g.get("seat_stats") or {}).items():
                if (seat in mine) != (role == "contender"):
                    continue
                for key in totals:
                    totals[key] += stats.get(key, 0)
                latencies.extend(stats.get("latency_ms", []))
        out[role] = {**totals, "latency": latency_summary(latencies)}
    return out


def fixed_sample(counted: list[dict], games: list[dict], pair_scores: list[float],
                 pentanomial: list[int], wins: int, losses: int, draws: int,
                 declared_pairs: int | None, replayed_errors: int) -> dict:
    played = wins + losses + draws
    score = (wins + 0.5 * draws) / played if played else None
    interval = pair_interval(pair_scores)
    pairs_seen: dict[int, int] = {}
    for g in counted:
        pairs_seen[g["pair"]] = pairs_seen.get(g["pair"], 0) + 1
    errors = sum(1 for g in games if g["result"]["termination"] == "error")
    illegal = sum(1 for g in games if g["result"]["termination"] == "illegal move")
    return {
        "declared_pairs": declared_pairs,
        "complete_pairs": len(pair_scores),
        "incomplete_pairs": sorted(p for p, n in pairs_seen.items() if n != 2),
        "sample_complete": declared_pairs is not None and len(pair_scores) == declared_pairs,
        "wins": wins, "draws": draws, "losses": losses,
        "score": score,
        "pair_score_mean": sum(pair_scores) / len(pair_scores) if pair_scores else None,
        "pentanomial": dict(zip(PENTANOMIAL_LABELS, pentanomial)),
        "score_interval_95": list(interval) if interval else None,
        "interval_method": ("Wilson score interval on the mean pair score, effective n = "
                            "pairs / dispersion from the pentanomial with 0.5 pseudocounts"),
        # No finite Elo at 0% or 100%: score_to_elo returns None there.
        "elo": score_to_elo(score) if score is not None else None,
        "elo_interval_95": elo_bounds(interval),
        "reliability": {"errors": errors, "illegal_moves": illegal,
                        "replayed_errors": replayed_errors,
                        "ok": errors == 0 and illegal == 0 and replayed_errors == 0},
    }


@dataclass
class Sprt:
    llr: float
    lower: float
    upper: float
    decision: str  # "continue", "accept_h0" or "accept_h1"


def paired_sprt(pair_scores: list[float], elo0: float, elo1: float,
                alpha: float = 0.05, beta: float = 0.05) -> Sprt:
    """Port of ``evaluate_paired_sprt``."""
    if not elo1 > elo0 or not 0 < alpha < 1 or not 0 < beta < 1:
        raise ValueError("invalid SPRT parameters")
    p0, p1 = expected_score(elo0), expected_score(elo1)
    lower = math.log(beta / (1.0 - alpha))
    upper = math.log((1.0 - beta) / alpha)
    llr = 0.0
    for pair_score in pair_scores:
        points = 2.0 * pair_score
        llr += points * math.log(p1 / p0) + (2.0 - points) * math.log((1.0 - p1) / (1.0 - p0))
    decision = "accept_h0" if llr <= lower else "accept_h1" if llr >= upper else "continue"
    return Sprt(llr, lower, upper, decision)


def summarize(games: list[dict], sprt: tuple[float, float, float, float] | None = None,
              declared_pairs: int | None = None, replayed_errors: int = 0) -> dict:
    """Aggregate finished game records (see match.py) from the contender's side."""
    counted = [g for g in games if g["result"]["termination"] != "error"]
    wins = sum(1 for g in counted if g["contender_score"] == 1.0)
    losses = sum(1 for g in counted if g["contender_score"] == 0.0)
    draws = len(counted) - wins - losses

    by_pair: dict[int, list[float]] = {}
    for g in counted:
        by_pair.setdefault(g["pair"], []).append(g["contender_score"])
    complete = {pair: scores for pair, scores in by_pair.items() if len(scores) == 2}
    pair_scores = [sum(scores) / 2.0 for _, scores in sorted(complete.items())]
    pentanomial = [0] * 5
    for scores in complete.values():
        pentanomial[int(round(2 * sum(scores)))] += 1

    games_played = len(counted)
    score = (wins + 0.5 * draws) / games_played if games_played else None
    interval = score_interval(pair_scores, wins, losses, draws)
    elo_interval = None
    if interval:
        low, high = score_to_elo(interval[0]), score_to_elo(interval[1])
        if low is not None and high is not None:
            elo_interval = [low, high]

    terminations: dict[str, int] = {}
    for g in games:
        name = g["result"]["termination"]
        terminations[name] = terminations.get(name, 0) + 1

    def side(team: str) -> dict:
        subset = [g for g in counted if g["contender_team"] == team]
        return {"wins": sum(1 for g in subset if g["contender_score"] == 1.0),
                "losses": sum(1 for g in subset if g["contender_score"] == 0.0),
                "draws": sum(1 for g in subset if g["contender_score"] == 0.5)}

    def team_totals(key: str, role: str) -> int:
        total = 0
        for g in counted:
            team = g["contender_team"] if role == "contender" else (
                "black" if g["contender_team"] == "white" else "white")
            total += g["result"][key][team]
        return total

    behaviour = {}
    for role in ("contender", "baseline"):
        decisions = team_totals("decisions", role)
        behaviour[role] = {
            "decisions": decisions,
            "sits": team_totals("sits", role),
            "sit_seconds_per_game": (team_totals("sit_ms", role) / 1000.0 / games_played
                                     if games_played else 0.0),
            "time_advantage_share": (team_totals("advantage_decisions", role) / decisions
                                     if decisions else 0.0),
            "timer_wakes": sum(g["result"].get("timer_wakes", {}).get(
                g["contender_team"] if role == "contender" else
                ("black" if g["contender_team"] == "white" else "white"), 0) for g in counted),
        }

    summary = {
        "games": len(games),
        "counted_games": games_played,
        "complete_pairs": len(pair_scores),
        "contender_wins": wins,
        "contender_losses": losses,
        "draws": draws,
        "contender_score": score,
        "contender_elo": score_to_elo(score) if score is not None else None,
        "score_confidence_95": list(interval) if interval else None,
        "elo_confidence_95": elo_interval,
        "confidence_method": ("paired-opening normal approximation"
                              if len(pair_scores) >= 2 else "game-level Wilson approximation"),
        "pentanomial": pentanomial,
        "contender_as": {"white": side("white"), "black": side("black")},
        "terminations": terminations,
        "mean_virtual_seconds": (sum(g["result"]["duration_ms"] for g in counted)
                                 / 1000.0 / games_played if games_played else None),
        "behaviour": behaviour,
        "engines": engine_behaviour(games),
        "fixed_sample": fixed_sample(counted, games, pair_scores, pentanomial, wins,
                                     losses, draws, declared_pairs, replayed_errors),
    }
    if sprt:
        elo0, elo1, alpha, beta = sprt
        state = paired_sprt(pair_scores, elo0, elo1, alpha, beta)
        summary["sprt"] = {"elo0": elo0, "elo1": elo1, "alpha": alpha, "beta": beta,
                           "llr": state.llr, "lower": state.lower, "upper": state.upper,
                           "decision": state.decision}
    return summary
