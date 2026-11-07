"""Hivemind latency preflight: what does its node budget cost in wall time, and
does it honour ``go movetime``?

PLAN rev 7 section 8: before measured games, search fixed representative
positions with Hivemind at its node budget (400) and with a few movetimes, one
process, nothing else running in it (concurrency 1). If every movetime is
honoured, all arms can share one movetime. Otherwise Hivemind keeps its node
budget and Fairy-Stockfish/HypeBeast get the measured mean latency as their
TOTAL movetime ("matched mean compute"). Either way the recommendation uses
the mean latency measured here, never an old NPS figure.

Run it under the same limits as the matches (scripts/ci.sh with -- ...), since
the job's CPU quota changes the latency. From ``tools/``::

    python3 -m bughouse_arena.preflight --output ~/.local/share/chess-prep/bughouse-arena/preflight.json

Honoured means, for each movetime M: median latency >= 0.8 M and p95 latency
<= M + max(0.1 M, 25 ms). An overrun is one search over that bound.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import subprocess
import sys
import time
from pathlib import Path

import chess

from .match import (PlayerFactory, default_ort_threads, environment, file_record,
                    load_openings, suspend_clock)
from .players import EngineError
from .referee import BOARDS, seat_team
from .sim import SeatView
from .stats import latency_summary

HERE = Path(__file__).resolve().parent
DEFAULT_POSITIONS = HERE / "opening_sets" / "preflight.txt"
HIVEMIND_CHECKOUT = Path.home() / "Projects" / "hivemind"


def tolerance_ms(movetime: int) -> float:
    return movetime + max(0.1 * movetime, 25.0)


def honoured(movetime: int, latencies: list[float]) -> bool:
    summary = latency_summary(latencies)
    if not summary["count"]:
        return False
    return summary["median_ms"] >= 0.8 * movetime and summary["p95_ms"] <= tolerance_ms(movetime)


def checkout_identity(path: Path) -> dict | None:
    """The local Hivemind source checkout, which need not match the binary."""
    if not (path / ".git").exists():
        return None

    def git(*args: str) -> str:
        return subprocess.run(["git", "-C", str(path), *args], text=True,
                              capture_output=True, timeout=20).stdout.strip()

    return {"path": str(path), "head": git("rev-parse", "HEAD"),
            "describe": git("describe", "--tags", "--always", "--dirty"),
            "branch": git("branch", "--show-current"),
            "dirty": [line for line in git("status", "--porcelain").splitlines() if line]}


def samples(positions_path: Path) -> list[tuple]:
    """(label, game, board, colour) for every seat on turn with a legal move."""
    out = []
    for number, opening in enumerate(load_openings(positions_path)):
        game = opening.build()
        for board in BOARDS:
            if game.has_legal_move(board):
                out.append((f"{number}{'AB'[board]}", game, board, game.turn(board)))
    return out


def run(spec_text: str, positions: Path, movetimes: list[int], warmup: int,
        ort_threads: int | None, log=print, search_timeout: float | None = None,
        max_seconds: float | None = 1200.0, engine_log: Path | None = None,
        checkpoint=None) -> dict:
    """Measure, never hang: every search has a hard wall-clock deadline (the
    seat's, or ``search_timeout``); a search that misses it is recorded as a
    timeout (an overrun and a failure), the engine is killed and a fresh one
    started. Once ``max_seconds`` have passed no new search starts and the
    report says it is truncated. ``checkpoint(report)`` is called after
    every phase so a killed run still leaves its data."""
    factory = PlayerFactory(spec_text, None, ort_threads, None)
    if factory.kind != "hivemind" or factory.spec.nodes is None:
        raise ValueError("the preflight measures a Hivemind spec with nodes=")
    factory.search_timeout = search_timeout
    if engine_log:
        factory.log_dir = engine_log.parent
    spec = factory.spec
    work = samples(positions)
    if not work:
        raise ValueError(f"{positions}: no positions with a legal move")
    started = time.time()
    clock = time.monotonic()
    suspended_at_start = suspend_clock()
    phases: dict[str, dict] = {}
    state = {"seat": None, "restarts": 0, "identity": None}

    def seat():
        if state["seat"] is None:
            state["seat"] = factory.make(engine_log.stem if engine_log else "preflight", 0)
            if state["identity"] is None:
                state["identity"] = state["seat"].identity()
        return state["seat"]

    def search(sample, budget_spec) -> dict:
        label, game, board, color = sample
        player = seat()
        row = {"position": label, "go": budget_spec.go_command}
        searched = time.monotonic()
        try:
            player.new_game(board, color)
            player.spec = budget_spec
            view = SeatView(game.copy(), board, color, seat_team(board, color), False,
                            (120_000,) * 4, 0, False)
            before_nodes = player.nodes
            move = player.decide(view)
        except EngineError as error:
            # Timeout or crash: a failed search, not a skipped one. Kill the
            # engine and carry on with a fresh process.
            row.update(timeout=True, error=str(error),
                       latency_ms=round((time.monotonic() - searched) * 1000, 1), nodes=None,
                       move=None, legal=False)
            log(f"  {label} {budget_spec.go_command}: FAILED after {row['latency_ms'] / 1000:.1f}s: "
                f"{error}")
            player.close()
            state["seat"] = None
            state["restarts"] += 1
            return row
        row.update(timeout=False, latency_ms=player.game_stats["latency_ms"][-1],
                   nodes=player.nodes - before_nodes, move=move,
                   legal=move is None or game.is_legal(board, move))
        return row

    def out_of_time() -> bool:
        return max_seconds is not None and time.monotonic() - clock > max_seconds

    report: dict = {}

    def assemble(complete: bool) -> dict:
        node_phase = phases.get(f"nodes={spec.nodes}")
        measured = [m for m in movetimes if f"movetime={m}" in phases]
        reliable = (complete and bool(movetimes)
                    and all(phases[f"movetime={m}"]["honoured"] for m in measured))
        recommendation = None
        if node_phase and node_phase["latency"]["mean_ms"] is not None:
            matched = max(1, round(node_phase["latency"]["mean_ms"]))
            recommendation = (
                {"mode": "same movetime for all arms",
                 "hivemind": f"hivemind,movetime={matched}",
                 "fsf_hypebeast_movetime_ms": matched}
                if reliable else
                {"mode": "matched mean compute",
                 "hivemind": f"hivemind,nodes={spec.nodes}",
                 "fsf_hypebeast_movetime_ms": matched,
                 "note": "Hivemind keeps its node budget; the Fairy-Stockfish arms get its "
                         "mean preflight latency (successful searches) as TOTAL movetime"})
        report.update({
            "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(started)),
            "wall_seconds": time.time() - started,
            "suspended_seconds": round(suspend_clock() - suspended_at_start, 1),
            "complete": complete,
            "truncated_by_max_seconds": out_of_time(),
            "max_seconds": max_seconds,
            "concurrency": 1,
            "spec": spec_text,
            "engine": {**factory.describe(), "files": factory.files(),
                       "identity": state["identity"], "ort_threads_env": ort_threads,
                       "search_timeout_s": search_timeout,
                       "restarts_after_failure": state["restarts"]},
            "hivemind_checkout": checkout_identity(HIVEMIND_CHECKOUT),
            "positions": {**file_record(positions), "searches_per_phase": len(work)},
            "warmup": {"searches": warmup, "latency": latency_summary(
                [row["latency_ms"] for row in warm if not row["timeout"]]),
                "failures": sum(1 for row in warm if row["timeout"])},
            "environment": environment(),
            "honour_rule": "median >= 0.8 M and p95 <= M + max(0.1 M, 25 ms); "
                           "a timed-out search counts as an overrun and a failure",
            "phases": phases,
            "movetime_reliably_honoured": reliable,
            "recommendation": recommendation,
        })
        return report

    warm: list[dict] = []
    try:
        for i in range(warmup):
            if out_of_time():
                break
            warm.append(search(work[i % len(work)], spec))
        budgets = [(f"nodes={spec.nodes}", spec, None)] + [
            (f"movetime={m}", dataclasses.replace(spec, nodes=None, movetime_ms=m), m)
            for m in movetimes]
        for label, budget_spec, movetime in budgets:
            rows = []
            for sample in work:
                if out_of_time():
                    break
                rows.append(search(sample, budget_spec))
            if not rows:
                break
            ok = [row for row in rows if not row["timeout"]]
            latencies = [row["latency_ms"] for row in ok]
            phase = {"go": budget_spec.go_command, "searches": rows,
                     "failures": len(rows) - len(ok),
                     "latency": latency_summary(latencies),
                     "nodes": latency_summary([float(row["nodes"]) for row in ok]),
                     "illegal_answers": sum(1 for row in ok if not row["legal"]),
                     "complete": len(rows) == len(work)}
            if movetime is not None:
                phase["overruns"] = (sum(1 for x in latencies if x > tolerance_ms(movetime))
                                     + phase["failures"])
                phase["honoured"] = (phase["failures"] == 0 and phase["complete"]
                                     and honoured(movetime, latencies))
            phases[label] = phase
            summary = phase["latency"]
            if summary["count"]:
                log(f"{label:>14}: mean {summary['mean_ms']:.0f} ms, median "
                    f"{summary['median_ms']:.0f}, p95 {summary['p95_ms']:.0f}, max "
                    f"{summary['max_ms']:.0f}, total {summary['total_ms'] / 1000:.1f} s, "
                    f"failures {phase['failures']}/{len(rows)}"
                    + (f", overruns {phase['overruns']}, honoured {phase['honoured']}"
                       if movetime is not None else ""))
            else:
                log(f"{label:>14}: every search failed ({len(rows)})")
            if checkpoint:
                checkpoint(assemble(False))
    finally:
        if state["seat"] is not None:
            state["seat"].close()
    complete = (not out_of_time() and len(phases) == len(movetimes) + 1
                and all(phase["complete"] for phase in phases.values()))
    return assemble(complete)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m bughouse_arena.preflight",
                                     description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--spec", default="hivemind,nodes=400",
                        help="Hivemind engine spec (default hivemind,nodes=400)")
    parser.add_argument("--positions", type=Path, default=DEFAULT_POSITIONS)
    parser.add_argument("--movetimes", default="100,250,500,1000",
                        help="comma-separated ms to test (default 100,250,500,1000)")
    parser.add_argument("--warmup", type=int, default=6, help="searches discarded first")
    parser.add_argument("--ort-threads", type=int, default=default_ort_threads(1),
                        help="HIVEMIND_ORT_THREADS, as a --concurrency 1 match sets it")
    parser.add_argument("--search-timeout", type=float, default=60.0,
                        help="hard wall-clock seconds per search; a miss is a recorded failure "
                             "and the engine is restarted (default 60)")
    parser.add_argument("--max-minutes", type=float, default=20.0,
                        help="start no search after this many minutes (default 20)")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    movetimes = [int(m) for m in args.movetimes.split(",") if m.strip()]
    argv_record = ["python3", "-m", "bughouse_arena.preflight",
                   *(argv if argv is not None else sys.argv[1:])]
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def write(report: dict) -> None:
        report["argv"] = argv_record
        temporary = args.output.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(args.output)

    def log(text: str) -> None:
        print(text, flush=True)

    try:
        report = run(args.spec, args.positions, movetimes, args.warmup, args.ort_threads,
                     log=log, search_timeout=args.search_timeout,
                     max_seconds=args.max_minutes * 60,
                     engine_log=args.output.with_suffix(".uci.log"), checkpoint=write)
    except Exception as error:
        print(f"preflight: {error}", file=sys.stderr, flush=True)
        return 1
    write(report)
    rec = report["recommendation"]
    print(f"complete: {report['complete']}  movetime reliably honoured: "
          f"{report['movetime_reliably_honoured']}", flush=True)
    if rec:
        print(f"recommendation: {rec['mode']}: {rec['hivemind']} vs "
              f"fsf/hypebeast movetime={rec['fsf_hypebeast_movetime_ms']}", flush=True)
    print(f"report: {args.output}\nprotocol log: {args.output.with_suffix('.uci.log')}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
