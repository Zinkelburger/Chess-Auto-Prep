"""Contender-vs-baseline bughouse matches in virtual time.

Each opening is played twice with the teams swapped and the same think-cost
sequence per seat, so the pair, not the game, is the unit the statistics use.
Every game seats four independent players: the contender holds both seats of
one team, the baseline the other two.
"""

from __future__ import annotations

import json
import os
import queue
import random
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import chess

from .players import EngineSpec, HivemindSeat, RandomPlayer
from .referee import BOARD_A, BOARD_B, BOARDS, Bughouse, team_color, team_name
from .sim import SEAT_NAMES, ClockConfig, GameResult, play_game, seat_index
from .stats import summarize


# ----------------------------------------------------------------- openings

@dataclass(frozen=True)
class Opening:
    dual_fen: str | None
    moves: tuple[str, ...]

    def build(self) -> Bughouse:
        game = Bughouse.from_dual_fen(self.dual_fen) if self.dual_fen else Bughouse()
        for token in self.moves:
            game.push(int(token[0]) - 1, token[1:])
        return game

    def to_json(self) -> dict:
        return {"dual_fen": self.dual_fen, "moves": list(self.moves)}


def load_openings(path: Path) -> list[Opening]:
    """One opening per line: engine-format moves (``1e2e4 2d2d4``), or a dual
    FEN (the tournament positions format; extra tab fields are ignored, since
    the clocks decide time advantage here)."""
    openings = []
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        first = line.split("\t")[0].strip()
        opening = (Opening(first, ()) if "|" in first
                   else Opening(None, tuple(first.split())))
        try:
            opening.build()
        except ValueError as error:
            raise ValueError(f"{path}:{number}: {error}") from error
        openings.append(opening)
    if not openings:
        raise ValueError(f"{path}: no openings")
    return openings


def random_opening(seed: int, pair: int, plies_per_board: int) -> Opening:
    rng = random.Random(f"opening:{seed}:{pair}")
    game = Bughouse()
    for _ in range(plies_per_board):
        for board in BOARDS:
            game.push(board, rng.choice(sorted(game.legal_moves(board))))
    return Opening(None, tuple(game.engine_moves()))


# ------------------------------------------------------------------ players

class PlayerFactory:
    """Builds one side's two seats from a spec string."""

    def __init__(self, text: str, default_binary: Path | None,
                 ort_threads: int | None, log_dir: Path | None):
        self.text = text
        self.ort_threads = ort_threads
        self.log_dir = log_dir
        if text == "random" or text.startswith("random,"):
            options = dict(item.split("=", 1) for item in text.split(",")[1:])
            self.random_sit = float(options.get("sit", 0.0))
            self.spec = None
            self.name = options.get("name", "random")
        else:
            self.spec = EngineSpec.parse(text, default_binary)
            self.name = self.spec.name

    def describe(self) -> dict:
        return self.spec.describe() if self.spec else {"name": self.name, "random_sit": self.random_sit}

    def make(self, label: str, seed: int):
        if self.spec is None:
            return RandomPlayer(seed, self.random_sit, self.name)
        log = self.log_dir / f"{label}.log" if self.log_dir else None
        return HivemindSeat(self.spec, ort_threads=self.ort_threads, log_path=log)


class SeatSet:
    """The four processes one worker plays its games with."""

    def __init__(self, contender: PlayerFactory, baseline: PlayerFactory, worker: int):
        self.contender = [contender.make(f"w{worker}-contender-{b}", worker * 4 + i)
                          for i, b in enumerate("AB")]
        self.baseline = [baseline.make(f"w{worker}-baseline-{b}", worker * 4 + 2 + i)
                         for i, b in enumerate("AB")]

    def seating(self, contender_team: chess.Color) -> dict[int, object]:
        seats = {}
        for side, team in ((self.contender, contender_team), (self.baseline, not contender_team)):
            for board in BOARDS:
                seats[seat_index(board, team_color(team, board))] = side[board]
        return seats

    def close(self) -> None:
        for player in self.contender + self.baseline:
            player.close()


# -------------------------------------------------------------------- match

@dataclass
class MatchConfig:
    pairs: int
    clock: ClockConfig
    output: Path
    seed: int = 1
    openings: list[Opening] | None = None
    opening_plies: int = 2
    concurrency: int = 1
    resume: bool = False
    sprt: tuple[float, float, float, float] | None = None
    verbose: bool = False


def game_plan(config: MatchConfig) -> list[tuple[int, int, chess.Color, Opening]]:
    plan = []
    for pair in range(config.pairs):
        opening = (config.openings[pair % len(config.openings)] if config.openings
                   else random_opening(config.seed, pair, config.opening_plies))
        for offset, team in enumerate((chess.WHITE, chess.BLACK)):
            plan.append((2 * pair + offset, pair, team, opening))
    return plan


def contender_score(result: GameResult, contender_team: chess.Color) -> float:
    if result.winner is None:
        return 0.5
    return 1.0 if result.winner == contender_team else 0.0


