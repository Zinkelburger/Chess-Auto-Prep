"""Match statistics, ported from Hivemind's engine/src/tools/tournament.cc so
arena and in-engine tournament numbers mean the same thing.

Games come in opening pairs (same opening and think costs, teams swapped), and
the pair is the unit of evidence: pair scores cancel most of the opening's
bias, which is why the confidence interval and SPRT both run on pairs.
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


def summarize(games: list[dict], sprt: tuple[float, float, float, float] | None = None) -> dict:
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
    }
    if sprt:
        elo0, elo1, alpha, beta = sprt
        state = paired_sprt(pair_scores, elo0, elo1, alpha, beta)
        summary["sprt"] = {"elo0": elo0, "elo1": elo1, "alpha": alpha, "beta": beta,
                           "llr": state.llr, "lower": state.lower, "upper": state.upper,
                           "decision": state.decision}
    return summary
