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

from .match import PlayerFactory, default_ort_threads, environment, file_record, load_openings
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
        ort_threads: int | None, log=print) -> dict:
    factory = PlayerFactory(spec_text, None, ort_threads, None)
    if factory.kind != "hivemind" or factory.spec.nodes is None:
        raise ValueError("the preflight measures a Hivemind spec with nodes=")
    spec = factory.spec
    work = samples(positions)
    if not work:
        raise ValueError(f"{positions}: no positions with a legal move")
    seat = factory.make("preflight", 0)
    started = time.time()
    phases: dict[str, dict] = {}
    try:
        identity = seat.identity()

        def search(sample, budget_spec) -> dict:
            label, game, board, color = sample
            seat.new_game(board, color)
            seat.spec = budget_spec
            view = SeatView(game.copy(), board, color, seat_team(board, color), False,
                            (120_000,) * 4, 0, False)
            before_nodes = seat.nodes
            move = seat.decide(view)
            return {"position": label, "latency_ms": seat.game_stats["latency_ms"][-1],
                    "nodes": seat.nodes - before_nodes, "move": move,
                    "legal": move is None or game.is_legal(board, move)}

        warm = [search(work[i % len(work)], spec) for i in range(warmup)]
        budgets = [(f"nodes={spec.nodes}", spec, None)] + [
            (f"movetime={m}", dataclasses.replace(spec, nodes=None, movetime_ms=m), m)
            for m in movetimes]
        for label, budget_spec, movetime in budgets:
            rows = [search(sample, budget_spec) for sample in work]
            latencies = [row["latency_ms"] for row in rows]
            phase = {"go": budget_spec.go_command, "searches": rows,
                     "latency": latency_summary(latencies),
                     "nodes": latency_summary([float(row["nodes"]) for row in rows]),
                     "illegal_answers": sum(1 for row in rows if not row["legal"])}
            if movetime is not None:
                phase["overruns"] = sum(1 for x in latencies if x > tolerance_ms(movetime))
                phase["honoured"] = honoured(movetime, latencies)
            phases[label] = phase
            summary = phase["latency"]
            log(f"{label:>14}: mean {summary['mean_ms']:.0f} ms, median {summary['median_ms']:.0f}, "
                f"p95 {summary['p95_ms']:.0f}, max {summary['max_ms']:.0f}, "
                f"total {summary['total_ms'] / 1000:.1f} s"
                + (f", overruns {phase['overruns']}/{len(rows)}, honoured {phase['honoured']}"
                   if movetime is not None else ""))
    finally:
        seat.close()

    node_phase = phases[f"nodes={spec.nodes}"]
    mean = node_phase["latency"]["mean_ms"]
    reliable = bool(movetimes) and all(phases[f"movetime={m}"]["honoured"] for m in movetimes)
    matched = max(1, round(mean))
    recommendation = (
        {"mode": "same movetime for all arms",
         "hivemind": f"hivemind,movetime={matched}",
         "fsf_hypebeast_movetime_ms": matched}
        if reliable else
        {"mode": "matched mean compute",
         "hivemind": f"hivemind,nodes={spec.nodes}",
         "fsf_hypebeast_movetime_ms": matched,
         "note": "Hivemind keeps its node budget; the Fairy-Stockfish arms get its mean "
                 "preflight latency as TOTAL movetime"})
    return {
        "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(started)),
        "wall_seconds": time.time() - started,
        "concurrency": 1,
        "spec": spec_text,
        "engine": {**factory.describe(), "files": factory.files(), "identity": identity,
                   "ort_threads_env": ort_threads},
        "hivemind_checkout": checkout_identity(HIVEMIND_CHECKOUT),
        "positions": {**file_record(positions), "searches_per_phase": len(work)},
        "warmup": {"searches": warmup, "latency": latency_summary(
            [row["latency_ms"] for row in warm])},
        "environment": environment(),
        "honour_rule": "median >= 0.8 M and p95 <= M + max(0.1 M, 25 ms)",
        "phases": phases,
        "movetime_reliably_honoured": reliable,
        "recommendation": recommendation,
    }


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
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    movetimes = [int(m) for m in args.movetimes.split(",") if m.strip()]
    try:
        report = run(args.spec, args.positions, movetimes, args.warmup, args.ort_threads)
    except Exception as error:
        print(f"preflight: {error}", file=sys.stderr)
        return 1
    report["argv"] = ["python3", "-m", "bughouse_arena.preflight",
                      *(argv if argv is not None else sys.argv[1:])]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    rec = report["recommendation"]
    print(f"movetime reliably honoured: {report['movetime_reliably_honoured']}\n"
          f"recommendation: {rec['mode']}: {rec['hivemind']} vs "
          f"fsf/hypebeast movetime={rec['fsf_hypebeast_movetime_ms']}\n"
          f"report: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
