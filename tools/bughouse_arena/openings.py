"""Opening sets for arena matches, cut from real FICS bughouse games.

An opening is the first ``--plies`` half-moves of a rated game, both boards
together, *in the order they were actually played*. Replaying that prefix
through the referee reproduces the real pockets at that moment: whatever the
players had captured and passed is in hand, promoted pieces stay marked.
Positions are kept only when the game is still undecided under the arena's
rules, neither side to move is in check, both have a legal move, each board
has at least ``--min-board-plies`` and at least one pocket is non-empty.

Board roles are balanced across a set: every second opening is written with
its boards swapped (board A's history played on B and vice versa), so a board
that happened to be further along in the source game is board A in half the
set and board B in the other half. Within a match each opening is played
twice with the teams swapped (match.py), so every engine plays all four seats
of every opening.

Sets in ``opening_sets/`` (see their headers for the exact command):

* ``debug.txt``     engine debugging and tuning only; never for results
* ``preflight.txt`` middlegame positions for the Hivemind latency preflight
* ``screen20.txt``  the 20-pair screening matches
* ``heldout200.txt`` the 200-pair strength matches; do not look at it before

Each set comes from its own archive year, and ``--exclude`` rejects any
position already in another set, so they are disjoint. "Held out" means held
out from our tuning and screening; what Hivemind's training data contained is
not known. Run from ``tools/``::

    python3 -m bughouse_arena.openings --year 2016 --count 200 \\
        --out bughouse_arena/opening_sets/heldout200.txt \\
        --exclude bughouse_arena/opening_sets/debug.txt ...
"""

from __future__ import annotations

import argparse
import hashlib
import heapq
import shlex
import sys
from pathlib import Path

import chess

from bughouse_db.bpgn import iter_games, open_bpgn
from bughouse_db.paths import corpus_dir

from .referee import BOARDS, Bughouse, IllegalMove

HERE = Path(__file__).resolve().parent / "opening_sets"


def swap_boards(tokens: list[str]) -> list[str]:
    """The same history with boards A and B exchanged."""
    return [("2" if token[0] == "1" else "1") + token[1:] for token in tokens]


def position_key(game: Bughouse) -> str:
    """Both boards, pockets and turns: the identity used for deduplication.
    Board-swapped copies count as the same opening."""
    fens = sorted(board.fen(promoted=True).rsplit(" ", 2)[0] for board in game.boards)
    return "|".join(fens)


def replay_prefix(moves: list[tuple[str, str]], plies: int) -> Bughouse | None:
    """The referee state after the game's first ``plies`` half-moves, or None
    if any of them does not parse or is illegal under the referee."""
    game = Bughouse()
    for letter, san in moves[:plies]:
        board = 0 if letter.upper() == "A" else 1
        try:
            move = game.boards[board].parse_san(san)
            game.push(board, move.uci())
        except (ValueError, IllegalMove):
            return None
    return game


def acceptable(game: Bughouse, min_board_plies: int) -> bool:
    per_board = [sum(1 for move in game.moves if move.board == board) for board in BOARDS]
    if min(per_board) < min_board_plies:
        return False
    for board in BOARDS:
        position = game.boards[board]
        if position.is_check() or not game.has_legal_move(board):
            return False
    for team in (chess.WHITE, chess.BLACK):
        for advantage in (False, True):
            if game.is_checkmate(team, advantage):
                return False
    if game.is_draw():
        return False
    return any(len(game.boards[board].pockets[color]) > 0
               for board in BOARDS for color in (chess.WHITE, chess.BLACK))


def read_keys(path: Path) -> set[str]:
    from .match import load_openings
    return {position_key(opening.build()) for opening in load_openings(path)}


def sample_rank(game_no: int, salt: str) -> str:
    """A seeded, uniform order over games, so a set spreads over the whole
    year rather than the evening the date-sorted archive happens to start on."""
    return hashlib.sha256(f"{salt}:{game_no}".encode()).hexdigest()


def build(year: int, count: int, plies: int, min_board_plies: int = 6, min_elo: int = 1800,
          salt: str = "arena", exclude: set[str] | None = None) -> list[tuple[list[str], str]]:
    """``count`` openings from ``export{year}``: rated games whose four
    ratings are all at least ``min_elo``, taken in ``sample_rank`` order."""
    source = corpus_dir() / f"export{year}.bpgn.bz2"
    if not source.exists():
        raise FileNotFoundError(f"{source}: fetch the archive with python3 -m bughouse_db fetch")
    keep = max(50, count * 6)
    heap: list[tuple[str, int, list, str]] = []  # max-heap on rank via negation trick below
    with open_bpgn(source) as lines:
        for game in iter_games(lines):
            if not game.rated or min(game.elos()) < min_elo or len(game.moves) <= plies:
                continue
            rank = sample_rank(game.game_no, salt)
            entry = (_Inverted(rank), game.game_no, game.moves, game.tags.get("Date", ""))
            if len(heap) < keep:
                heapq.heappush(heap, entry)
            elif rank < heap[0][0].value:
                heapq.heapreplace(heap, entry)
    candidates = sorted(heap, key=lambda item: item[0].value)
    seen = set(exclude or ())
    out: list[tuple[list[str], str]] = []
    for _, game_no, moves, date in candidates:
        if len(out) >= count:
            break
        state = replay_prefix(moves, plies)
        if state is None or not acceptable(state, min_board_plies):
            continue
        key = position_key(state)
        if key in seen:
            continue
        seen.add(key)
        tokens = state.engine_moves()
        swapped = len(out) % 2 == 1
        if swapped:
            tokens = swap_boards(tokens)
        check = Bughouse()
        for token in tokens:
            check.push(int(token[0]) - 1, token[1:])
        out.append((tokens, f"fics={game_no} year={year} date={date} swapped={int(swapped)}"))
    if len(out) < count:
        raise RuntimeError(f"only {len(out)} openings in {source} under these filters")
    return out


class _Inverted:
    """Orders strings backwards, turning heapq's min-heap into a max-heap."""
    __slots__ = ("value",)

    def __init__(self, value: str):
        self.value = value

    def __lt__(self, other: "_Inverted") -> bool:
        return self.value > other.value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m bughouse_arena.openings",
                                     description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--plies", type=int, default=16, help="half-moves over both boards")
    parser.add_argument("--min-board-plies", type=int, default=6)
    parser.add_argument("--min-elo", type=int, default=1800, help="lowest of the four ratings")
    parser.add_argument("--salt", default="arena", help="seed of the sampling order")
    parser.add_argument("--purpose", default="", help="one line for the file header")
    parser.add_argument("--exclude", type=Path, nargs="*", default=[])
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    exclude: set[str] = set()
    for path in args.exclude:
        exclude |= read_keys(path)
    openings = build(args.year, args.count, args.plies, args.min_board_plies, args.min_elo,
                     args.salt, exclude)
    command = "python3 -m bughouse_arena.openings " + shlex.join(
        argv if argv is not None else sys.argv[1:])
    header = [
        f"# {args.purpose}" if args.purpose else "# arena opening set",
        f"# generated by: {command}",
        f"# source: FICS export{args.year}, rated, all four ratings >= {args.min_elo}, "
        f"sampled across the year in sha256('{args.salt}:<game no>') order",
        f"# each line: the first {args.plies} half-moves in played order (engine tokens), "
        "then provenance; odd lines are board-swapped",
    ]
    lines = header + [" ".join(tokens) + "\t" + source for tokens, source in openings]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines) + "\n")
    print(f"{args.out}: {len(openings)} openings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
