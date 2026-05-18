#!/usr/bin/env python3
"""
Fetch ECO opening data from lichess-org/chess-openings and produce eco.json.

Output format: array of [eco_code, opening_name, pgn_moves, final_fen] quads, sorted by ECO code.
Source: https://github.com/lichess-org/chess-openings (CC0 public domain)
"""

import json
import urllib.request
from pathlib import Path

import chess
import chess.pgn
import io

BASE_URL = "https://raw.githubusercontent.com/lichess-org/chess-openings/master"
FILES = ["a.tsv", "b.tsv", "c.tsv", "d.tsv", "e.tsv"]

OUTPUT = Path(__file__).resolve().parent.parent / "public" / "eco.json"


def pgn_to_fen(pgn_text: str) -> str:
    """Use python-chess to play through PGN moves and return the final board FEN."""
    game = chess.pgn.read_game(io.StringIO(pgn_text))
    if game is None:
        return chess.STARTING_FEN
    board = game.board()
    for move in game.mainline_moves():
        board.push(move)
    return board.fen()


def main():
    entries: list[tuple[str, str, str]] = []

    for fname in FILES:
        url = f"{BASE_URL}/{fname}"
        print(f"Fetching {url} ...")
        with urllib.request.urlopen(url) as resp:
            text = resp.read().decode("utf-8")

        for i, line in enumerate(text.strip().splitlines()):
            if i == 0:
                continue  # skip header
            parts = line.split("\t")
            if len(parts) >= 3:
                eco = parts[0].strip()
                name = parts[1].strip()
                pgn = parts[2].strip()
                entries.append((eco, name, pgn))

    # Deduplicate: same eco+name can appear if multiple move orders reach it;
    # keep the shortest line (most canonical)
    best: dict[tuple[str, str], str] = {}
    for eco, name, pgn in sorted(entries):
        key = (eco, name)
        if key not in best or len(pgn) < len(best[key]):
            best[key] = pgn

    print(f"Computing FENs for {len(best)} openings ...")
    unique: list[list[str]] = []
    for (eco, name), pgn in sorted(best.items()):
        fen = pgn_to_fen(pgn)
        # Only keep the board placement part of FEN for display (saves space)
        fen_placement = fen.split(" ")[0]
        unique.append([eco, name, pgn, fen_placement])

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT, "w") as f:
        json.dump(unique, f, separators=(",", ":"))

    print(f"Wrote {len(unique)} openings to {OUTPUT}")
    print(f"File size: {OUTPUT.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()
