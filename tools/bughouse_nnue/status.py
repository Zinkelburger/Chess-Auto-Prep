"""What is built, extracted and packed, as one JSON document."""

from __future__ import annotations

import json
from pathlib import Path

from . import toolchain
from .paths import dataset_dir, nets_dir, plain_dir

RECORD_BYTES = 72  # sizeof(PackedSfenValue) in the tools' 512-bit format


def _size(path: Path) -> int:
    return path.stat().st_size if path.exists() else 0


def status() -> dict[str, object]:
    out: dict[str, object] = {"toolchain": toolchain.status()}

    plain = plain_dir()
    years = {}
    for stats_path in sorted(plain.glob("????.stats.json")):
        year = stats_path.name[:4]
        stats = json.loads(stats_path.read_text())
        years[year] = {
            "games": stats.get("used"),
            "train": stats.get("positions", {}).get("train", 0),
            "validation": stats.get("positions", {}).get("validation", 0),
            "scored": (plain / f"{year}.scored.plain").exists(),
        }
    out["plain"] = {"dir": str(plain), "years": years}

    datasets = {}
    for manifest in sorted(dataset_dir().glob("*.json")):
        info = json.loads(manifest.read_text())
        name = manifest.stem
        info["bin_bytes"] = _size(dataset_dir() / f"{name}.bin")
        info["positions_in_bin"] = info["bin_bytes"] // RECORD_BYTES
        datasets[name] = info
    out["datasets"] = {"dir": str(dataset_dir()), "built": datasets}

    out["nets"] = {
        "dir": str(nets_dir()),
        "files": sorted(p.name for p in nets_dir().glob("*.nnue")) if nets_dir().exists() else [],
    }
    return out
