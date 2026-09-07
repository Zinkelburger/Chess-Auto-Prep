# Parallel Pure and Fast expectimax

Pure and Fast use the configured engine workers to evaluate independent
positions concurrently. The search coordinator owns the tree, budgets,
probability distributions and Fast's committed moves. It sends work to engines
and applies completed results in the original move order.

Two sources keep workers occupied:

- At our turns, evaluate all legal candidates concurrently before applying the
  engine-loss constraint. A fast result cannot exclude a slower candidate.
- At the horizon, group up to 256 frontier leaves into a batch, including leaves
  from different reply branches. This matters when individual positions have
  fewer legal moves than there are workers.

Each free worker takes the next position. Assigning an entire subtree to each
worker would leave idle workers when subtree sizes differ, require shared tree
mutation and complicate budgets and Fast commitments. The expensive Stockfish
work can be shared without those complications. Maia and chess bookkeeping
remain serial. More workers do not remove exponential branching or guarantee
linear speedup.

Dart uses the existing bounded `runLanes` helper and pool concurrency limit.
C uses its engine thread pool with one UCI thread per position. Tree updates
and Fast decisions wait for the required batch. Cancellation stops dispatching
new work; in-flight work drains before return. Failed/incomplete candidate
batches cannot publish partial action sets. Successfully evaluated attached
leaves can be reused after interruption. Completed results agree across worker
counts when the input evaluations agree. Real Stockfish hash histories can
produce different fixed-depth scores across schedules; the search itself
retains the same objective and constraints.

The other Dart engine-backed build paths already expand independent frontier
nodes in parallel; their concurrency now respects the active pool limit, even
if an earlier consumer spawned more engines. C's database builder already uses
batch evaluation. Modes that only use database counts or Maia do not benefit
from additional Stockfish workers. The shared C batch path also now clears
stale success flags and frees rejected submissions.

## Maia repeatability discovered during validation

The interrupt/resume regression exposed a separate reproducible inference
issue with the bundled Maia model and ONNX Runtime 1.15.1. For
`8/8/8/8/P7/3k4/8/4K3 b - - 0 2`, the first inference assigned `d3c4`
probability 0.9219915375521778; subsequent inferences assigned
0.9205872191759987. There was no parallel Maia call in this reproduction.

Disabling memory patterns made first and repeated results agree. ONNX Runtime
[documents memory patterns](https://onnxruntime.ai/docs/api/csharp/api/Microsoft.ML.OnnxRuntime.SessionOptions.html#Microsoft_ML_OnnxRuntime_SessionOptions_EnableMemoryPattern)
as reusing the first run's allocation pattern on later runs. The exact internal
cause of the probability difference has not been established; disabling that
optimization is the tested workaround for this bundled runtime/model.

Both implementations disable it. Dart's wrapper lacks this option, so a small
native session-construction helper sets it through the same ORT C API before
handing the session to the wrapper. Inference still uses the existing serialized
Maia queue. Old cached Maia probabilities are invalidated, preserving Stockfish
evaluations. Old C cache imports cannot reintroduce them. Pure/Fast trees record
`maia_policy_version: 1`; older trees require a fresh build rather than mixing
probabilities from the two inference configurations.

## Validation

The regressions compare entire completed trees, including Fast decisions,
with deliberately unequal evaluation completion times. They test cancellation,
resume, failed or insufficient-depth evaluations, worker limits, parallel
horizon leaves, and first/repeated Maia inference.

Run the focused checks through the bounded runner:

```sh
scripts/ci.sh test test/services/generation test/services/engine test/services/eval
scripts/ci.sh analyze lint
scripts/ci.sh with -- make -C tree_builder -j2 test-pure
# Requires the ONNX runtime library on LD_LIBRARY_PATH:
scripts/ci.sh test test/tools/maia_repeatability.dart
```

The C CLI oracle test observes ten simultaneous engine searches even under the
test runner's two-CPU limit (the simulated engine deliberately waits). It is a
concurrency/correctness test, not a ten-core Stockfish speed benchmark. Real
engine measurements are recorded below separately.

## Real-engine measurements — 6 September 2026

Fresh processes and disposable storage, one observation per setting, two CPUs
available to the job, startup excluded. These use production Dart search,
Stockfish and Maia; [raw measurements and engine identity](benchmarks/parallel-expectimax-2026-09-06.json)
include configs, engine calls and values.

| Position / horizon / engine depth | Mode | 1 worker | 2 workers | Ratio |
|---|---|---:|---:|---:|
| Winawer after 3…Bb4 / 1 ply / depth 16 | Pure | 5.187 s | 2.945 s | 1.76× |
| Winawer after 3…Bb4 / 1 ply / depth 16 | Fast | 5.126 s | 2.997 s | 1.71× |
| Pawn control / 4 plies / depth 10 | Pure | 5.217 s | 5.323 s | 0.98× |
| Pawn control / 4 plies / depth 10 | Fast | 5.237 s | 5.197 s | 1.01× |

All eight builds completed. The Winawer root choice was e5 in every run;
the pawn choice was Kf1. Candidate sets and backed-up values did vary slightly:
these are real fixed-depth Stockfish searches with independent hash histories,
not deterministic evaluation oracles. At these short horizons Fast does not
save deeper alternative branches, so this tests parallel evaluation rather
than Fast's long-horizon approximation. The cheap pawn evaluations expose the
serial Maia/bookkeeping cost; additional engines alone do not speed that case.
This is evidence of useful scaling where engine work dominates, not a claim
of a tenfold speedup or improved playing strength.

Reproduce with `tools/experiments/fast_vs_pure/run_overnight.sh OUTPUT
--case winawer-root --depth 16 --workers 2` (one fresh OUTPUT per measurement).
Use `--case pawn-control --depth 10` for the four-ply case. Supply `--onnx-lib`
when the runtime is outside the default build bundle.

Completed checks for this change: 863 tests across Dart generation, engine,
eval-cache, form and session suites; 22 final focused checks after adding
inference-version rejection and cache migration; two native-Maia/cache checks;
30 C Pure oracle trees and 12 rolling oracle policies; C one/ten-worker,
interrupt/resume, failure and cache-import regressions; 46 MCP tests and two
benchmark guards. Analyzer and lint passed. The native-Maia check exercises
Dart's actual ORT session, without cache hits, across repeated and fresh sessions.
