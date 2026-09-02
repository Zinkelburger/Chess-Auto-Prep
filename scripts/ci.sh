#!/usr/bin/env bash
# scripts/ci.sh — run the local CI gates one-at-a-time, machine-wide.
#
# Several agents used to launch `flutter test` / `flutter analyze` at once and
# bring the machine down. This script serialises every heavy Flutter job
# behind one flock, and reuses a passing result when the working tree has not
# changed since it was produced — so five agents asking for "CI" on the same
# tree get one run, and the other four just replay its log.
#
#   scripts/ci.sh              # format + analyze + test (+ lint greps)
#   scripts/ci.sh analyze      # one step
#   scripts/ci.sh test lint    # several
#   scripts/ci.sh integration  # integration_test/app_test.dart on the Linux
#                              # device (opens a window on this display)
#   scripts/ci.sh status       # who holds the lock, and what is cached
#   scripts/ci.sh --fresh …    # ignore the result cache
#
# Any other heavy job (an app launch, a release build) can join the queue with
#   scripts/ci.sh with -- <command…>
# which runs <command> under the same lock without caching.
set -uo pipefail

CALLER_PWD=$PWD
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# Flutter lives at ~/sdk/flutter on the dev machine; fall back to PATH.
if [[ -z "${FLUTTER:-}" ]]; then
  if [[ -x "$HOME/sdk/flutter/bin/flutter" ]]; then
    FLUTTER="$HOME/sdk/flutter/bin/flutter"
  else
    FLUTTER=$(command -v flutter || true)
  fi
fi
DART="$(dirname "$FLUTTER")/dart"
[[ -x "$FLUTTER" ]] || { echo "ci.sh: flutter not found (set FLUTTER=…)" >&2; exit 2; }

LOCK=${CHESS_PREP_LOCK:-/tmp/chess-auto-prep-flutter.lock}
HOLDER="$LOCK.holder"
CACHE_DIR=${CHESS_PREP_CI_CACHE:-/tmp/chess-auto-prep-ci}
LOCK_TIMEOUT=${CHESS_PREP_LOCK_TIMEOUT:-3600}
mkdir -p "$CACHE_DIR"

FRESH=0
STEPS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh) FRESH=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) STEPS+=("$1") ;;
  esac
  shift
