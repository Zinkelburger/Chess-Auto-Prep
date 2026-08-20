#!/usr/bin/env bash
# Fast-vs-Pure Expectimax experiment driver.
#
# Runs the real Dart pipeline headlessly (flutter_tester + Stockfish + Maia
# ONNX) once per algorithm, then compares the two trees.  Each phase is its
# own `flutter test` process with its own sandbox (fresh eval cache), so the
# two builds are cold-cache comparable and a crash in one leaves the other's
# output intact.
#
#   tools/experiments/fast_vs_pure/run_overnight.sh [results-dir]
#
# Tunables (env): MAX_PLY EVAL_DEPTH THREADS BUDGET_MIN START_MOVES PLAY_WHITE
#                 MULTIPV MAIA_ELO MIN_EVAL_CP NICE ORDER ("fast pure" default)
#
# Progress: tail -f <results-dir>/{fast,pure}.log ; summary lands in
# <results-dir>/compare/compare.md.  Stop with: kill $(cat <results-dir>/pid)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
FLUTTER="${FLUTTER:-$HOME/sdk/flutter/bin/flutter}"
RESULTS="${1:-$REPO/tools/experiments/fast_vs_pure/results/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$RESULTS"
echo $$ > "$RESULTS/pid"

MAX_PLY="${MAX_PLY:-10}"
EVAL_DEPTH="${EVAL_DEPTH:-14}"
THREADS="${THREADS:-6}"
BUDGET_MIN="${BUDGET_MIN:-0}"
START_MOVES="${START_MOVES:-}"
PLAY_WHITE="${PLAY_WHITE:-true}"
MULTIPV="${MULTIPV:-4}"
MAIA_ELO="${MAIA_ELO:-2200}"
MIN_EVAL_CP="${MIN_EVAL_CP:--20}"
NICE="${NICE:-10}"
ORDER="${ORDER:-fast pure}"

export LD_LIBRARY_PATH="$REPO/build/linux/x64/debug/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ ! -f "$REPO/build/linux/x64/debug/bundle/lib/libonnxruntime.so.1.15.1" ]; then
  echo "onnxruntime .so not found under build/linux — build the Linux app once (flutter build linux --debug)" >&2
  exit 2
fi

cat > "$RESULTS/settings.txt" <<EOF
MAX_PLY=$MAX_PLY EVAL_DEPTH=$EVAL_DEPTH THREADS=$THREADS BUDGET_MIN=$BUDGET_MIN
START_MOVES="$START_MOVES" PLAY_WHITE=$PLAY_WHITE MULTIPV=$MULTIPV MAIA_ELO=$MAIA_ELO MIN_EVAL_CP=$MIN_EVAL_CP
NICE=$NICE ORDER="$ORDER" started=$(date -Is) host=$(hostname) nproc=$(nproc)
EOF
cat "$RESULTS/settings.txt"

run_build() {
  local algo="$1"
  echo "=== $(date -Is) build $algo → $RESULTS/$algo"
  nice -n "$NICE" "$FLUTTER" test "$REPO/test/benchmark/fast_vs_pure_benchmark.dart" \
    --dart-define=MODE=build \
    --dart-define=ALGO="$algo" \
    --dart-define=OUT="$RESULTS/$algo" \
    --dart-define=MAX_PLY="$MAX_PLY" \
    --dart-define=EVAL_DEPTH="$EVAL_DEPTH" \
    --dart-define=THREADS="$THREADS" \
    --dart-define=BUDGET_MIN="$BUDGET_MIN" \
    --dart-define=START_MOVES="$START_MOVES" \
    --dart-define=PLAY_WHITE="$PLAY_WHITE" \
    --dart-define=MULTIPV="$MULTIPV" \
    --dart-define=MAIA_ELO="$MAIA_ELO" \
    --dart-define=MIN_EVAL_CP="$MIN_EVAL_CP" \
    > "$RESULTS/$algo.log" 2>&1
  local rc=$?
  echo "=== $(date -Is) build $algo exit=$rc"
  grep -h "fvp\] \(build done\|phase2\)" "$RESULTS/$algo.log" || true
  return $rc
}

for algo in $ORDER; do
  run_build "$algo"
done

echo "=== $(date -Is) compare"
nice -n "$NICE" "$FLUTTER" test "$REPO/test/benchmark/fast_vs_pure_benchmark.dart" \
  --dart-define=MODE=compare \
  --dart-define=FAST="$RESULTS/fast" \
  --dart-define=PURE="$RESULTS/pure" \
  --dart-define=OUT="$RESULTS/compare" \
  > "$RESULTS/compare.log" 2>&1
echo "=== $(date -Is) compare exit=$?"
[ -f "$RESULTS/compare/compare.md" ] && cat "$RESULTS/compare/compare.md"
echo "=== $(date -Is) done"
