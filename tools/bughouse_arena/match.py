"""Contender-vs-baseline bughouse matches in virtual time.

Each opening is played twice with the teams swapped and the same think-cost
sequence per seat, so the pair, not the game, is the unit the statistics use.
Every game seats four independent players: the contender holds both seats of
one team, the baseline the other two.

Every match directory gets a ``manifest.json`` pinning what was played: each
side's kind, settings, binary/model/runtime/net SHA-256 and the engine's own
``uci`` self-description, the opening file and its hash, the clock model, the
arena source, the host and the command line. ``--resume`` refuses to continue
a match whose pins changed.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import queue
import random
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import chess

from .players import EngineSpec, RandomPlayer, make_seat
from .referee import BOARDS, Bughouse, team_color, team_name
from .sim import SEAT_NAMES, ClockConfig, GameResult, SeatView, play_game, seat_index
from .stats import summarize


# ----------------------------------------------------------------- openings

@dataclass(frozen=True)
class Opening:
    dual_fen: str | None
    moves: tuple[str, ...]
    source: str = ""

    def build(self) -> Bughouse:
        game = Bughouse.from_dual_fen(self.dual_fen) if self.dual_fen else Bughouse()
        for token in self.moves:
            game.push(int(token[0]) - 1, token[1:])
        return game

    def to_json(self) -> dict:
        data = {"dual_fen": self.dual_fen, "moves": list(self.moves)}
        if self.source:
            data["source"] = self.source
        return data


def load_openings(path: Path) -> list[Opening]:
    """One opening per line: engine-format moves (``1e2e4 2d2d4``), or a dual
    FEN (the tournament positions format; extra tab fields are ignored, since
    the clocks decide time advantage here). A second tab field that names
    where the opening came from (``fics=...``) is kept as its source."""
    openings = []
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        first = fields[0].strip()
        source = fields[1].strip() if len(fields) > 1 and "=" in fields[1] else ""
        opening = (Opening(first, (), source) if "|" in first
                   else Opening(None, tuple(first.split()), source))
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
    """Builds one side's two seats from a spec string: ``random[,sit=p]`` or
    an engine spec (``[hivemind|hypebeast|fsf,]key=value,...``)."""

    def __init__(self, text: str, default_binary: Path | None,
                 ort_threads: int | None, log_dir: Path | None):
        self.text = text
        self.ort_threads = ort_threads
        self.log_dir = log_dir
        self.search_timeout: float | None = None  # None: derived from the budget
        if text == "random" or text.startswith("random,"):
            options = dict(item.split("=", 1) for item in text.split(",")[1:])
            self.random_sit = float(options.get("sit", 0.0))
            self.spec = None
            self.name = options.get("name", "random")
            self.kind = "random"
        else:
            # --engine names a Hivemind build; the Fairy-Stockfish kinds take bin=.
            self.spec = EngineSpec.parse(text, default_binary)
            self.name = self.spec.name
            self.kind = self.spec.kind

    def describe(self) -> dict:
        return (self.spec.describe() if self.spec
                else {"kind": "random", "name": self.name, "random_sit": self.random_sit})

    def make(self, label: str, seed: int):
        if self.spec is None:
            return RandomPlayer(seed, self.random_sit, self.name)
        log = self.log_dir / f"{label}.log" if self.log_dir else None
        return make_seat(self.spec, ort_threads=self.ort_threads, log_path=log,
                         search_timeout=self.search_timeout)

    def files(self) -> dict:
        """Every file this side loads, with its SHA-256."""
        spec = self.spec
        if spec is None:
            return {}
        out = {"binary": file_record(spec.binary)}
        if spec.kind == "hivemind":
            out["model"] = file_record(spec.model)
            if spec.library_dir:
                out["runtime"] = [file_record(path) for path in sorted(
                    Path(spec.library_dir).glob("*onnxruntime*")) + sorted(
                    Path(spec.library_dir).glob("hivemind_ort*"))]
        else:
            out["net"] = file_record(spec.net)
        return out

    def identity(self) -> dict:
        """Start one seat and record what the engine says about itself. The
        Fairy-Stockfish kinds also answer one real search from the start
        position, which is where NNUE loading is confirmed."""
        if self.spec is None:
            return {}
        seat = self.make("probe", 0)
        try:
            info = seat.identity()
            if self.spec.kind != "hivemind":
                seat.new_game(0, chess.WHITE)
                view = SeatView(Bughouse(), 0, chess.WHITE, chess.WHITE, False,
                                (120_000,) * 4, 0, False)
                move = seat.decide(view)
                info["probe_search"] = {"position": seat.position_command(view),
                                        "go": self.spec.go_command, "bestmove": move,
                                        "nnue": list(seat.nnue_lines),
                                        "latency_ms": seat.game_stats["latency_ms"]}
            info["sends_seat"] = getattr(seat, "sends_seat", False)
            info["sends_clocks"] = getattr(seat, "sends_clocks", False)
            info["sent_options"] = dict(seat.sent_options)
            return info
        finally:
            seat.close()


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
    fixed_sample: bool = False
    openings_path: Path | None = None
    ort_threads: int | None = None
    argv: list[str] = field(default_factory=list)
    probe_engines: bool = True


def game_plan(config: MatchConfig) -> list[tuple[int, int, chess.Color, Opening]]:
    if config.fixed_sample and config.openings and config.pairs > len(config.openings):
        raise ValueError(f"--fixed-sample needs one opening per pair: {config.pairs} pairs, "
                         f"{len(config.openings)} openings")
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


# ----------------------------------------------------------------- manifest

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def file_record(path: Path | None) -> dict | None:
    if path is None:
        return None
    path = Path(path)
    if not path.exists():
        return {"path": str(path), "missing": True}
    resolved = path.resolve()
    return {"path": str(path), "resolved": str(resolved), "bytes": resolved.stat().st_size,
            "sha256": sha256_file(resolved)}


def _read(path: str) -> str | None:
    try:
        return Path(path).read_text()
    except OSError:
        return None


def suspend_clock() -> float:
    """Seconds the machine has spent suspended since boot (CLOCK_BOOTTIME
    counts suspend, CLOCK_MONOTONIC does not); 0 where unsupported. A
    difference of two readings is the suspend inside a run, which makes a
    laptop lid-close visible instead of looking like a hang."""
    try:
        return time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()
    except (AttributeError, OSError):
        return 0.0


ENV_RECORDED = ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "HIVEMIND_ORT_THREADS",
                "HIVEMIND_BIN", "HIVEMIND_MODEL", "HIVEMIND_LIB", "HYPEBEAST_HOME")


def environment() -> dict:
    """The host a run used: CPU, cores, memory and the CPU quota of the cgroup
    it runs in (scripts/ci.sh jobs are capped)."""
    cpuinfo = _read("/proc/cpuinfo") or ""
    model = next((line.split(":", 1)[1].strip() for line in cpuinfo.splitlines()
                  if line.startswith("model name")), platform.processor())
    cores = {(block.get("physical id"), block.get("core id"))
             for block in (dict(line.split(":", 1) for line in chunk.splitlines() if ":" in line)
                           for chunk in cpuinfo.split("\n\n"))
             if block.get("core id") is not None}
    memory = next((line.split()[1] for line in (_read("/proc/meminfo") or "").splitlines()
                   if line.startswith("MemTotal:")), None)
    cgroup = (_read("/proc/self/cgroup") or "").strip().split("::")[-1]
    cpu_max = _read(f"/sys/fs/cgroup{cgroup}/cpu.max") if cgroup else None
    try:
        affinity = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        affinity = None
    return {"hostname": socket.gethostname(), "platform": platform.platform(),
            "python": sys.version.split()[0], "python_chess": chess.__version__,
            "cpu_model": model, "logical_cpus": os.cpu_count(),
            "physical_cores": len(cores) or None, "cpu_affinity": affinity,
            "memory_kb": int(memory) if memory else None,
            "cgroup": cgroup or None, "cgroup_cpu_max": cpu_max.strip() if cpu_max else None,
            "load_average": list(os.getloadavg()) if hasattr(os, "getloadavg") else None,
            "env": {name: os.environ[name] for name in ENV_RECORDED if name in os.environ}}


def arena_source() -> dict:
    here = Path(__file__).resolve().parent
    files = {path.name: sha256_file(path) for path in sorted(here.glob("*.py"))}
    try:
        head = subprocess.run(["git", "-C", str(here), "rev-parse", "HEAD"], text=True,
                              capture_output=True, timeout=10).stdout.strip() or None
        dirty = subprocess.run(["git", "-C", str(here), "status", "--porcelain", "--", "."],
                               text=True, capture_output=True, timeout=10).stdout.split("\n")
        dirty = [line.strip() for line in dirty if line.strip()]
    except (OSError, subprocess.SubprocessError):
        head, dirty = None, None
    return {"git_head": head, "dirty": dirty, "files_sha256": files}


def build_manifest(config: MatchConfig, contender: PlayerFactory,
                   baseline: PlayerFactory) -> dict:
    sides = {}
    for role, factory in (("contender", contender), ("baseline", baseline)):
        sides[role] = {**factory.describe(), "spec": factory.text, "files": factory.files(),
                       "identity": factory.identity() if config.probe_engines else None}
    openings = None
    if config.openings_path:
        openings = {**file_record(config.openings_path), "count": len(config.openings or [])}
    return {
        "pins": {
            "contender": {k: sides["contender"][k] for k in ("kind", "name", "spec", "files")},
            "baseline": {k: sides["baseline"][k] for k in ("kind", "name", "spec", "files")},
            "openings": ({k: openings[k] for k in ("sha256", "count")} if openings
                         else {"random_plies_per_board": config.opening_plies}),
            "clock": vars(config.clock) | {"move_cost_ms": list(config.clock.move_cost_ms)},
            "seed": config.seed,
            "fixed_sample": config.fixed_sample,
        },
        "sides": sides,
        "openings": openings,
        "pairs": config.pairs,
        "concurrency": config.concurrency,
        "search_timeout_s": {"contender": contender.search_timeout,
                             "baseline": baseline.search_timeout,
                             "default": "3 x movetime + 15 s, or 120 s for a node budget"},
        "ort_threads": config.ort_threads,
        "statistics": ("fixed sample: no early stopping; pair-aware Wilson interval"
                       if config.fixed_sample else
                       "legacy: optional total-points paired SPRT stopping"),
        "sprt": list(config.sprt) if config.sprt else None,
        "arena": arena_source(),
        "environment": environment(),
        "argv": list(config.argv),
    }


def write_manifest(config: MatchConfig, contender: PlayerFactory,
                   baseline: PlayerFactory) -> dict:
    path = config.output / "manifest.json"
    manifest = build_manifest(config, contender, baseline)
    session = {"started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "argv": manifest["argv"],
               "environment": manifest["environment"], "arena": manifest["arena"],
               "identity": {role: manifest["sides"][role]["identity"]
                            for role in ("contender", "baseline")},
               "pairs": config.pairs}
    if path.exists():
        previous = json.loads(path.read_text())
        if previous.get("pins") != manifest["pins"]:
            raise RuntimeError(f"{path}: the engines, files, openings or clock changed since "
                               "this match started; start a new --output")
        manifest = previous
        manifest["pairs"] = config.pairs
    manifest.setdefault("sessions", []).append(session)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(path)
    return manifest


def run_match(config: MatchConfig, contender: PlayerFactory, baseline: PlayerFactory,
              log: Callable[[str], None] = print) -> dict:
    if config.fixed_sample and config.sprt:
        raise ValueError("--fixed-sample runs do not use SPRT stopping")
    config.output.mkdir(parents=True, exist_ok=True)
    results_path = config.output / "results.jsonl"
    summary_path = config.output / "summary.json"
    bpgn_path = config.output / "games.bpgn"
    replayed_path = config.output / "replayed_errors.jsonl"

    records: list[dict] = []
    if config.resume and results_path.exists():
        records = [json.loads(line) for line in results_path.read_text().splitlines() if line]
        voided = [r for r in records if r["result"]["termination"] == "error"]
        if voided:
            # Crashed games are replayed, never forgotten: keep them beside the
            # results and count them in the summary's reliability block.
            with replayed_path.open("a") as stream:
                for record in voided:
                    stream.write(json.dumps(record) + "\n")
        records = [r for r in records if r["result"]["termination"] != "error"]
        results_path.write_text("".join(json.dumps(r) + "\n" for r in records))
    elif results_path.exists():
        raise FileExistsError(f"{results_path} exists; pass --resume or pick a new --output")
    done = {r["game"] for r in records}
    replayed_errors = (len(replayed_path.read_text().splitlines())
                       if replayed_path.exists() else 0)
    game_plan(config)  # fail on a short opening file before starting engines
    manifest = write_manifest(config, contender, baseline)

    plan = [item for item in game_plan(config) if item[0] not in done]
    work: queue.Queue = queue.Queue()
    for item in plan:
        work.put(item)
    lock = threading.Lock()
    stop = threading.Event()
    started = time.monotonic()
    suspended_at_start = suspend_clock()
    meta = {"contender": contender.describe(), "baseline": baseline.describe(),
            "clock": vars(config.clock) | {"move_cost_ms": list(config.clock.move_cost_ms)},
            "pairs": config.pairs, "seed": config.seed,
            "fixed_sample_mode": config.fixed_sample,
            "openings_sha256": (manifest.get("openings") or {}).get("sha256")}

    def write_summary() -> dict:
        summary = {**meta, **summarize(records, config.sprt, declared_pairs=config.pairs,
                                       replayed_errors=replayed_errors),
                   "wall_seconds": time.monotonic() - started,
                   "suspended_seconds": round(suspend_clock() - suspended_at_start, 1)}
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
                    "seat_stats": {SEAT_NAMES[s]: dict(p.game_stats)
                                   for s, p in seating.items() if hasattr(p, "game_stats")},
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
                    if sprt and sprt["decision"] != "continue" and not config.fixed_sample:
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
