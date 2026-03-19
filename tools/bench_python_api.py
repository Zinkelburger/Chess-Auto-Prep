#!/usr/bin/env python3
"""
Benchmark: Pure Lichess Explorer API speed from Python.

Tests three modes:
  1) Sequential with 100ms politeness delay (matches production Python code)
  2) Sequential with 300ms politeness delay (matches production Flutter code)
  3) Sequential with NO delay (raw API latency)
  4) Sequential with session reuse vs fresh connections

Also simulates a mini-DFS to show total generation speed with Python's approach.
"""

import os
import time
import json
import urllib.parse
from dataclasses import dataclass, field
from typing import Optional

import requests
from dotenv import load_dotenv

load_dotenv()

TOKEN = os.getenv("LICHESS_API_TOKEN") or os.getenv("LICHESS")
# Explorer API doesn't require auth; sending an expired token causes 401s.
# Only include the header if explicitly requested.
USE_AUTH = os.getenv("BENCH_USE_AUTH", "").lower() in ("1", "true", "yes")
HEADERS = {"Authorization": f"Bearer {TOKEN}"} if (TOKEN and USE_AUTH) else {}

BASE_URL = "https://explorer.lichess.ovh/lichess"
PARAMS_BASE = {
    "variant": "standard",
    "speeds": "blitz,rapid,classical",
    "ratings": "1800,2000,2200,2500",
}

# Same FENs as the existing test — actual DFS positions from Benoni generation
TEST_FENS = [
    "rnbqkb1r/pp3ppp/3p1n2/2pP4/8/2N5/PP2PPPP/R1BQKBNR w KQkq - 0 6",
    "rnbqkb1r/pp3ppp/3p1n2/2pP4/4P3/2N5/PP3PPP/R1BQKBNR b KQkq - 0 6",
    "rnbqkb1r/pp3p1p/3p1np1/2pP4/4P3/2N5/PP3PPP/R1BQKBNR w KQkq - 0 7",
    "rnbqkb1r/pp3p1p/3p1np1/2pP4/4PP2/2N5/PP4PP/R1BQKBNR b KQkq - 0 7",
    "rnbqkb1r/1p3p1p/p2p1np1/2pP4/4PP2/2N5/PP4PP/R1BQKBNR w KQkq - 0 8",
    "rnbqkb1r/1p3p1p/p2p1np1/2pP4/4PP2/2N2N2/PP4PP/R1BQKB1R b KQkq - 1 8",
    "rnbqk2r/1p3pbp/p2p1np1/2pP4/4PP2/2N2N2/PP4PP/R1BQKB1R w KQkq - 2 9",
    "rnbqk2r/1p3pbp/p2p1np1/2pP4/P3PP2/2N2N2/1P4PP/R1BQKB1R b KQkq - 0 9",
    # Additional deeper positions
    "rnbq1rk1/1p3pbp/p2p1np1/2pP4/P3PP2/2N2N2/1P4PP/R1BQKB1R w KQ - 1 10",
    "rnbq1rk1/1p3pbp/p2p1np1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R b KQ - 2 10",
    "r1bq1rk1/1p3pbp/p1np1np1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R w KQ - 3 11",
    "r1bq1rk1/1p2npbp/p2p2p1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R w KQ - 1 11",
]


@dataclass
class RequestResult:
    elapsed_ms: float
    status: int
    num_moves: int
    total_games: int
    fen_short: str


@dataclass
class BenchmarkRun:
    label: str
    results: list = field(default_factory=list)
    wall_ms: float = 0.0

    @property
    def avg_ms(self) -> float:
        if not self.results:
            return 0.0
        return sum(r.elapsed_ms for r in self.results) / len(self.results)

    @property
    def total_api_ms(self) -> float:
        return sum(r.elapsed_ms for r in self.results)

    @property
    def min_ms(self) -> float:
        return min(r.elapsed_ms for r in self.results) if self.results else 0.0

    @property
    def max_ms(self) -> float:
        return max(r.elapsed_ms for r in self.results) if self.results else 0.0


def build_url(fen: str) -> str:
    params = {**PARAMS_BASE, "fen": fen}
    return f"{BASE_URL}?{urllib.parse.urlencode(params)}"


def run_sequential(
    fens: list,
    delay_ms: float,
    label: str,
    use_session: bool = True,
) -> BenchmarkRun:
    run = BenchmarkRun(label=label)
    session = requests.Session() if use_session else None

    wall_start = time.perf_counter()
    for i, fen in enumerate(fens):
        if delay_ms > 0:
            time.sleep(delay_ms / 1000.0)

        url = build_url(fen)
        t0 = time.perf_counter()
        if session:
            resp = session.get(url, headers=HEADERS)
        else:
            resp = requests.get(url, headers=HEADERS)
        elapsed = (time.perf_counter() - t0) * 1000

        data = resp.json() if resp.status_code == 200 else {}
        moves = data.get("moves", [])
        total = sum(m.get("white", 0) + m.get("draws", 0) + m.get("black", 0) for m in moves)

        run.results.append(RequestResult(
            elapsed_ms=elapsed,
            status=resp.status_code,
            num_moves=len(moves),
            total_games=total,
            fen_short=fen.split(" ")[0][:25],
        ))
        print(f"  [{i+1:2d}/{len(fens)}] {elapsed:7.1f}ms  HTTP {resp.status_code}  "
              f"{len(moves):2d} moves  {total:>8d} games")

    run.wall_ms = (time.perf_counter() - wall_start) * 1000
    if session:
        session.close()
    return run


