"""Opening sequences for engine games, taken from the FICS archive.

An engine game has to start somewhere other than the start position, or a
deterministic engine plays the same game every time.  Random moves do that
but produce absurd positions; the archive has millions of real bughouse
openings, so the first few plies of real games are used instead.  Each
opening is both boards' first `plies` half-moves in the order they were
played, as `(board, san)` pairs the way `DualBoard.push` takes them.
"""

from __future__ import annotations

import random

from bughouse_db.bpgn import iter_games, open_bpgn
from bughouse_db.paths import corpus_dir

Opening = list[tuple[str, str]]


def load(count: int, plies: int, rng: random.Random, min_elo: int = 1800) -> list[Opening]:
    """`count` openings of `plies` half-moves per board, from random years."""
    sources = sorted(corpus_dir().glob("export*.bpgn.bz2"))
    if not sources or count <= 0 or plies <= 0:
        return []
    out: list[Opening] = []
    for source in rng.sample(sources, min(3, len(sources))):
        want = count - len(out)
        if want <= 0:
            break
        with open_bpgn(source) as lines:
            for game in iter_games(lines):
                if not game.rated or min(game.elos()) < min_elo:
                    continue
                opening = _truncate(game.moves, plies)
                if opening is not None:
                    out.append(opening)
                    if len(out) - (count - want) >= want:
                        break
    rng.shuffle(out)
    return out[:count]


def _truncate(moves: list[tuple[str, str]], plies: int) -> Opening | None:
    """The first `plies` half-moves of each board, in played order, or None
    if either board has fewer."""
    seen = {"A": 0, "B": 0}
    out: Opening = []
    for which, san in moves:
        letter = which.upper()
        if seen[letter] >= plies:
            continue
        seen[letter] += 1
        out.append((letter, san))
        if seen["A"] >= plies and seen["B"] >= plies:
            return out
    return None