def write_bpgn(stream, record: dict, names: dict[str, str]) -> None:
    result = record["result"]
    outcome = {"white": "1-0", "black": "0-1", None: "1/2-1/2"}[result["winner"]]
    seat_names = {seat: names[seat] for seat in SEAT_NAMES}
    stream.write(
        f'[Event "Hivemind Arena"]\n[Round "{record["game"] + 1}"]\n'
        f'[WhiteA "{seat_names["A-white"]}"]\n[BlackA "{seat_names["A-black"]}"]\n'
        f'[WhiteB "{seat_names["B-white"]}"]\n[BlackB "{seat_names["B-black"]}"]\n'
        f'[TimeControl "{record["clock"]["initial_ms"] / 1000:g}"]\n'
        f'[Opening "{" ".join(record["opening"]["moves"])}"]\n'
        f'[Result "{outcome}"]\n[Termination "{result["termination"]}"]\n\n')
    numbers = {"A": 0, "a": 0, "B": 0, "b": 0}
    tokens = []
    for event in result["events"]:
        if event["kind"] == "move":
            label = event["board"] if event["seat"].endswith("white") else event["board"].lower()
            numbers[label] += 1
            clock = event["clocks"][SEAT_NAMES.index(event["seat"])] / 1000
            tokens.append(f"{numbers[label]}{label}. {event['uci']} {{{event['t'] / 1000:.1f}s {clock:.1f}}}")
        elif event["kind"] == "sit":
            tokens.append(f"{{{event['seat']} sits @{event['t'] / 1000:.1f}s}}")
    stream.write(" ".join(tokens) + f" {outcome}\n\n")


def run_match(config: MatchConfig, contender: PlayerFactory, baseline: PlayerFactory,
              log: Callable[[str], None] = print) -> dict:
    config.output.mkdir(parents=True, exist_ok=True)
    results_path = config.output / "results.jsonl"
    summary_path = config.output / "summary.json"
    bpgn_path = config.output / "games.bpgn"

    records: list[dict] = []
    if config.resume and results_path.exists():
        records = [json.loads(line) for line in results_path.read_text().splitlines() if line]
        records = [r for r in records if r["result"]["termination"] != "error"]
        results_path.write_text("".join(json.dumps(r) + "\n" for r in records))
    elif results_path.exists():
        raise FileExistsError(f"{results_path} exists; pass --resume or pick a new --output")
    done = {r["game"] for r in records}

    plan = [item for item in game_plan(config) if item[0] not in done]
    work: queue.Queue = queue.Queue()
    for item in plan:
        work.put(item)
    lock = threading.Lock()
    stop = threading.Event()
    started = time.monotonic()
    meta = {"contender": contender.describe(), "baseline": baseline.describe(),
            "clock": vars(config.clock) | {"move_cost_ms": list(config.clock.move_cost_ms)},
            "pairs": config.pairs, "seed": config.seed}

    def write_summary() -> dict:
        summary = {**meta, **summarize(records, config.sprt),
                   "wall_seconds": time.monotonic() - started}
        temporary = summary_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(summary, indent=2) + "\n")
        temporary.replace(summary_path)
        return summary

    failures: list[str] = []

    def worker(index: int) -> None:
        seats = None
        try:
            while not stop.is_set():
                try:
                    game_index, pair, team, opening = work.get_nowait()
                except queue.Empty:
                    return
                if seats is None:
                    seats = SeatSet(contender, baseline, index)
                seating = seats.seating(team)
                names = {SEAT_NAMES[s]: p.name for s, p in seating.items()}
                on_event = None
                if config.verbose:
                    def on_event(event, game_index=game_index):
                        if event["kind"] in ("move", "sit", "flag", "end"):
                            clocks = " ".join(f"{c / 1000:5.1f}" for c in event["clocks"])
                            detail = event.get("uci") or event.get("termination") or ""
                            log(f"  g{game_index + 1} {event['t'] / 1000:6.1f}s "
                                f"{event['seat'] or '':8} {event['kind']:5} {detail:8} [{clocks}]")
                game_start = time.monotonic()
                result = play_game(opening.build(), seating, config.clock,
                                   cost_key=f"{config.seed}:{pair}", on_event=on_event)
                record = {
                    "game": game_index, "pair": pair,
                    "contender": contender.name, "baseline": baseline.name,
                    "contender_team": team_name(team),
                    "contender_score": contender_score(result, team),
                    "opening": opening.to_json(), "seats": names,
                    "clock": meta["clock"],
                    "wall_seconds": time.monotonic() - game_start,
                    "result": result.to_json(),
                }
                with lock:
                    records.append(record)
                    with results_path.open("a") as stream:
                        stream.write(json.dumps(record) + "\n")
                    with bpgn_path.open("a") as stream:
                        write_bpgn(stream, record, names)
                    summary = write_summary()
                    elo = summary["contender_elo"]
                    log(f"game {game_index + 1}/{2 * config.pairs} pair {pair + 1} "
                        f"contender={team_name(team)} -> {'draw' if result.winner is None else team_name(result.winner) + ' wins'} "
                        f"by {result.termination} at {result.duration_ms / 1000:.1f}s "
                        f"({record['wall_seconds']:.0f}s wall) | "
                        f"+{summary['contender_wins']} -{summary['contender_losses']} ={summary['draws']}"
                        + (f" elo {elo:+.0f}" if elo is not None else ""))
                    if result.error:
                        log(f"  error: {result.error}")
                    sprt = summary.get("sprt")
                    if sprt and sprt["decision"] != "continue":
                        log(f"SPRT {sprt['decision']} (LLR {sprt['llr']:.2f}); stopping")
                        stop.set()
                if result.termination == "error":
                    seats.close()
                    seats = None
        except Exception as error:  # a seat that cannot start stops the match
            with lock:
                failures.append(f"worker {index}: {error}")
                log(f"worker {index} failed: {error}")
            stop.set()
        finally:
            if seats is not None:
                seats.close()

    threads = [threading.Thread(target=worker, args=(i,), daemon=True)
               for i in range(max(1, min(config.concurrency, len(plan) or 1)))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    summary = write_summary()
    if failures:
        raise RuntimeError("; ".join(failures))
    return summary


def default_ort_threads(concurrency: int) -> int:
    # Only the seat on move searches, so each game keeps one search of four
    # search threads busy; split the cores between the concurrent games.
    return max(1, (os.cpu_count() or 4) // (4 * max(1, concurrency)))