def run_mini_dfs(delay_ms: float, label: str) -> BenchmarkRun:
    """Simulate a small DFS tree similar to what the Flutter isolate does."""
    run = BenchmarkRun(label=label)
    session = requests.Session()

    start_fen = "rnbqkb1r/pp3ppp/3p1n2/2pP4/8/2N5/PP2PPPP/R1BQKBNR w KQkq - 0 6"
    import chess
    visited = set()
    stack = [(start_fen, 0)]
    max_depth = 6
    max_requests = 30

    wall_start = time.perf_counter()
    req_count = 0

    while stack and req_count < max_requests:
        fen, depth = stack.pop()
        if fen in visited or depth > max_depth:
            continue
        visited.add(fen)

        if delay_ms > 0:
            time.sleep(delay_ms / 1000.0)

        url = build_url(fen)
        t0 = time.perf_counter()
        resp = session.get(url, headers=HEADERS)
        elapsed = (time.perf_counter() - t0) * 1000
        req_count += 1

        data = resp.json() if resp.status_code == 200 else {}
        moves_data = data.get("moves", [])
        total = sum(m.get("white", 0) + m.get("draws", 0) + m.get("black", 0) for m in moves_data)

        run.results.append(RequestResult(
            elapsed_ms=elapsed,
            status=resp.status_code,
            num_moves=len(moves_data),
            total_games=total,
            fen_short=fen.split(" ")[0][:25],
        ))

        board = chess.Board(fen)
        is_white = board.turn == chess.WHITE

        if moves_data:
            if is_white:
                # Pick best by win rate (simulate "our move")
                best = max(moves_data, key=lambda m: m.get("white", 0) / max(1, m["white"] + m["draws"] + m["black"]))
                try:
                    board.push_san(best["san"])
                    stack.append((board.fen(), depth + 1))
                except Exception:
                    pass
            else:
                # Branch on opponent replies (simulate opponent moves)
                for m in moves_data[:5]:
                    mg = m["white"] + m["draws"] + m["black"]
                    if total > 0 and mg / total >= 0.01:
                        try:
                            b = chess.Board(fen)
                            b.push_san(m["san"])
                            stack.append((b.fen(), depth + 1))
                        except Exception:
                            pass

        print(f"  [{req_count:2d}] d={depth} {elapsed:7.1f}ms  "
              f"{len(moves_data):2d} moves  {total:>8d} games  {'W' if is_white else 'B'}")

    run.wall_ms = (time.perf_counter() - wall_start) * 1000
    session.close()
    return run


def print_summary(runs: list):
    print(f"\n{'='*80}")
    print(f"  BENCHMARK SUMMARY")
    print(f"{'='*80}")
    print(f"  {'Test':<45s} {'Reqs':>5s} {'Avg':>8s} {'Min':>8s} {'Max':>8s} {'Wall':>10s}")
    print(f"  {'─'*45} {'─'*5} {'─'*8} {'─'*8} {'─'*8} {'─'*10}")
    for run in runs:
        n = len(run.results)
        print(f"  {run.label:<45s} {n:>5d} {run.avg_ms:>7.0f}ms {run.min_ms:>7.0f}ms "
              f"{run.max_ms:>7.0f}ms {run.wall_ms:>9.0f}ms")

    print(f"\n  Auth token: {'YES' if TOKEN else 'NO'}")
    print(f"  Note: Wall time includes delays between requests.")
    print(f"{'='*80}")


def main():
    print("=" * 80)
    print("  PYTHON LICHESS EXPLORER API BENCHMARK")
    print("=" * 80)
    print(f"  Token: {'present' if TOKEN else 'MISSING'}")
    print(f"  FENs: {len(TEST_FENS)}")
    print()

    runs = []

    # Test 1: No delay (raw API latency)
    print("─" * 80)
    print("  Test 1: No delay, persistent session (raw API latency)")
    print("─" * 80)
    runs.append(run_sequential(TEST_FENS, delay_ms=0, label="No delay (raw API latency)"))

    # Test 2: 100ms delay (Python production)
    print("\n" + "─" * 80)
    print("  Test 2: 100ms delay, persistent session (Python production)")
    print("─" * 80)
    runs.append(run_sequential(TEST_FENS, delay_ms=100, label="100ms delay (Python production)"))

    # Test 3: 300ms delay (Flutter production)
    print("\n" + "─" * 80)
    print("  Test 3: 300ms delay, persistent session (Flutter equivalent)")
    print("─" * 80)
    runs.append(run_sequential(TEST_FENS, delay_ms=300, label="300ms delay (Flutter equivalent)"))

    # Test 4: No session (fresh TCP per request)
    print("\n" + "─" * 80)
    print("  Test 4: No delay, NO session (fresh TCP per request)")
    print("─" * 80)
    runs.append(run_sequential(TEST_FENS, delay_ms=0, label="No delay, no session", use_session=False))

    # Test 5: Mini DFS with 100ms (Python-style)
    print("\n" + "─" * 80)
    print("  Test 5: Mini DFS, 100ms delay (Python production DFS)")
    print("─" * 80)
    runs.append(run_mini_dfs(delay_ms=100, label="Mini DFS, 100ms delay (Python)"))

    # Test 6: Mini DFS with 300ms (Flutter-style)
    print("\n" + "─" * 80)
    print("  Test 6: Mini DFS, 300ms delay (Flutter-equivalent DFS)")
    print("─" * 80)
    runs.append(run_mini_dfs(delay_ms=300, label="Mini DFS, 300ms delay (Flutter)"))

    print_summary(runs)


if __name__ == "__main__":
    main()
