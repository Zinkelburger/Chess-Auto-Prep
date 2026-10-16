"""How well an evaluation predicts held-out game outcomes.

The gate for a trained net, and the baseline it has to beat: the same
positions, the same question -- which team won? -- asked of the hand-written
eval, the crazyhouse NNUE, and the new net.  Two numbers:

* sign accuracy -- did the eval's sign pick the winner (AlphaGo's "value
  accuracy sign", drawn games left out);
* log loss -- of `sigmoid(score / scale)` against the result, with `scale`
  fitted on the same positions so an eval in odd units is not punished for
  its units.  Chance is ln 2 = 0.693.

Positions come from the validation files, which `extract` held out by game
number, so no eval was trained on them.
"""

from __future__ import annotations

import json
import math
import multiprocessing as mp
import os
import random
import time
from pathlib import Path

from . import records
from .engine import Engine
from .paths import VARIANT, nets_dir, plain_dir
from .toolchain import require_binary

SEED = 7


def _probe_batch(args) -> list[tuple[int, int]]:
    binary, variant, options, depth, batch = args
    global _engine
    try:
        engine = _engine
    except NameError:
        engine = _engine = Engine(binary, variant, options)
    out = []
    for text in batch:
        rec = records.parse(text)
        score, _ = engine.search(rec["fen"], depth)
        out.append((score, int(rec["result"])))
    return out


def sample_positions(years: list[int] | None, n: int, rng: random.Random) -> list[str]:
    files = sorted(plain_dir().glob("????.val.plain"))
    if years:
        files = [f for f in files if int(f.name[:4]) in years]
    if not files:
        raise SystemExit(f"no validation files in {plain_dir()}; run `extract` first")
    pool: list[str] = []
    for path in files:
        pool.extend(records.iter_records(path))
    return rng.sample(pool, min(n, len(pool)))


def fit_scale(pairs: list[tuple[int, int]]) -> tuple[float, float]:
    """(scale, log loss) minimising log loss of sigmoid(score/scale) vs result."""
    decisive = [(s, r) for s, r in pairs if r != 0]
    best = (float("inf"), 1.0)
    scale = 25.0
    while scale <= 40_000:
        loss = 0.0
        for s, r in decisive:
            p = 1 / (1 + math.exp(-s / scale))
            p = min(max(p, 1e-6), 1 - 1e-6)
            loss -= math.log(p if r > 0 else 1 - p)
        loss /= max(1, len(decisive))
        if loss < best[0]:
            best = (loss, scale)
        scale *= 1.15
    return best[1], best[0]


def summarise(pairs: list[tuple[int, int]]) -> dict[str, float | int]:
    decisive = [(s, r) for s, r in pairs if r != 0]
    right = sum(1 for s, r in decisive if s != 0 and (s > 0) == (r > 0))
    scale, loss = fit_scale(pairs)
    return {
        "positions": len(pairs),
        "decisive": len(decisive),
        "sign_accuracy": round(right / max(1, len(decisive)), 4),
        "scale": round(scale, 1),
        "log_loss": round(loss, 4),
        "chance_log_loss": round(math.log(2), 4),
    }


def evaluate(net: Path | None, n: int, depth: int, years: list[int] | None, jobs: int,
             variant: str | None) -> int:
    binary = require_binary()
    rng = random.Random(SEED)
    positions = sample_positions(years, n, rng)
    jobs = max(1, min(jobs or os.cpu_count() or 1, len(positions)))
    if net is not None:
        options = {"Use NNUE": "pure", "EvalFile": str(net.resolve())}
        label = net.name
    else:
        options = {"Use NNUE": "false"}
        label = "hand-written eval"
    variant = variant or VARIANT
    print(f"{label} ({variant}, depth {depth}) on {len(positions)} held-out positions, {jobs} engine(s)")
    started = time.time()
    batch = max(1, len(positions) // (jobs * 4))
    tasks = [
        (binary, variant, options, depth, positions[i:i + batch])
        for i in range(0, len(positions), batch)
    ]
    pairs: list[tuple[int, int]] = []
    pool = mp.Pool(jobs)
    try:
        for part in pool.imap_unordered(_probe_batch, tasks):
            pairs.extend(part)
    except RuntimeError as e:
        pool.terminate()
        raise SystemExit(f"{label}: {e}") from None
    finally:
        pool.terminate()
        pool.join()
    result = summarise(pairs)
    result.update({"eval": label, "variant": variant, "depth": depth,
                   "years": years, "seconds": round(time.time() - started, 1)})
    print(json.dumps(result, indent=2))
    nets_dir().mkdir(parents=True, exist_ok=True)
    with open(nets_dir() / "evaluations.jsonl", "a") as log:
        log.write(json.dumps(result) + "\n")
    return 0
