"""Replay the FICS archive into the trainer's plain-text records.

One worker per archive year, as `bughouse_db.index` does, each replaying its
games with the same `DualBoard` the Bughouse Lab drives: a capture goes to
the partner board's reserve, a promoted piece reverts to a pawn when taken.
That two-board replay is what makes the single-board records honest -- the
hands in each position are the hands the players really had, fed by a real
partner, not something simulated.

A record is one board of a game at one moment, written the way
`variant-nnue-tools` reads it back (`convert_bin`):

    fen <crazyhouse FEN with the hands in brackets>
    move <the move played, UCI>
    score 0            (a shallow search fills this in later, if wanted)
    ply <half-moves played on this board, 1-based>
    result <1 | 0 | -1: did the side to move's team win?>
    e

The label is the team's result from the side to move's point of view, which
is what the trainer's `--lambda 0` regresses a win probability on.  Teams
sit crosswise: WhiteA and BlackB are one team, so White to move on board B
is on the team that *loses* a `1-0`.

Sampling: `per_board` positions from each board, chosen at random from its
plies past `min_ply`, and fewer (`other_board` of that) from the board the
game did not end on, since that board's position says less about the
result.  Games with no result, unrated games, and boards with a player under
`min_elo` are skipped.  A fixed share of games, by game number, goes to the
validation files instead.

Each year also gets a `stats.json`: how games ended and on which board, and
which pieces arrived in the hands at which stage of the game -- the arrival
statistics behind the question of how random the piece flow really is.
"""

from __future__ import annotations

import json
import multiprocessing as mp
import os
import random
import sys
import time
import zlib
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path

import chess

from bughouse_db.bpgn import BpgnGame, iter_games, open_bpgn
from bughouse_db.paths import corpus_dir

from .paths import REPO, plain_dir

sys.path.insert(0, str(REPO / "tools" / "mcp"))

RESULTS = {"1-0": 1, "0-1": -1, "1/2-1/2": 0}

#: Which colour on each board belongs to the team that wins a `1-0`.
TEAM_ONE_IS_WHITE = {"A": True, "B": False}

ELO_TAGS = {"A": ("WhiteAElo", "BlackAElo"), "B": ("WhiteBElo", "BlackBElo")}


@dataclass(frozen=True)
class Settings:
    min_elo: int = 1800
    per_board: int = 6
    min_ply: int = 6
    other_board: float = 0.5
    validation_percent: int = 2
    max_games: int = 0


@dataclass
class Snapshot:
    """One board just before a move was played on it."""

    fen: str
    move: str
    turn: bool
    ply: int  # half-moves already played on this board


def record(fen: str, move: str, ply: int, result: int, score: int = 0) -> str:
    return f"fen {fen}\nmove {move}\nscore {score}\nply {ply}\nresult {result}\ne\n"


def result_for(board: str, turn: bool, team_one_result: int) -> int:
    """`team_one_result` (+1 if WhiteA's team won) seen from `turn` on `board`."""
    on_team_one = (turn == chess.WHITE) == TEAM_ONE_IS_WHITE[board]
    return team_one_result if on_team_one else -team_one_result


def board_elos(game: BpgnGame, board: str) -> tuple[int, int]:
    out = []
    for tag in ELO_TAGS[board]:
        try:
            out.append(int(game.tags.get(tag, "0")))
        except ValueError:
            out.append(0)
    return out[0], out[1]


def termination_kind(text: str) -> str:
    """`checkmated`, `resigns`, `forfeits on time`, … without the handle."""
    return text.split(" ", 1)[1] if " " in text else text


def game_key(game: BpgnGame) -> int:
    """A stable per-game number: bughouse-db's id, or a CRC of the tags.

    Python's `hash` of a string changes between processes, so it cannot seed
    anything that should replay the same way twice.
    """
    if game.game_no:
        return game.game_no
    return zlib.crc32(repr(sorted(game.tags.items())).encode()) or 1


def is_validation(game: BpgnGame, percent: int) -> bool:
    return game_key(game) % 100 < percent


def _arrived(before: str, after: str) -> str:
    """The piece letters in `after` (a pocket) that were not in `before`."""
    gained = Counter(after) - Counter(before)
    return "".join(sorted(gained.elements()))


