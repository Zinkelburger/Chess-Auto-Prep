"""Add a shallow pocketknight search score to extracted records.

Pure-outcome training (`--lambda 0`) does not need this.  It exists so the
Stockfish-style blend can be compared: the trainer's `--lambda` mixes a
search score in, which carries the tactics of the position without the
noise of a whole game's result.  The score is the hand-written eval's
search, so it knows nothing about pieces arriving -- that knowledge still
has to come from the results.

`<year>.plain` becomes `<year>.scored.plain`, the same records with the score
line filled in.  One engine per core; a year of a few million records takes
on the order of an hour at depth 4.
"""

from __future__ import annotations

import multiprocessing as mp
import os
import time
from pathlib import Path

from . import records
from .engine import Engine
from .paths import VARIANT, plain_dir
from .toolchain import require_binary

BATCH = 2000


def _score_batch(args) -> list[str]:
    binary, depth, batch = args
    global _engine  # one engine per worker process, started on first use
    try:
        engine = _engine
    except NameError:
        engine = _engine = Engine(binary, VARIANT, {"Use NNUE": "false"})
    out = []
    for text in batch:
        fen = records.parse(text)["fen"]
        score, _ = engine.search(fen, depth)
        out.append(records.with_score(text, score))
    return out


def _batches(path: Path):
    batch: list[str] = []
    for text in records.iter_records(path):
        batch.append(text)
        if len(batch) >= BATCH:
            yield batch
            batch = []
    if batch:
        yield batch


def score_file(binary: Path, source: Path, target: Path, depth: int, jobs: int) -> int:
    started = time.time()
    n = 0
    partial = target.with_suffix(".part")
    pool = mp.Pool(jobs)
    try:
        with open(partial, "w") as out:
            tasks = ((binary, depth, batch) for batch in _batches(source))
            for scored in pool.imap(_score_batch, tasks):
                out.write("".join(scored))
                n += len(scored)
                if n % (BATCH * 50) == 0:
                    rate = n / (time.time() - started)
                    print(f"  {source.name}: {n} scored, {rate:.0f}/s", flush=True)
    except RuntimeError as e:
        raise SystemExit(f"{source.name}: {e}") from None
    finally:
        pool.terminate()
        pool.join()
    partial.replace(target)
    print(f"  {source.name}: {n} records in {time.time() - started:.0f}s -> {target.name}")
    return n


def unscored() -> list[Path]:
    out = []
    for path in sorted(plain_dir().glob("*.plain")):
        if ".scored" in path.name:
            continue
        if not path.with_name(path.name[:-len(".plain")] + ".scored.plain").exists():
            out.append(path)
    return out


def score_files(files: list[Path], depth: int, jobs: int) -> int:
    binary = require_binary()
    files = files or unscored()
    if not files:
        print("nothing to score")
        return 0
    jobs = jobs or os.cpu_count() or 1
    print(f"scoring {len(files)} file(s) at depth {depth} on {jobs} engine(s)")
    total = 0
    for source in files:
        target = source.with_name(source.name[:-len(".plain")] + ".scored.plain")
        total += score_file(binary, source, target, depth, jobs)
    print(f"{total} records scored")
    return 0
