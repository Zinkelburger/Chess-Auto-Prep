"""Does a net play better?  Two evals as opposing teams over whole games.

`evaluate` asks whether an eval predicts who won, which is the training
objective and says nothing about what the eval does inside a search.  The
only gate that answers the question the site asks -- what is the best move
here -- is a match: one team's two searches run eval A, the other team's run
eval B, and the games are counted.  Every opening is played twice with the
teams swapped, so an opening that favours one side cancels out.

Both teams play the same way `selfplay` does: fixed nodes a move, boards in
turn, no sitting, mate ends the game.  Two engine processes per worker, one
per eval, one hash each.

    python3 -m bughouse_nnue match --net-one nets/pocketknight-x.nnue --games 400
    python3 -m bughouse_nnue match --net-one A.nnue --net-two B.nnue

With no `--net-two` the other team is the hand-written eval.  The result is
appended to `nets/matches.jsonl`.
"""

from __future__ import annotations

import json
import math
import multiprocessing as mp
import os
import random
import time
from collections import Counter
from dataclasses import asdict
from pathlib import Path

from . import openings
from .engine import Engine
from .paths import VARIANT, nets_dir
from .selfplay import Settings, eval_options, failed, game_settings, load_openings, play
from .toolchain import require_binary


_engines: tuple[Engine, Engine] | None = None  # per worker process, started on first use


def _play_pair(args) -> tuple[int, list[int], dict]:
    """One opening, two games with the teams swapped.  Scores are for eval one.

    Each game gets its own rng from the same seed, so any random plies are the
    same in both and the swap cancels the opening out.  A pair where either
    game fails counts neither.
    """
    index, seed, binary, settings, nets, opening = args
    global _engines
    scores: list[int] = []
    ends: Counter = Counter()
    try:
        if _engines is None:
            _engines = tuple(Engine(binary, VARIANT, eval_options(net)) for net in nets)
        outcomes = [
            play((_engines[1], _engines[0]) if swap else _engines, settings, random.Random(seed), opening)[1]
            for swap in (False, True)
        ]
    except Exception as error:  # noqa: BLE001 -- one bad pair must not stop the match
        for engine in _engines or ():
            engine.close()
        _engines = None
        ends[failed(error)["termination"]] += 2
        return index, scores, {"termination": ends}
    for swap, outcome in zip((False, True), outcomes):
        ends[outcome["termination"]] += 1
        if outcome["team_one"] is None:
            continue
        scores.append(-outcome["team_one"] if swap else outcome["team_one"])
    return index, scores, {"termination": ends}


def summarise(scores: list[int]) -> dict:
    n = len(scores)
    wins = sum(1 for s in scores if s > 0)
    losses = sum(1 for s in scores if s < 0)
    draws = n - wins - losses
    if n == 0:
        return {"games": 0}
    points = [(s + 1) / 2 for s in scores]
    p = sum(points) / n
    var = sum((x - p) ** 2 for x in points) / max(1, n - 1)
    se = math.sqrt(var / n)

    def elo(q: float) -> float | None:
        q = min(max(q, 1e-6), 1 - 1e-6)
        return round(-400 * math.log10(1 / q - 1), 1)

    return {
        "games": n, "wins": wins, "draws": draws, "losses": losses,
        "score": round(p, 4),
        "elo": elo(p),
        "elo_95": [elo(p - 1.96 * se), elo(p + 1.96 * se)],
        # Likelihood of superiority: P(eval one is stronger) under a normal
        # approximation of the score.
        "los": round(0.5 * (1 + math.erf((p - 0.5) / (se * math.sqrt(2)))) if se > 0 else (1.0 if p > 0.5 else 0.0), 4),
    }


def match(net_one: Path | None, net_two: Path | None, games: int, settings: Settings,
          jobs: int, seed: int | None) -> int:
    binary = require_binary()
    nets = (str(net_one) if net_one else None, str(net_two) if net_two else None)
    names = tuple(Path(n).name if n else "hand-written eval" for n in nets)
    jobs = max(1, jobs or os.cpu_count() or 1)
    seed = seed if seed is not None else int(time.time())
    rng = random.Random(seed)
    pairs = max(1, games // 2)
    starts = load_openings(pairs, settings.opening_plies, rng)
    if not starts and settings.random_plies <= 0:
        settings = Settings(**{**asdict(settings), "random_plies": 8})
    print(
        f"match: {names[0]} vs {names[1]}, {pairs} openings x 2 games, "
        f"{settings.nodes} nodes/move on {jobs} core(s)"
    )
    started = time.time()
    tasks = [
        (i, seed * 1_000_003 + i, binary, game_settings(settings, i, starts), nets,
         starts[i % len(starts)] if starts else None)
        for i in range(pairs)
    ]
    scores: list[int] = []
    ends: Counter = Counter()
    with mp.Pool(jobs) as pool:
        for done, (_, pair_scores, info) in enumerate(pool.imap_unordered(_play_pair, tasks, chunksize=1), 1):
            scores.extend(pair_scores)
            ends.update(info["termination"])
            if done % 25 == 0 or done == pairs:
                s = summarise(scores)
                print(
                    f"  {done}/{pairs} pairs: +{s.get('wins', 0)} ={s.get('draws', 0)} -{s.get('losses', 0)} "
                    f"score {s.get('score', 0):.3f} elo {s.get('elo')} {s.get('elo_95')}", flush=True,
                )
    result = summarise(scores)
    result.update({
        "one": names[0], "two": names[1], "nodes": settings.nodes,
        "opening_plies": settings.opening_plies, "terminations": dict(ends), "seed": seed,
        "seconds": round(time.time() - started, 1),
    })
    print(json.dumps(result, indent=2))
    nets_dir().mkdir(parents=True, exist_ok=True)
    with open(nets_dir() / "matches.jsonl", "a") as log:
        log.write(json.dumps(result) + "\n")
    return 0