def replay(game: BpgnGame, stats: dict) -> dict[str, list[Snapshot]] | None:
    """Both boards' snapshots, or None when a move does not replay."""
    from bughouse.board import DualBoard  # noqa: PLC0415 -- worker-local import

    dual = DualBoard()
    snapshots: dict[str, list[Snapshot]] = {"A": [], "B": []}
    plies = {"A": 0, "B": 0}
    arrivals = stats["arrivals"]
    try:
        for which, san in game.moves:
            letter = which.upper()
            board = dual.board(letter)
            other = dual.board("B" if letter == "A" else "A")
            fen = board.fen()
            mover = board.turn
            pocket_before = str(other.pockets[not mover])
            ply = dual.push(letter, san)
            if "x" in ply.san:
                gained = _arrived(pocket_before, str(other.pockets[not mover]))
                for piece in gained:
                    arrivals["by_piece"][piece.upper()] += 1
                    arrivals["by_decile"][str(min(plies[letter] // 10, 9))] += 1
            snapshots[letter].append(Snapshot(fen, ply.uci, mover, plies[letter]))
            plies[letter] += 1
    except Exception:  # noqa: BLE001 -- a corrupt game must not stop a year
        return None
    return snapshots


def sample(game: BpgnGame, snapshots: dict[str, list[Snapshot]], settings: Settings,
           rng: random.Random, team_one_result: int, ended_on: str | None) -> list[str]:
    out: list[str] = []
    for board in ("A", "B"):
        lo, hi = board_elos(game, board)
        if min(lo, hi) < settings.min_elo:
            continue
        want = settings.per_board
        if ended_on is not None and ended_on != board:
            want = round(want * settings.other_board)
        candidates = [s for s in snapshots[board] if s.ply >= settings.min_ply]
        if want <= 0 or not candidates:
            continue
        for snap in rng.sample(candidates, min(want, len(candidates))):
            out.append(record(snap.fen, snap.move, snap.ply + 1,
                              result_for(board, snap.turn, team_one_result)))
    return out


def new_stats(source: str) -> dict:
    return {
        "source": source,
        "games": 0,
        "used": 0,
        "skipped": Counter(),
        "ended_on": Counter(),
        "termination": Counter(),
        "positions": Counter(),
        "arrivals": {"by_piece": Counter(), "by_decile": Counter()},
    }


def extract_year(args) -> tuple[str, dict]:
    source, out_dir, settings = args
    stats = new_stats(source.name)
    year = source.name[6:10]
    train_path = out_dir / f"{year}.plain"
    val_path = out_dir / f"{year}.val.plain"
    started = time.time()
    with open(train_path, "w") as train, open(val_path, "w") as val, open_bpgn(source) as lines:
        for game in iter_games(lines):
            stats["games"] += 1
            if settings.max_games and stats["games"] > settings.max_games:
                break
            if not game.moves:
                stats["skipped"]["empty"] += 1
                continue
            if not game.rated:
                stats["skipped"]["unrated"] += 1
                continue
            if game.result not in RESULTS:
                stats["skipped"]["no result"] += 1
                continue
            snapshots = replay(game, stats)
            if snapshots is None:
                stats["skipped"]["unreplayable"] += 1
                continue
            ended_on = game.ended_on()
            stats["ended_on"][ended_on or "unknown"] += 1
            stats["termination"][termination_kind(game.termination) or "unknown"] += 1
            rng = random.Random(game_key(game))
            records = sample(game, snapshots, settings, rng, RESULTS[game.result], ended_on)
            if not records:
                stats["skipped"]["elo"] += 1
                continue
            stats["used"] += 1
            if is_validation(game, settings.validation_percent):
                val.write("".join(records))
                stats["positions"]["validation"] += len(records)
            else:
                train.write("".join(records))
                stats["positions"]["train"] += len(records)
    stats["seconds"] = round(time.time() - started, 1)
    stats["settings"] = asdict(settings)
    (out_dir / f"{year}.stats.json").write_text(json.dumps(stats, indent=2, default=dict) + "\n")
    return source.name, stats


def extract(years: list[int] | None, settings: Settings, jobs: int) -> int:
    sources = sorted(corpus_dir().glob("export*.bpgn.bz2"))
    if years:
        sources = [p for p in sources if int(p.name[6:10]) in years]
    if not sources:
        raise SystemExit(
            f"no archive files in {corpus_dir()} -- run "
            "`python3 -m bughouse_db fetch` first"
        )
    out_dir = plain_dir()
    out_dir.mkdir(parents=True, exist_ok=True)
    jobs = max(1, min(jobs or os.cpu_count() or 1, len(sources)))
    print(
        f"extracting {len(sources)} year(s) on {jobs} core(s): "
        f"{settings.per_board} per board, Elo >= {settings.min_elo}, "
        f"{settings.validation_percent}% held out -> {out_dir}"
    )
    started = time.time()
    total = new_stats("all")
    tasks = [(src, out_dir, settings) for src in sources]
    with mp.Pool(jobs) as pool:
        for name, stats in pool.imap_unordered(extract_year, tasks):
            print(
                f"  {name}: {stats['used']:>7}/{stats['games']} games, "
                f"{stats['positions']['train']} + {stats['positions']['validation']} positions "
                f"({stats['seconds']:.0f}s)"
            )
            for key in ("games", "used"):
                total[key] += stats[key]
            for key in ("skipped", "ended_on", "termination", "positions"):
                total[key].update(stats[key])
            for key in ("by_piece", "by_decile"):
                total["arrivals"][key].update(stats["arrivals"][key])
    total["seconds"] = round(time.time() - started, 1)
    total["settings"] = asdict(settings)
    total["years"] = [p.name[6:10] for p in sources]
    (out_dir / "stats.json").write_text(json.dumps(total, indent=2, default=dict) + "\n")
    print(
        f"{total['used']}/{total['games']} games used, "
        f"{total['positions']['train']} training and "
        f"{total['positions']['validation']} validation positions "
        f"in {total['seconds']:.0f}s"
    )
    arrivals = total["arrivals"]["by_piece"]
    if arrivals:
        n = sum(arrivals.values())
        print("arrivals: " + ", ".join(f"{p} {c / n:.1%}" for p, c in sorted(arrivals.items())))
    return 0
