"""Two-board engine games: four single-board searches feeding each other.

Two `DualBoard`s-worth of pocketknight searches play a whole bughouse game: a
capture on one board lands in the partner's hand on the other, exactly as
`extract` replays it, except that here every move is the engine's own.  Two
commands share this: `selfplay`, where both teams run the same eval and the
positions become training data, and `match`, where each team runs its own
eval and only the result counts.

Both boards move in turn, A then B, one half-move each, so each side gets
the same number of searches: a fixed-nodes stand-in for equal clocks.
Nobody sits and there is no clock; a checkmate on either board ends the
game, and a board with no legal move and no check is scored a draw.  Games
start from real openings out of the FICS archive (`opening_plies` per
board), which is what keeps a deterministic engine from playing the same
game twice; `random_plies` of uniformly random moves is the fallback when
the archive is not there.

Every searched position carries the search score *and* the game result,
from the side to move's point of view, so any `--lambda` works.  By default
`per_board` positions per board are kept, quiet ones only, as `extract`
does; `--per-board 0` keeps every searched position.

Output: `selfplay.plain`, `selfplay.val.plain` and `selfplay.stats.json`
beside the archive years, appended to, so runs accumulate.  Then
`convert --source selfplay`.
"""

from __future__ import annotations

import json
import multiprocessing as mp
import os
import random
import sys
import time
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path

import chess

from . import openings
from .engine import Engine
from .extract import TEAM_ONE_IS_WHITE, record, result_for
from .paths import REPO, VARIANT, plain_dir
from .toolchain import require_binary

sys.path.insert(0, str(REPO / "tools" / "mcp"))

NAME = "selfplay"


@dataclass(frozen=True)
class Settings:
    nodes: int = 10000
    opening_plies: int = 10
    random_plies: int = 0
    max_plies: int = 200
    per_board: int = 8
    other_board: float = 0.5
    quiet_only: bool = True
    validation_percent: int = 2
    net: str | None = None


@dataclass
class Searched:
    fen: str
    move: str
    turn: bool
    ply: int
    score: int
    quiet: bool


def eval_options(net: str | None) -> dict[str, str]:
    if net:
        return {"Use NNUE": "pure", "EvalFile": str(Path(net).resolve())}
    return {"Use NNUE": "false"}


def on_team_one(letter: str, turn: bool) -> bool:
    return (turn == chess.WHITE) == TEAM_ONE_IS_WHITE[letter]


def play(engines: tuple[Engine, Engine], settings: Settings, rng: random.Random,
         opening: openings.Opening | None = None) -> tuple[dict[str, list[Searched]], dict]:
    """One game: team one's engine plays WhiteA and BlackB, team two's the rest.

    Returns the searched positions per board and how it ended.
    `outcome["team_one"]` is +1 if team one won, -1 if it lost, 0 for a
    draw, and None when the game hit `max_plies` and was abandoned.
    """
    from bughouse.board import DualBoard  # noqa: PLC0415 -- worker-local import

    for engine in set(engines):
        engine.new_game()
    dual = DualBoard()
    plies = {"A": 0, "B": 0}
    searched: dict[str, list[Searched]] = {"A": [], "B": []}
    outcome: dict = {"team_one": None, "ended_on": None, "termination": "abandoned"}
    for letter, san in opening or []:
        try:
            dual.push(letter, san)
        except Exception:  # noqa: BLE001 -- a bad opening just ends early
            break
        plies[letter] += 1
    for step in range(2 * settings.max_plies):
        letter = "A" if step % 2 == 0 else "B"
        board = dual.board(letter)
        legal = list(board.legal_moves)
        if not legal:
            outcome["ended_on"] = letter
            if board.is_check():
                outcome["team_one"] = -1 if on_team_one(letter, board.turn) else 1
                outcome["termination"] = "checkmate"
            else:
                outcome["team_one"] = 0
                outcome["termination"] = "stalemate"
            break
        if plies[letter] < settings.random_plies:
            move = rng.choice(legal).uci()
        else:
            fen = board.fen()
            engine = engines[0] if on_team_one(letter, board.turn) else engines[1]
            score, move = engine.search(fen, nodes=settings.nodes)
            if move == "(none)":
                raise RuntimeError(f"engine found no move in {fen}")
            quiet = not board.is_check() and not board.is_capture(chess.Move.from_uci(move))
            searched[letter].append(Searched(fen, move, board.turn, plies[letter], score, quiet))
        dual.push(letter, move)
        plies[letter] += 1
    outcome["plies"] = dict(plies)
    return searched, outcome


