#!/usr/bin/env python3
"""
Quick diagnostic: measure Lichess Explorer API latency.

Reproduces the exact same queries the Dart repertoire generator makes,
with the same parameters, so we can isolate API latency from Dart overhead.

Usage:
    python3 tools/test_lichess_api.py
    python3 tools/test_lichess_api.py --parallel   # test parallel fetching
"""

import argparse
import asyncio
import time
import urllib.parse
from dataclasses import dataclass

import aiohttp
import requests


BASE_URL = "https://explorer.lichess.ovh/lichess"
PARAMS = {
    "variant": "standard",
    "speeds": "blitz,rapid,classical",
    "ratings": "1800,2000,2200,2500",
}

# FENs from the user's actual generation log, in DFS order.
# First few are popular (should be fast), rest are progressively rarer.
TEST_FENS = [
    # DB#1 root
    "rnbqkb1r/pp3ppp/3p1n2/2pP4/8/2N5/PP2PPPP/R1BQKBNR w KQkq - 0 6",
    # DB#2 after e4
    "rnbqkb1r/pp3ppp/3p1n2/2pP4/4P3/2N5/PP3PPP/R1BQKBNR b KQkq - 0 6",
    # DB#3 after g6
    "rnbqkb1r/pp3p1p/3p1np1/2pP4/4P3/2N5/PP3PPP/R1BQKBNR w KQkq - 0 7",
    # DB#4 after f4 (this is where latency started in the log)
    "rnbqkb1r/pp3p1p/3p1np1/2pP4/4PP2/2N5/PP4PP/R1BQKBNR b KQkq - 0 7",
    # DB#5 after a6
    "rnbqkb1r/1p3p1p/p2p1np1/2pP4/4PP2/2N5/PP4PP/R1BQKBNR w KQkq - 0 8",
    # DB#6 after Nf3
    "rnbqkb1r/1p3p1p/p2p1np1/2pP4/4PP2/2N2N2/PP4PP/R1BQKB1R b KQkq - 1 8",
    # DB#7 after Bg7
    "rnbqk2r/1p3pbp/p2p1np1/2pP4/4PP2/2N2N2/PP4PP/R1BQKB1R w KQkq - 2 9",
    # DB#8 after a4
    "rnbqk2r/1p3pbp/p2p1np1/2pP4/P3PP2/2N2N2/1P4PP/R1BQKB1R b KQkq - 0 9",
]

# Extra FENs at various depths for parallel test
PARALLEL_TEST_FENS = [
    "rnbqk2r/1p3pbp/p2p1np1/2pP4/4PP2/2N2N2/PP4PP/R1BQKB1R w KQkq - 2 9",
    "rnbq1rk1/1p3pbp/p2p1np1/2pP4/P3PP2/2N2N2/1P4PP/R1BQKB1R w KQ - 1 10",
    "rnbq1rk1/1p3pbp/p2p1np1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R b KQ - 2 10",
    "r1bq1rk1/1p3pbp/p1np1np1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R w KQ - 3 11",
    "r1bq1rk1/1p2npbp/p2p2p1/2pP4/P3PP2/2NB1N2/1P4PP/R1BQK2R w KQ - 1 11",
]


def build_url(fen: str) -> str:
    params = {**PARAMS, "fen": fen}
    return f"{BASE_URL}?{urllib.parse.urlencode(params)}"


@dataclass
class QueryResult:
    fen_short: str
    status: int
    elapsed_ms: float
    num_moves: int
    total_games: int


def query_sequential(fens: list[str], session: requests.Session | None = None) -> list[QueryResult]:
    results = []
    use_session = session or requests.Session()
    for fen in fens:
        url = build_url(fen)
        t0 = time.perf_counter()
        resp = use_session.get(url)
        elapsed = (time.perf_counter() - t0) * 1000

        data = resp.json() if resp.status_code == 200 else {}
        moves = data.get("moves", [])
        total = sum(m.get("white", 0) + m.get("draws", 0) + m.get("black", 0) for m in moves)

        fen_short = fen.split(" ")[0][:30]
        results.append(QueryResult(fen_short, resp.status_code, elapsed, len(moves), total))

    if session is None:
        use_session.close()
    return results


