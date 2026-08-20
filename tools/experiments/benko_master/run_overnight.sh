#!/usr/bin/env bash
# Overnight: fill the master-games database from TWIC, then build a
# repertoire from a given position with that book in play.
#
# Both phases are headless `flutter test` processes (flutter_tester +
# Stockfish + Maia ONNX) — the app is never launched, so nothing appears on
# the desktop.  Phase 2 waits for phase 1 and is skipped if it produced no
# games.
#
#   tools/experiments/benko_master/run_overnight.sh [results-dir]
#
# Tunables (env): START_MOVES PLAY_WHITE MAX_PLY EVAL_DEPTH THREADS
#                 BUDGET_MIN MULTIPV MAIA_ELO MIN_EVAL_CP YEARS NICE
#                 SKIP_DOWNLOAD=1 (a download already running elsewhere)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
FLUTTER="${FLUTTER:-$HOME/sdk/flutter/bin/flutter}"
DB="${DB:-$HOME/.local/share/com.example.chess_auto_prep/master_games.db}"
RESULTS="${1:-$REPO/tools/experiments/benko_master/run_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$RESULTS"
echo $$ > "$RESULTS/pid"

START_MOVES="${START_MOVES:-d4 Nf6 c4 c5 d5 b5 cxb5 a6 bxa6 e6}"
PLAY_WHITE="${PLAY_WHITE:-true}"
MAX_PLY="${MAX_PLY:-14}"
EVAL_DEPTH="${EVAL_DEPTH:-16}"
THREADS="${THREADS:-16}"
BUDGET_MIN="${BUDGET_MIN:-300}"
MULTIPV="${MULTIPV:-4}"
MAIA_ELO="${MAIA_ELO:-2200}"
MIN_EVAL_CP="${MIN_EVAL_CP:--20}"
YEARS="${YEARS:-5}"
NICE="${NICE:-5}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"

export LD_LIBRARY_PATH="$REPO/build/linux/x64/debug/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ ! -f "$REPO/build/linux/x64/debug/bundle/lib/libonnxruntime.so.1.15.1" ]; then
  echo "onnxruntime .so not found — build the Linux app once (flutter build linux --debug)" >&2
  exit 2
fi

{
  echo "START_MOVES=\"$START_MOVES\" PLAY_WHITE=$PLAY_WHITE MAX_PLY=$MAX_PLY"
  echo "EVAL_DEPTH=$EVAL_DEPTH THREADS=$THREADS BUDGET_MIN=$BUDGET_MIN MULTIPV=$MULTIPV"
  echo "MAIA_ELO=$MAIA_ELO MIN_EVAL_CP=$MIN_EVAL_CP YEARS=$YEARS DB=$DB"
  echo "started=$(date -Is) host=$(hostname) nproc=$(nproc)"
} | tee "$RESULTS/settings.txt"

games() { sqlite3 "$DB" 'select count(*) from games;' 2>/dev/null || echo 0; }

if [ "$SKIP_DOWNLOAD" != "1" ]; then
  echo "=== $(date -Is) TWIC download → $RESULTS/twic.log"
  nice -n "$NICE" "$FLUTTER" test "$REPO/test/benchmark/twic_download.dart" \
    --dart-define=DB="$DB" \
    --dart-define=YEARS="$YEARS" \
    > "$RESULTS/twic.log" 2>&1
  echo "=== $(date -Is) download exit=$? ($(games) games in the database)"
fi

if [ "$(games)" -eq 0 ]; then
  echo "!!! no master games — refusing to build a book-less 'master' run" >&2
  exit 3
fi

echo "=== $(date -Is) build → $RESULTS/build.log"
nice -n "$NICE" "$FLUTTER" test "$REPO/test/benchmark/master_build_overnight.dart" \
  --dart-define=OUT="$RESULTS/build" \
  --dart-define=DB="$DB" \
  --dart-define=START_MOVES="$START_MOVES" \
  --dart-define=PLAY_WHITE="$PLAY_WHITE" \
  --dart-define=MAX_PLY="$MAX_PLY" \
  --dart-define=EVAL_DEPTH="$EVAL_DEPTH" \
  --dart-define=THREADS="$THREADS" \
  --dart-define=BUDGET_MIN="$BUDGET_MIN" \
  --dart-define=MULTIPV="$MULTIPV" \
  --dart-define=MAIA_ELO="$MAIA_ELO" \
  --dart-define=MIN_EVAL_CP="$MIN_EVAL_CP" \
  > "$RESULTS/build.log" 2>&1
echo "=== $(date -Is) build exit=$?"
grep -h "mgb\] .*\(build done\|phase2\|phase3\|wrote\)" "$RESULTS/build.log" || true
