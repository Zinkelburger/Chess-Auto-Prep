#!/usr/bin/env python3
"""
Build the app-bundled player directory assets.

Reads the research output in scripts/data/ and scripts/chesscom_titled_analysis/
and emits two compact JSON assets consumed by lib/features/tournament/services/
player_directory.dart:

  assets/data/uscf_chesscom_map.json   USCF ID -> chess.com username + evidence
  assets/data/chesscom_titled.json     chess.com username -> title

Re-run this after extending the mapping with build_player_map.py, then commit
the regenerated assets.

Usage:
    python scripts/build_directory_assets.py
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "scripts" / "data"
TITLED = ROOT / "scripts" / "chesscom_titled_analysis" / "data"
OUT = ROOT / "assets" / "data"

# Confidence levels we are willing to ship. "ambiguous"/"unmappable" rows carry
# no username and would only add weight to the asset.
SHIPPED_CONFIDENCE = {"exact", "high", "medium"}

# Titles in descending strength; a username appearing in two rosters keeps the
# strongest (chess.com occasionally lists a player under an old title).
TITLE_ORDER = ["GM", "IM", "FM", "NM", "CM"]


def build_mapping() -> dict:
    src = json.loads((DATA / "player_mapping.json").read_text())
    players = src.get("players", {})

    out = {}
    for uscf_id, row in players.items():
        username = row.get("chesscom_username")
        confidence = row.get("confidence", "")
        if not username or confidence not in SHIPPED_CONFIDENCE:
            continue
        out[uscf_id] = {
            "u": username,
            "n": row.get("uscf_name", ""),
            "c": confidence,
            "m": row.get("method", ""),
            # Evidence: the event this linkage was established from.
            "e": row.get("event_id", ""),
            "d": row.get("event_date", ""),
        }

    return {
        "schema": 1,
        "source": "USCF-rated events hosted by CHESSCOM LLC (affiliate A6044892)",
        "events_processed": len(src.get("events_processed", [])),
        "players": out,
    }


def build_titled() -> dict:
    out = {}
    # Walk weakest-first so stronger titles overwrite.
    for title in reversed(TITLE_ORDER):
        path = TITLED / f"titled_{title}.json"
        if not path.exists():
            print(f"  (skipping missing {path.name})")
            continue
        for username in json.loads(path.read_text()):
            out[username.lower()] = title
    return {"schema": 1, "titles": out}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    mapping = build_mapping()
    mapping_path = OUT / "uscf_chesscom_map.json"
    mapping_path.write_text(json.dumps(mapping, separators=(",", ":")))
    print(
        f"wrote {mapping_path.relative_to(ROOT)}  "
        f"({len(mapping['players'])} players, {mapping_path.stat().st_size // 1024} KB)"
    )

    titled = build_titled()
    titled_path = OUT / "chesscom_titled.json"
    titled_path.write_text(json.dumps(titled, separators=(",", ":")))
    print(
        f"wrote {titled_path.relative_to(ROOT)}  "
        f"({len(titled['titles'])} titled accounts, "
        f"{titled_path.stat().st_size // 1024} KB)"
    )


if __name__ == "__main__":
    main()