async def query_parallel(fens: list[str]) -> list[QueryResult]:
    results: list[QueryResult] = []
    async with aiohttp.ClientSession() as session:
        t0 = time.perf_counter()

        async def fetch(fen: str) -> QueryResult:
            url = build_url(fen)
            ft0 = time.perf_counter()
            async with session.get(url) as resp:
                data = await resp.json(content_type=None)
                elapsed = (time.perf_counter() - ft0) * 1000
                moves = data.get("moves", [])
                total = sum(
                    m.get("white", 0) + m.get("draws", 0) + m.get("black", 0)
                    for m in moves
                )
                fen_short = fen.split(" ")[0][:30]
                return QueryResult(fen_short, resp.status, elapsed, len(moves), total)

        tasks = [fetch(f) for f in fens]
        results = await asyncio.gather(*tasks)
        wall = (time.perf_counter() - t0) * 1000

    return list(results), wall


def print_results(label: str, results: list[QueryResult], wall_ms: float | None = None):
    print(f"\n{'='*70}")
    print(f"  {label}")
    print(f"{'='*70}")
    total_ms = 0
    for i, r in enumerate(results):
        status = "OK" if r.status == 200 else f"HTTP {r.status}"
        print(f"  [{i+1:2d}] {r.elapsed_ms:7.0f}ms  {status}  "
              f"{r.num_moves:2d} moves  {r.total_games:>8d} games  {r.fen_short}...")
        total_ms += r.elapsed_ms

    print(f"  {'─'*66}")
    print(f"  Sum of individual latencies: {total_ms:.0f}ms")
    if wall_ms is not None:
        print(f"  Wall-clock time (parallel):  {wall_ms:.0f}ms")
        print(f"  Speedup:                     {total_ms / wall_ms:.1f}x")
    else:
        print(f"  Wall-clock time (sequential): {total_ms:.0f}ms")


def main():
    parser = argparse.ArgumentParser(description="Lichess Explorer API latency test")
    parser.add_argument("--parallel", action="store_true",
                        help="Also test parallel fetching")
    parser.add_argument("--no-session", action="store_true",
                        help="Use a fresh connection per request (no keep-alive)")
    args = parser.parse_args()

    print("\nLichess Explorer API Latency Diagnostic")
    print("Reproducing the same queries as the Dart repertoire generator.\n")

    # --- Sequential with session (mimics Dart's persistent http.Client) ---
    print("Testing sequential with persistent session (= Dart http.Client)...")
    session = requests.Session()
    results = query_sequential(TEST_FENS, session)
    print_results("Sequential (persistent session — same as Dart)", results)
    session.close()

    if args.no_session:
        print("\nTesting sequential WITHOUT session (fresh TCP per request)...")
        results = query_sequential(TEST_FENS, session=None)
        print_results("Sequential (no session — fresh TCP each time)", results)

    if args.parallel:
        print("\nTesting parallel fetch of 5 sibling FENs...")
        par_results, wall = asyncio.run(query_parallel(PARALLEL_TEST_FENS))
        print_results("Parallel (5 sibling positions)", par_results, wall_ms=wall)

    print("\n" + "="*70)
    print("  CONCLUSION")
    print("="*70)
    avg = sum(r.elapsed_ms for r in results[3:]) / max(1, len(results[3:]))
    print(f"  Avg latency for non-cached positions: {avg:.0f}ms")
    if avg > 2000:
        print("  The Lichess Explorer API itself is the bottleneck.")
        print("  This is NOT a Dart/HTTP-client issue.")
        print("  Parallelizing sibling requests is the main optimization.\n")
    else:
        print("  API seems fast — bottleneck may be elsewhere.\n")


if __name__ == "__main__":
    main()
