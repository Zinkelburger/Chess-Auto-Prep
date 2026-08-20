#!/usr/bin/env bash
# Waits for an already-running TWIC download to finish, proves the build
# harness works on a throwaway 3-minute build, then starts the real one.
# Called detached by the overnight setup; see run_overnight.sh for the
# self-contained version that also does the download.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
FLUTTER="${FLUTTER:-$HOME/sdk/flutter/bin/flutter}"
RESULTS="$1"
DB="${DB:-$HOME/.local/share/com.example.chess_auto_prep/master_games.db}"
export LD_LIBRARY_PATH="$REPO/build/linux/x64/debug/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Wait on the downloader's own last line rather than a pid: the pid of a
# detached `flutter test` is the wrapper's, not the process that does the
# work, and it exits immediately.
if [ "${NO_WAIT:-0}" = "1" ]; then
  echo "=== $(date -Is) download already finished, not waiting"
else
echo "=== $(date -Is) waiting for the TWIC download to finish"
DEADLINE=$(( $(date +%s) + 7200 ))
while ! grep -qE '^\[twic\] .* done:' "$RESULTS/twic.log" 2>/dev/null; do
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    echo "!!! download did not finish within two hours — stopping" >&2
    exit 5
  fi
  sleep 20
done
sleep 20  # let the importer's last transaction and the VM exit settle
fi
GAMES=$(sqlite3 "$DB" 'select count(*) from games;' 2>/dev/null || echo 0)
echo "=== $(date -Is) download finished, $GAMES games"
if [ "${GAMES:-0}" -lt 1000 ]; then
  echo "!!! too few master games ($GAMES) — stopping" >&2
  exit 3
fi

# Smoke: same harness, same position, a few plies. Catches a broken harness
# in three minutes instead of at hour five.
echo "=== $(date -Is) smoke build → $RESULTS/smoke.log"
"$FLUTTER" test "$REPO/test/benchmark/master_build_overnight.dart" \
  --dart-define=OUT="$RESULTS/smoke" \
  --dart-define=DB="$DB" \
  --dart-define="START_MOVES=d4 Nf6 c4 c5 d5 b5 cxb5 a6 bxa6 e6" \
  --dart-define=MAX_PLY=4 \
  --dart-define=EVAL_DEPTH=10 \
  --dart-define=THREADS=8 \
  --dart-define=BUDGET_MIN=3 \
  > "$RESULTS/smoke.log" 2>&1
RC=$?
echo "=== $(date -Is) smoke exit=$RC"
if [ $RC -ne 0 ]; then
  echo "!!! smoke build failed — not starting the long run; see $RESULTS/smoke.log" >&2
  tail -30 "$RESULTS/smoke.log" >&2
  exit 4
fi
grep -h "mgb\]" "$RESULTS/smoke.log" | tail -6

echo "=== $(date -Is) real build starting"
SKIP_DOWNLOAD=1 "$REPO/tools/experiments/benko_master/run_overnight.sh" "$RESULTS"
