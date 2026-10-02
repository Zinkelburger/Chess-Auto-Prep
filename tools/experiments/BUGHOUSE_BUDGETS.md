# Bughouse evaluation budget benchmark

This is an isolated research harness, not a database builder. It never updates
the desktop/web books, changes engine defaults, or starts a scheduled task.

## Search experiment

`bughouse_budget_benchmark.py prepare` takes the existing FICS sample JSON
(`tags` and interleaved `moves`), replays both boards with the production
bughouse move rules, and samples one position per distinct game. The fixed seed
is 20261002. There are eight positions in each of three strata: early positions
without reserves, later positions with reserves, and positions in check. Each
selected board has at least two legal moves. Sampling is deliberately balanced
for a stress test; aggregate percentages are not estimates of the distribution
of positions reached by users.

`run` compares 100, 300, 800, 3,000 and 8,000 requested MCTS nodes. Budget order
is deterministically shuffled per case, `ucinewgame` clears the tree before
every search, the selected board must move, time advantage is false, and
pondering is disabled. Each case also gets a no-search two-seat neural reading.
The searched value subtracts the static two-seat offset, exactly as the current
table backend does, and is stored from the White-on-board-A team's perspective.
This normalization has limitations; this experiment tests convergence of the
current evaluator, not calibration against real game outcomes.

Record actual nodes as well as requested nodes: batched search can overshoot,
and a proof/early exit may stop before the allowance. Search timing excludes
model loading and static calibration (the latter is recorded separately).
Hashes identify the exact executable and weights. CI's CPU quota applies even
when the process affinity lists more CPUs. Do not extrapolate elapsed seconds
to an unrestricted GPU or a differently allocated CPU job.

Use 8,000 nodes as a stronger **reference**, not ground truth. Report absolute
Q differences, large-error tails, sign reversals when the reference magnitude
is at least 0.10, and selected-board best-move agreement. A move disagreement
alone is not a blunder: multiple moves can be equally good. Q is the engine's
bounded value scale; these differences are neither centipawns nor validated
win-probability errors. In particular, no Elo claims follow from this test.

Before seeing the complete results, use |ΔQ| > 0.05 as a noticeable change and
|ΔQ| > 0.10 as a large change for comparing budgets. These are engineering
tolerances, not empirically established human-strength boundaries. A bulk
budget needs separate scrutiny on tactical tails even if its median is good.

Example (all engine execution goes through the bounded runner):

```bash
python3 tools/experiments/bughouse_budget_benchmark.py --output "$BENCH_DIR" prepare \
  --source "$FICS_SAMPLE"
scripts/ci.sh with -- python3 tools/experiments/bughouse_budget_benchmark.py \
  --output "$BENCH_DIR" run --engine "$ENGINE_BIN" --model "$ENGINE_MODEL" \
  --library "$ENGINE_LIB"
python3 tools/experiments/bughouse_budget_benchmark.py --output "$BENCH_DIR" validate
python3 tools/experiments/bughouse_budget_benchmark.py --output "$BENCH_DIR" summarize
```

`--shard N --shards K` divides cases into disjoint subsets; the record files are
separate. A repeat uses `--repeat N --only CASE_ID ...` and fresh searches. Keep the cases, model,
binary and settings unchanged when resuming a directory. JSONL records flush
after each result. Save the output directory, including manifests and cases,
with any report.

`prepare_rankings` selects up to four cases where the 100- or 800-node move
disagrees with 8,000 nodes, prioritizing the largest score discrepancies. It
creates `rankings/cases.json` with the resulting positions after those moves,
including cross-board captures. Search those children at 8,000 nodes to compare
the alternatives on a common horizon. These are deliberately selected case
studies, not an unbiased estimate of move regret; terminal children require
explicit adjudication and are rejected by this helper rather than guessed.

## Mate-solver experiment

The installed UCI binary has no independent mate-budget option. The C++ probe
calls `Agent::find_root_mate` directly, without loading the neural network, from
an explicitly identified Hivemind static library. This is a separate build;
its throughput must not be represented as a measurement of the bundled UCI
binary. Record the source commit and static-library hash.

`prepare_mates --source /path/to/hivemind/engine/tests/test_move_gen.cc` extracts
literal dual FENs from mate-probe regression tests and adds the 24 FICS cases.
It normalizes each FEN using the same board parser. Regression positions are
tested from both selected boards when legal moves exist. Tests that require
additional moves or assembled string variables are not automatically copied.
These are curated tactical cases, not an independent tactical test set.

The probe tries allowances of 100, 300, 1,000, 2,000, 3,000, 8,000, 10,000,
30,000, 100,000 and 300,000, three repeats each. All use no time advantage and
require a move on the selected board. Each call receives a ten-second safety
deadline; timed-out calls must be reported separately. Board state must be
restored after every probe. Allowances are the solver's own budget units, not
MCTS nodes. Mate-probe subphases can have their own proportional allowances.

Link the probe with the selected Hivemind build's `libhivemind_lib.a`, its
Fairy-Stockfish static library and its inference runtime, using that build's
include paths and `HIVEMIND_BACKEND_ONNXRUNTIME` definition. For the existing
ONNX Runtime build layout:

```bash
scripts/ci.sh with -- g++ -std=c++23 -O2 -DNDEBUG -DNNUE_EMBEDDING_OFF \
  -DHIVEMIND_BACKEND_ONNXRUNTIME -I"$ENGINE_CHECKOUT/engine/src" \
  -I"$ENGINE_CHECKOUT/third_party/onnxruntime/include" \
  tools/experiments/bughouse_mate_benchmark.cc \
  "$ENGINE_CHECKOUT/engine/build-ort/libhivemind_lib.a" \
  "$ENGINE_CHECKOUT/engine/build-ort/src/Fairy-Stockfish/libFairy-Stockfish.a" \
  "$ENGINE_CHECKOUT/third_party/onnxruntime/lib/libonnxruntime.so" \
  -Wl,-rpath,"$ENGINE_CHECKOUT/third_party/onnxruntime/lib" -ldl -pthread \
  -o "$MATE_PROBE"
```

Then run:

```bash
scripts/ci.sh with -- bash -c '"$MATE_PROBE" < "$BENCH_DIR/mate-cases.tsv" > "$BENCH_DIR/mates.jsonl"'
```

Compare proof coverage with the largest allowance, including whether a smaller
budget finds a longer mate. “Not proven” does not mean “no mate.” A high-budget
proof is a useful reference but not an independent verification of the solver.
The root winning-mate probe is only one tactical mechanism: this test does not
measure the separate forced-loss scanner or all in-tree MCTS proofs.