done
[[ ${#STEPS[@]} -eq 0 ]] && STEPS=(format analyze test lint)

# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------
acquire_lock() {
  local what=$1
  exec 9>"$LOCK"
  if ! flock -n 9; then
    local who="another Flutter job"
    [[ -r "$HOLDER" ]] && who=$(cat "$HOLDER")
    echo "ci.sh: waiting for the Flutter lock (held by: $who)…"
    if ! flock -w "$LOCK_TIMEOUT" 9; then
      echo "ci.sh: gave up waiting for the lock after ${LOCK_TIMEOUT}s" >&2
      exit 3
    fi
  fi
  printf 'pid %s · %s · started %s\n' "$$" "$what" "$(date '+%H:%M:%S')" > "$HOLDER"
  trap 'rm -f "$HOLDER"' EXIT
}

# ---------------------------------------------------------------------------
# Tree hash — HEAD + every tracked change + untracked source files, so two
# identical trees share a cache entry and any edit invalidates it.
# ---------------------------------------------------------------------------
tree_hash() {
  {
    git rev-parse HEAD
    git diff HEAD -- lib test integration_test pubspec.yaml pubspec.lock analysis_options.yaml
    git ls-files --others --exclude-standard -z lib test integration_test \
      | xargs -0 -r sha256sum
  } | sha256sum | cut -c1-16
}

cache_key() { echo "$CACHE_DIR/$(tree_hash).$1"; }

replay_cached() {
  local key=$1 step=$2
  [[ $FRESH -eq 0 && -r "$key" ]] || return 1
  echo "── $step: reusing the passing result from $(stat -c '%y' "$key" | cut -c1-19) (tree unchanged)"
  tail -n 5 "$key"
  return 0
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
run_step() {
  local step=$1 rc=0 key log
  case "$step" in
    format)
      # Applies formatting (what you want before a commit); CI merely checks.
      echo "── format"
      "$DART" format lib test integration_test
      return $?
      ;;
    lint)
      echo "── lint greps"
      local bad=0
      if grep -rlE "import '.*(widgets/|screens/)" lib/core lib/models lib/services lib/utils 2>/dev/null; then
        echo "lint: layering violation (core/models/services/utils importing widgets/screens)"; bad=1
      fi
      local feat
      feat=$(grep -rlE "import '.*(widgets/|screens/)" lib/features/*/controllers lib/features/*/services lib/features/*/models 2>/dev/null \
        | grep -v 'features/repertoire/controllers/build_launcher.dart' || true)
      if [[ -n "$feat" ]]; then
        echo "$feat"; echo "lint: feature non-widget layer importing widgets/screens"; bad=1
      fi
      if grep -rnE "fontSize: (9|10|10\.5|11|11\.5)[,)]" lib | grep -v board_coordinates; then
        echo "lint: fontSize below the 12px floor"; bad=1
      fi
      return $bad
      ;;
    analyze|test|integration) ;;
    *) echo "ci.sh: unknown step '$step'" >&2; return 2 ;;
  esac

  key=$(cache_key "$step")
  replay_cached "$key" "$step" && return 0

  log=$(mktemp "$CACHE_DIR/$step.XXXXXX.log")
  echo "── $step (log: $log)"
  case "$step" in
    analyze)
      "$FLUTTER" analyze lib test --no-fatal-infos 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
      # CI treats warnings as fatal; the exit code alone does not.
      if grep -qE '^\s*(error|warning) •' "$log"; then rc=1; fi
      ;;
    test)
      "$FLUTTER" test 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
      ;;
    integration)
      "$FLUTTER" test integration_test/app_test.dart -d linux 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
      ;;
  esac
  if [[ $rc -eq 0 ]]; then
    mv "$log" "$key"
  else
    echo "── $step FAILED (rc=$rc); full log: $log"
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
case "${STEPS[0]}" in
  status)
    if [[ -r "$HOLDER" ]] && ! flock -n "$LOCK" true 2>/dev/null; then
      echo "lock held: $(cat "$HOLDER")"
    else
      echo "lock free"
    fi
    h=$(tree_hash)
    echo "tree $h; cached passes:"
    ls "$CACHE_DIR"/"$h".* 2>/dev/null | sed 's|.*/||' || true
    exit 0
    ;;
  with)
    # scripts/ci.sh with -- cmd…   → run cmd under the lock, no caching,
    # in the directory the caller was in (so a worktree can use it).
    shift_n=1; [[ "${STEPS[1]:-}" == "--" ]] && shift_n=2
    CMD=("${STEPS[@]:$shift_n}")
    acquire_lock "${CMD[*]:0:3}"
    cd "$CALLER_PWD" && "${CMD[@]}"
    exit $?
    ;;
esac

# `format` rewrites files, which changes the tree hash — run it before deciding
# whether the heavy steps are cached. It and `lint` are cheap and never queue.
overall=0
if [[ " ${STEPS[*]} " == *" format "* ]]; then
  run_step format || { overall=1; failed=" format"; }
  STEPS=("${STEPS[@]/format}")
fi

needs_lock=0
for s in "${STEPS[@]}"; do
  case "$s" in analyze|test|integration) needs_lock=1 ;; esac
done
if [[ $needs_lock -eq 1 ]]; then
  # If every heavy step is already cached for this tree, skip the queue.
  all_cached=1
  for s in "${STEPS[@]}"; do
    case "$s" in
      analyze|test|integration) [[ $FRESH -eq 0 && -r "$(cache_key "$s")" ]] || all_cached=0 ;;
    esac
  done
  [[ $all_cached -eq 1 ]] || acquire_lock "ci.sh ${STEPS[*]}"
fi

for s in "${STEPS[@]}"; do
  [[ -z "$s" ]] && continue
  run_step "$s" || { overall=1; failed="${failed:-} $s"; }
done
if [[ $overall -eq 0 ]]; then
  echo "── all green: ${STEPS[*]}"
else
  echo "── FAILED:${failed}"
fi
exit $overall
