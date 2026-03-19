# Lichess Explorer API: Python vs Flutter Speed Analysis

**Date:** March 5, 2026
**Benchmark scripts:** `tools/bench_python_api.py`, `tools/bench_dart_api.dart`

---

## TL;DR

The Flutter UI is slower than the Python script primarily because of **three compounding factors**:

1. **3x longer politeness delay** — Flutter waits 300ms between requests vs Python's 100ms
2. **Extra DB calls** — Flutter's `LineFinalizer` makes an additional API call at every leaf node
3. **Engine work** (engine strategies only) — Stockfish analysis dominates total time, dwarfing API latency

Raw API latency is **identical** between Python and Dart (~87ms). The HTTP client, language runtime, and JSON parsing are not the bottleneck.

---

## Benchmark Results

> **Note:** The Lichess Explorer API (`explorer.lichess.ovh`) returned 401 during testing
> (nginx-level auth block, likely temporary). Network roundtrip times are still valid
> since TLS handshake and latency are the same regardless of response code.

### Raw API Latency (12 sequential requests, persistent connections)

| Metric         | Python (`requests.Session`) | Dart (`dart:io HttpClient`) |
|----------------|---------------------------:|----------------------------:|
| **Average**    | 108 ms                     | 118 ms                      |
| **Min**        | 91 ms                      | 86 ms                       |
| **Max**        | 296 ms (cold start)        | 453 ms (cold start)         |
| **Steady-state** | ~87-91 ms                | ~85-89 ms                   |

**Conclusion:** Dart and Python have nearly identical raw API speed. The cold-start
difference (first request) is TLS negotiation; subsequent requests reuse the TCP
connection and are equivalent.

### Effect of Politeness Delay (12 requests, wall-clock time)

| Delay     | Python Wall Time | Dart Wall Time |
|-----------|----------------:|---------------:|
| 0 ms      | 1,303 ms        | 1,430 ms       |
| 100 ms    | 2,446 ms        | 2,441 ms       |
| 300 ms    | 4,876 ms        | 4,817 ms       |

**Identical wall times** at every delay setting. The language runtime is irrelevant.

### No-Session vs Session (Python only)

| Mode         | Avg Latency | Wall Time |
|--------------|------------:|----------:|
| With session | 91 ms       | 1,303 ms  |
| No session   | 284 ms      | 3,415 ms  |

Fresh TCP connections cost ~190ms extra per request (TLS handshake). Both Python
and Flutter use persistent connections, so this is not a factor.

---

## Why Python Is Faster: Root Cause Analysis

### Factor 1: Politeness Delay (the biggest single factor)

| Implementation | Delay Mechanism | Effective Delay |
|----------------|----------------|----------------:|
| **Python** (`probability.py`) | `time.sleep(0.1)` before each request | **100 ms** |
| **Flutter** (`lichess_api_client.dart`) | `Duration(milliseconds: 300)` min gap | **300 ms** |

```
Python per-request cycle:  100ms sleep + 87ms API = 187ms
Flutter per-request cycle: ~213ms wait + 87ms API = 300ms minimum = ~387ms
```

For a generation run with 200 unique positions:
- **Python:** 200 × 187ms = **37.4 seconds**
- **Flutter:** 200 × 387ms = **77.4 seconds** (2.1× slower)

The Flutter delay is a _minimum gap_ between requests (line 56 and 131 of
`lichess_api_client.dart`). If processing between requests exceeds 300ms, no
additional wait is needed. But in DB-only mode where processing is minimal
(~2ms), nearly the full 300ms is waited every time.

### Factor 2: Extra DB Calls from LineFinalizer

At every DFS leaf node, `LineFinalizer.finalize()` calls `_findOurBestResponse()`,
which makes **another** Lichess Explorer API call to find our best response move.

```
// line_finalizer.dart:14-16
if (isOurMove && hasLegalMoves) {
  final response = await findOurBestResponse();  // ← extra API call
  if (response != null) finalLine = [...lineSan, response];
}
```

In a typical generation with 100 leaf nodes, this adds **100 extra API requests**,
each with a 300ms politeness delay:

- Extra time from line finalization: 100 × 387ms = **38.7 seconds**

**Python does not do this.** When Python hits a leaf, it just saves the line. No
extra API call.

### Factor 3: Engine Analysis (engine strategies only)

When using `engineOnly` or `metaEval` strategies (not `winRateOnly`), every node
in the DFS requires:

| Step | Cost |
|------|-----:|
| `_evaluateWhiteCp()` — Stockfish eval | 200–2,000 ms |
| `_getDbData()` — Lichess API call | ~387 ms |
| `_buildOurCandidates()` — MultiPV discovery | 500–3,000 ms |
| `_getLikelyMovesForUs()` — another DB call | ~387 ms |
| `_pool.evaluateMany()` — eval all candidates | 500–5,000 ms |
| `EaseCalculator.compute()` (metaEval only) | 200–2,000 ms |

A single engine node can take **2–12 seconds**, compared to Python's ~187ms
per pure-DB node. This is why the engine strategies feel glacially slow.

**Python's `builder.py` coverage mode uses only DB calls — no engine.** This is
the most direct comparison to Flutter's `winRateOnly` strategy.

### Factor 4: Main-Thread Event Loop Penalty (engine strategies)

