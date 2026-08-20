# Fast vs Pure Expectimax experiment

Question: does the Fast Expectimax build (best-first frontier + reach-zoned
pruning + incumbent/alternative subtree gating, `TreeBuildConfig`
`searchAlgorithm == fast`) pick the **same repertoire moves** as the uniform
Pure build at the same `maxPly`, and if not, does the disagreement follow the
predicted bias — Fast confirming the shallow-eval incumbent because its
alternatives get thinner subtrees (less "human error credit" in expectimax)?

Not part of the app or CI.  Runs the app's **real** Dart pipeline headlessly:
`test/benchmark/fast_vs_pure_benchmark.dart` under `flutter test`
(flutter_tester, no window), the extracted Stockfish binary, and Maia-3 via
onnxruntime (needs `LD_LIBRARY_PATH` → `build/linux/x64/debug/bundle/lib`).

```
tools/experiments/fast_vs_pure/run_overnight.sh [results-dir]
# env: MAX_PLY EVAL_DEPTH THREADS BUDGET_MIN START_MOVES PLAY_WHITE MULTIPV
#      MAIA_ELO MIN_EVAL_CP NICE ORDER
```

Each algorithm builds in its own sandbox (fresh eval/Maia cache → cold-cache
timings), then phase 2 (ease, expectimax, selection) runs exactly as
`GenerationSessionController._analyzeTreePhase`; deep verify is off.  Output
per run: `tree.json`, `stats.json`, `run.log`.  `compare/compare.md` reports:

- wall time / engine searches / node counts / root V per algorithm;
- over our-move positions present in **both** trees, weighted by Pure's reach
  probability and split into hot/warm/cold zones (Fast's own thresholds
  0.02 / 0.002): move agreement, and **regret** = Pure's expectimax value of
  Pure's move minus Pure's value of Fast's move (how much practical value
  Fast's choice loses under the uniform tree's judgment);
- bias diagnostics at disagreements: is Fast's choice the engine-best
  (incumbent) move? is Pure's? did Fast's chosen move get a deeper subtree
  than its siblings?
- the worst disagreements by reach × regret.

Caveats: Stockfish with >1 thread is nondeterministic, so some disagreement
is engine noise, not algorithm; the hot-zone rows and the regret magnitude
are the signal, raw agreement % alone is not.  `MIN_EVAL_CP` defaults to
−20 (app default 0) because root-eval noise otherwise pruned every root
child in about half of shallow smoke runs.
