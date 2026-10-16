"""Interleave the per-year files and pack them to the trainer's `.bin`.

The trainer reads its file front to back (with random skipping), so the
order on disk is the order positions are learnt in.  A year file is in game
order, six records of one board side by side, so the years are interleaved
at random and passed through a shuffle buffer before packing.  The packing
itself is the tools' `convert_bin`, run with the variant set, which is what
decides how the hands are encoded.

`validate_training_data` was removed from the tools, so the check is the one
that matters: the `.bin` holds exactly 72 bytes per record written.
"""

from __future__ import annotations

import json
import random
import time
from pathlib import Path
from typing import Iterable, Iterator

from . import records
from .engine import Engine
from .paths import VARIANT, dataset_dir, plain_dir, toolchain_dir
from .status import RECORD_BYTES
from .toolchain import require_binary

SHUFFLE_BUFFER = 500_000
SEED = 1


def interleave(paths: list[Path], rng: random.Random, buffer: int = SHUFFLE_BUFFER) -> Iterator[str]:
    """Records from all `paths`, years mixed and locally shuffled."""
    streams = [records.iter_records(p) for p in paths]
    held: list[str] = []
    while streams:
        stream = rng.choice(streams)
        try:
            held.append(next(stream))
        except StopIteration:
            streams.remove(stream)
            continue
        if len(held) >= buffer:
            i = rng.randrange(len(held))
            held[i], held[-1] = held[-1], held[i]
            yield held.pop()
    rng.shuffle(held)
    yield from held


def write_merged(paths: list[Path], out: Path, rng: random.Random) -> int:
    n = 0
    with open(out, "w") as handle:
        for text in interleave(paths, rng):
            handle.write(text)
            n += 1
    return n


def pack(engine: Engine, plain: Path, out: Path) -> list[str]:
    out.unlink(missing_ok=True)
    return engine.command(f"convert_bin targetfile {plain} output_file_name {out}")


def _sources(years: list[int] | None, scored: bool,
             source: str | None = None) -> tuple[list[Path], list[Path]]:
    suffix = ".scored.plain" if scored else ".plain"
    train, val = [], []
    if source:
        t, v = plain_dir() / f"{source}{suffix}", plain_dir() / f"{source}.val{suffix}"
        if not t.exists():
            raise SystemExit(f"missing {t}")
        return [t], [v] if _has_records(v) else []
    for stats in sorted(plain_dir().glob("????.stats.json")):
        year = stats.name[:4]
        if years and int(year) not in years:
            continue
        t, v = plain_dir() / f"{year}{suffix}", plain_dir() / f"{year}.val{suffix}"
        if not t.exists():
            raise SystemExit(f"missing {t}" + (" -- run `score` first" if scored else ""))
        train.append(t)
        if _has_records(v):
            val.append(v)
    if not train:
        raise SystemExit(f"nothing extracted in {plain_dir()}; run `extract` first")
    return train, val


def _has_records(path: Path) -> bool:
    """Self-play opens its validation file up front, so an empty one is normal."""
    return path.exists() and path.stat().st_size > 0


def convert(years: list[int] | None, name: str, scored: bool, source: str | None = None) -> int:
    binary = require_binary()
    train, val = _sources(years, scored, source)
    if not val:
        raise SystemExit(
            "no validation records to pack" + (f" for {source}" if source else "")
            + "; the trainer needs both sets -- play or extract more games"
        )
    out = dataset_dir()
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)
    started = time.time()
    counts = {}
    with Engine(binary, VARIANT) as engine:
        for label, paths in (("train", train), ("val", val)):
            if not paths:
                continue
            merged = out / f"{name}.{label}.plain"
            target = out / (f"{name}.bin" if label == "train" else f"{name}.val.bin")
            print(f"{label}: interleaving {len(paths)} file(s)…", flush=True)
            n = write_merged(paths, merged, rng)
            print(f"{label}: packing {n} records…", flush=True)
            for line in pack(engine, merged, target):
                if line.startswith("convert "):
                    print("  " + line)
            packed = target.stat().st_size // RECORD_BYTES
            if packed != n:
                raise SystemExit(f"{target} holds {packed} records, expected {n}")
            merged.unlink()
            counts[label] = n
    stamp = toolchain_dir() / "toolchain.json"
    manifest = {
        "variant": VARIANT,
        "years": [p.name[:4] for p in train] if not source else [],
        "source": source,
        "scored": scored,
        "seed": SEED,
        "shuffle_buffer": SHUFFLE_BUFFER,
        "records": counts,
        "tools_sha": json.loads(stamp.read_text()).get("tools_sha") if stamp.exists() else None,
        "built_at": int(time.time()),
    }
    (out / f"{name}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(
        f"dataset {name}: {counts.get('train', 0)} training and {counts.get('val', 0)} "
        f"validation records in {time.time() - started:.0f}s -> {out}"
    )
    return 0