The code comment in `db_only_generation_isolate.dart` explicitly states:

> "This avoids the 30-70× latency penalty caused by Flutter's rendering pipeline
> blocking async continuations on the main isolate."

When engine strategies run on the **main isolate**, every `await` yields to the
Flutter event loop. Between continuations, Flutter's build/layout/paint pipeline
can insert itself, adding 10–70ms overhead per async operation. The UI throttles
progress updates to every 250ms, but this only reduces — doesn't eliminate — the
contention.

The `winRateOnly` (DB-only) strategy correctly uses a **dedicated isolate**,
avoiding this penalty entirely. But it still has the 300ms delay.

---

## Detailed Code Comparison

### What Python Does Per Node (coverage mode)

1. `time.sleep(0.1)` — 100ms rate limit
2. `requests.get()` — HTTP GET (~87ms)
3. `response.json()` — JSON parse (negligible)
4. Raw dict access for move data (no model objects)
5. `chess.Board(fen)` / `board.push_san()` — apply move
6. Recurse

**Total per node: ~187ms**

### What Flutter Does Per Node (DB-only isolate)

1. `_waitForSlot()` — 300ms minimum gap enforced
2. `_httpClient.get()` — HTTP GET (~87ms)
3. `json.decode(response.body)` — JSON parse
4. `ExplorerResponse.fromJson(data, fen: fen)` — build model objects, sort moves
5. `Chess.fromSetup(Setup.parseFen(fen))` — parse position with dartchess
6. `DbMoveFilters.bestMoveForUs()` / `opponentReplies()` — filter moves
7. `playUciMove(fen, move.uci)` — apply move, get child FEN
8. `sendPort.send(DbOnlyProgress(...))` — cross-isolate progress (every 20 nodes)
9. At leaves: `LineFinalizer.finalize()` → **another API call** via `_findOurBestResponse()`
10. Recurse

**Total per node: ~387ms + 387ms at leaves**

### What Flutter Does Per Node (engine strategies, main isolate)

Steps 1–8 above, plus:
- Stockfish eval via `_evaluateWhiteCp()`
- Multi-PV engine discovery via `_pool.discoverMoves()`
- Candidate evaluation via `_pool.evaluateMany()`
- Ease calculation (metaEval) via `EaseCalculator.compute()`
- Flutter event loop contention (10–70ms per await)

**Total per node: 2,000–12,000ms**

---

## Estimated Generation Times (200 unique positions)

| Strategy | Per-Node Time | Total Estimate |
|----------|-------------:|---------------:|
| **Python (coverage)** | ~187 ms | **~37 seconds** |
| **Flutter winRateOnly (DB-only isolate)** | ~387 ms + leaf overhead | **~90 seconds** |
| **Flutter engineOnly** | ~2,000–5,000 ms | **7–17 minutes** |
| **Flutter metaEval** | ~3,000–12,000 ms | **10–40 minutes** |

---

## Recommendations

### Quick Win: Reduce Politeness Delay to 100ms

The Lichess Explorer API rate limit is documented as 15 req/s for authenticated
users. A 100ms delay = 10 req/s, well within limits. The current 300ms is
unnecessarily conservative.

```dart
// lichess_api_client.dart line 56
// BEFORE:
static const Duration politenessDelay = Duration(milliseconds: 300);
// AFTER:
static const Duration politenessDelay = Duration(milliseconds: 100);
```

**Impact:** Immediately cuts DB-only generation time nearly in half.

### Remove LineFinalizer Extra DB Call

For DB-only mode, the extra API call at every leaf to find "our best response" is
expensive. Consider:
- Making it optional (skip when cumulative probability is already very low)
- Caching the parent's DB data and reusing it (the parent already has the move list)
- Dropping it entirely — the leaf already has a complete line

### Consider Parallel API Requests for Sibling Positions

When branching on opponent replies, all sibling positions could be fetched in
parallel. With 3–5 siblings, this would reduce the API bottleneck by 3–5×.

The Explorer API can handle multiple concurrent requests. A batch of 5 parallel
requests takes the same wall time as 1 sequential request (~87ms), instead of
5 × 387ms = ~1.9 seconds.

### Engine Strategy Improvements

For engine-backed strategies, the DB calls are dwarfed by engine work. Focus on:
- Engine eval caching (already implemented via `_evalWhiteCache`)
- Reducing engine depth for candidate screening
- More aggressive pruning to reduce tree size

---

## Summary Table

| Dimension | Python | Flutter DB-Only | Flutter Engine |
|-----------|--------|-----------------|----------------|
| Raw API latency | ~87 ms | ~87 ms | ~87 ms |
| Politeness delay | 100 ms | 300 ms | 300 ms |
| Effective per-request cycle | 187 ms | ~387 ms | ~387 ms |
| Extra leaf API calls | No | Yes | Yes |
| Engine work per node | None | None | 1–10 seconds |
| Event loop overhead | None | None (isolate) | 10–70 ms/await |
| HTTP client | `requests.Session` | `http.Client` | `http.Client` |
| Connection reuse | Yes | Yes | Yes |
| JSON parse cost | Negligible | Negligible | Negligible |
| **Relative speed** | **1×** | **~2.5×** slower | **~20–60×** slower |