def sample(searched: dict[str, list[Searched]], outcome: dict, settings: Settings,
           rng: random.Random) -> list[str]:
    out: list[str] = []
    team_one = outcome["team_one"]
    for board in ("A", "B"):
        candidates = [s for s in searched[board] if s.quiet or not settings.quiet_only]
        if settings.per_board:
            want = settings.per_board
            if outcome["ended_on"] != board:
                want = round(want * settings.other_board)
            candidates = rng.sample(candidates, min(want, len(candidates)))
        for s in candidates:
            out.append(record(s.fen, s.move, s.ply + 1, result_for(board, s.turn, team_one), s.score))
    return out


def _play_one(args) -> tuple[int, list[str], dict]:
    index, seed, binary, settings, opening = args
    global _engine  # one engine per worker process, started on first use
    try:
        engine = _engine
    except NameError:
        engine = _engine = Engine(binary, VARIANT, eval_options(settings.net))
    rng = random.Random(seed)
    searched, outcome = play((engine, engine), settings, rng, opening)
    records = sample(searched, outcome, settings, rng) if outcome["team_one"] is not None else []
    return index, records, outcome


def load_openings(games: int, plies: int, rng: random.Random) -> list[openings.Opening]:
    if plies <= 0:
        return []
    print(f"loading {games} openings of {plies} plies per board from the archive…", flush=True)
    found = openings.load(games, plies, rng)
    if not found:
        print("  no archive openings found; falling back to random moves", flush=True)
    return found


def selfplay(games: int, settings: Settings, jobs: int, seed: int | None) -> int:
    binary = require_binary()
    out_dir = plain_dir()
    out_dir.mkdir(parents=True, exist_ok=True)
    train_path, val_path = out_dir / f"{NAME}.plain", out_dir / f"{NAME}.val.plain"
    stats_path = out_dir / f"{NAME}.stats.json"
    jobs = max(1, jobs or os.cpu_count() or 1)
    seed = seed if seed is not None else int(time.time())
    rng = random.Random(seed)
    starts = load_openings(games, settings.opening_plies, rng)
    if not starts and settings.random_plies <= 0:
        settings = Settings(**{**asdict(settings), "random_plies": 8})
    print(
        f"self-play: {games} games on {jobs} core(s), {settings.nodes} nodes/move, "
        f"{len(starts)} archive openings, {settings.random_plies} random plies/board, "
        f"{'net ' + settings.net if settings.net else 'hand-written eval'} -> {out_dir}"
    )
    stats: dict = {
        "games": 0, "abandoned": 0, "termination": Counter(), "ended_on": Counter(),
        "positions": Counter(), "plies": 0, "seed": seed, "settings": asdict(settings),
    }
    started = time.time()
    tasks = [
        (i, seed * 1_000_003 + i, binary, settings, starts[i % len(starts)] if starts else None)
        for i in range(games)
    ]
    with open(train_path, "a") as train, open(val_path, "a") as val, mp.Pool(jobs) as pool:
        for i, records, outcome in pool.imap_unordered(_play_one, tasks, chunksize=1):
            stats["games"] += 1
            stats["plies"] += sum(outcome["plies"].values())
            stats["termination"][outcome["termination"]] += 1
            if outcome["team_one"] is None:
                stats["abandoned"] += 1
                continue
            stats["ended_on"][outcome["ended_on"]] += 1
            if (seed * 7919 + i) % 100 < settings.validation_percent:
                val.write("".join(records))
                stats["positions"]["validation"] += len(records)
            else:
                train.write("".join(records))
                stats["positions"]["train"] += len(records)
            if stats["games"] % 50 == 0 or stats["games"] == games:
                elapsed = time.time() - started
                print(
                    f"  {stats['games']}/{games} games, {sum(stats['positions'].values())} positions, "
                    f"{stats['games'] / elapsed:.2f} games/s, "
                    f"{stats['plies'] / stats['games'] / 2:.0f} plies/board", flush=True,
                )
    stats["seconds"] = round(time.time() - started, 1)
    history = json.loads(stats_path.read_text()) if stats_path.exists() else {"runs": []}
    history["runs"].append(stats)
    history["positions"] = {
        k: sum(run["positions"].get(k, 0) for run in history["runs"]) for k in ("train", "validation")
    }
    stats_path.write_text(json.dumps(history, indent=2, default=dict) + "\n")
    print(
        f"{stats['games'] - stats['abandoned']}/{stats['games']} games finished "
        f"({dict(stats['termination'])}), {stats['positions']['train']} training and "
        f"{stats['positions']['validation']} validation positions in {stats['seconds']:.0f}s; "
        f"{NAME} now holds {history['positions']['train']} + {history['positions']['validation']}"
    )
    return 0
