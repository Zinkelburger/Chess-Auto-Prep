#!/usr/bin/env bash
# scripts/ci.sh — run the local CI gates one-at-a-time, machine-wide.
#
# Several agents used to launch `flutter test` / `flutter analyze` at once and
# bring the machine down. This script serialises every heavy Flutter job
# behind one flock, and reuses a passing result when the working tree has not
# changed since it was produced — so five agents asking for "CI" on the same
# tree get one run, and the other four just replay its log.
#
#   scripts/ci.sh              # format + analyze + coverage tests + tools + lint
#   scripts/ci.sh analyze      # one step
#   scripts/ci.sh test lint    # several
#   scripts/ci.sh integration  # integration_test/app_test.dart on the Linux
#                              # device (opens a window on this display)
#   scripts/ci.sh status       # who holds the lock, and what is cached
#   scripts/ci.sh unlock       # clear a lock left by a job that is gone
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
[[ ${#STEPS[@]} -eq 0 ]] && STEPS=(format analyze test tools lint)

# ---------------------------------------------------------------------------
# Lock
#
# The lock lives on fd 9's *open file description*, which every forked child
# shares unless the fd is closed for it. That is the trap this file fell into
# on 2026-09-04: `flutter test` was killed, ten `flutter_tester` children
# survived it reparented to `systemd --user`, and because each still held fd 9
# the flock stayed taken. Every agent on the machine queued behind a lock whose
# recorded holder had been dead for 45 minutes.
#
# Three rules keep that from recurring, and all three matter:
#   * `capped` closes fd 9 for the command it runs (`9>&-`).
#   * `run_step` closes it for its whole body, because the heavy steps are
#     pipelines — `capped … | tee log` forks a subshell and a `tee` that
#     inherit the fd too, and protecting only the command inside `capped`
#     leaves those two holding the lock. This was found by killing a real run
#     and watching the lock survive it; do not undo it.
#   * `sweep_stale_scopes` clears the leftovers themselves on the way in, so a
#     run killed with SIGKILL — which runs no trap — is tidied by whoever comes
#     next rather than by a human noticing.
#
# Between them the lock is held by this shell and nothing else, so killing this
# script by any means releases it.
#
# `driver.py` shares this lock and is safe already: Python has opened file
# descriptors non-inheritable by default since PEP 446, so its `flutter run`
# never had a copy. Do not "fix" it with os.set_inheritable().
# ---------------------------------------------------------------------------

# pids that currently hold the lock file open, one per line.
lock_holders() {
  local fd pid
  for fd in /proc/[0-9]*/fd/*; do
    [[ -L $fd ]] || continue
    if [[ $(readlink "$fd" 2>/dev/null) == "$LOCK" ]]; then
      pid=${fd#/proc/}; pid=${pid%%/*}
      echo "$pid"
    fi
  done 2>/dev/null | sort -un
}

# Stop any cgroup left behind by a ci.sh that is no longer running.
#
# The unit name carries the owning pid, so "is this mine to clean?" is a
# question we can answer without guessing. Stopping a scope kills what is still
# inside it, which is exactly the orphaned test isolates.
sweep_stale_scopes() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local unit owner
  while read -r unit; do
    [[ $unit == chess-prep-ci-*.scope ]] || continue
    owner=${unit#chess-prep-ci-}; owner=${owner%%-*}
    [[ $owner =~ ^[0-9]+$ ]] || continue
    kill -0 "$owner" 2>/dev/null && continue   # its ci.sh is still running
    echo "ci.sh: clearing $unit, left by dead pid $owner"
    systemctl --user stop "$unit" >/dev/null 2>&1 || true
  done < <(systemctl --user list-units --type=scope --all --no-legend --plain 2>/dev/null \
             | awk '{print $1}')
}

acquire_lock() {
  local what=$1
  sweep_stale_scopes
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
  HOLD_LOCK=1
}

# ---------------------------------------------------------------------------
# Memory ceiling
#
# The lock stops several heavy Flutter jobs running at once. It does nothing
# about ONE job going runaway, which is what actually takes this machine down:
# on 2026-09-04 a mutation campaign launched through `ci.sh with --` buffered a
# broken test's output until it reached 30 GB, and the kernel OOM-killed the
# editor scope it was living in — several agent sessions died with it, none of
# them the culprit. So every heavy command runs inside its own transient cgroup
# with a hard cap: a runaway hits the cap and the kernel kills *it*, alone,
# while everything else keeps running.
#
#   CHESS_PREP_MEM_MAX=24G   raise the ceiling for one run
#   CHESS_PREP_MEM_MAX=0     opt out entirely
#
# Degrades to a plain run where systemd-run or the memory controller is absent.
# ---------------------------------------------------------------------------
# 8G: the heaviest Flutter process ever measured here is dart:frontend_server
# at 1.02 G (from the 2026-09-04 task dump), and a live `ci.sh` scope under a
# mutation campaign measured 0.11 G anon / 0.67 G peak. 8G is ~8x that, and
# sits just under the 10G the desktop app scopes get.
MEM_MAX=${CHESS_PREP_MEM_MAX:-8G}
CAP_OK=0
if [[ "$MEM_MAX" != 0 && -n "$MEM_MAX" ]] && command -v systemd-run >/dev/null 2>&1 \
   && grep -qw memory "/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers" 2>/dev/null; then
  CAP_OK=1
fi

# Units this run has created, so the exit trap can tear down whatever is still
# breathing in them.
#
# A file, not an array: the heavy steps run `capped … | tee`, and the left-hand
# side of a pipeline is a subshell, so an array appended to there never reaches
# the parent that owns the trap.
UNITS_FILE=$(mktemp -t chess-prep-ci-units.XXXXXX)

# Every heavy command goes through here, which is why the `9>&-` lives here and
# not at the nine call sites: it closes the lock fd for the command and for
# everything the command spawns. Without it a surviving grandchild keeps the
# machine-wide lock held after this script is gone — see the Lock section.
capped() {
  if [[ $CAP_OK -eq 0 ]]; then "$@" 9>&-; return $?; fi
  local unit="chess-prep-ci-$$-${RANDOM}"
  echo "$unit.scope" >> "$UNITS_FILE"
  local rc=0
  # MemorySwapMax=0 keeps a runaway out of zram too — swapping it merely makes
  # the whole desktop crawl on the way to the same kill.
  systemd-run --user --scope --quiet --collect \
    --unit "$unit" \
    -p MemoryMax="$MEM_MAX" -p MemorySwapMax=0 \
    -- "$@" 9>&- || rc=$?
  stop_unit "$unit.scope"
  return $rc
}

# Stop a scope and anything still breathing inside it.
#
# `systemd-run --scope` returns when the command it started returns, which is
# not the same as the scope being empty: a test runner that leaks isolates
# leaves them there. `--collect` only reaps a scope once it is empty, so on its
# own it would keep a dead run's children alive forever.
stop_unit() {
  local unit=$1
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user is-active --quiet "$unit" 2>/dev/null || return 0
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
}

# Runs for a clean finish, an error, Ctrl+C and SIGTERM. A SIGKILL runs no trap
# at all, which is what `sweep_stale_scopes` is for.
#
# One handler, not two: a second `trap … EXIT` anywhere in this file silently
# replaces the first, and the holder file used to install its own.
on_exit() {
  local unit
  while read -r unit; do
    [[ -n $unit ]] && stop_unit "$unit"
  done < "$UNITS_FILE" 2>/dev/null
  rm -f "$UNITS_FILE"
  [[ ${HOLD_LOCK:-0} -eq 1 ]] && rm -f "$HOLDER"
  return 0
}
trap on_exit EXIT INT TERM

# 137 is SIGKILL, and by far its most likely source here is the memory ceiling
# above. Left bare it reads as a mysterious crash and costs someone half an
# hour; say so explicitly, and prove it from the cgroup's own kill counter
# rather than guessing.
explain_137() {
  local rc=$1 what=$2
  [[ $rc -eq 137 ]] || return 0
  # One line only: a heredoc-ish command would otherwise smear over the message.
  what=$(printf '%s' "$what" | tr '\n' ' ' | cut -c1-60)
  echo "──"
  echo "── \"$what\" was SIGKILLed (rc=137). Almost always the memory ceiling:"
  echo "──   the job asked for more than CHESS_PREP_MEM_MAX (${MEM_MAX}) and the"
  echo "──   kernel killed it inside its own cgroup, leaving everything else alone."
  local ev
  ev=$(cat /sys/fs/cgroup/user.slice/user-"$(id -u)".slice/user@"$(id -u)".service/app.slice/chess-prep-ci-*/memory.events 2>/dev/null \
       | awk '/^oom_kill /{s+=$2} END{print s+0}')
  [[ -n "$ev" && "$ev" != "0" ]] && echo "──   (cgroup oom_kill counter: $ev)"
  echo "──   Find the leak first. Raise the ceiling only if the job genuinely needs"
  echo "──   it, e.g. CHESS_PREP_MEM_MAX=16G scripts/ci.sh …"
  echo "──"
}

# If a global OOM happens anyway, the kernel should pick a build over the
# user's editor and agent sessions (which sit at 200-300). Raising our own
# adjustment never needs privilege, and children inherit it.
echo 800 > /proc/self/oom_score_adj 2>/dev/null || true

# ---------------------------------------------------------------------------
# Tree hash — HEAD + every tracked change + untracked source files, so two
# identical trees share a cache entry and any edit invalidates it.
# ---------------------------------------------------------------------------
tree_hash() {
  {
    git rev-parse HEAD
    git diff HEAD -- lib test integration_test tools scripts .github \
      pubspec.yaml pubspec.lock analysis_options.yaml
    git ls-files --others --exclude-standard -z \
      lib test integration_test tools scripts .github \
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
#
# `} 9>&-` on the function itself, and it is load-bearing. The heavy steps run
# `capped … | tee "$log"`, and a pipeline forks two more processes that inherit
# the lock fd — the subshell running the left-hand side, and `tee`. Closing the
# fd inside `capped` alone left those two holding the lock after a SIGKILLed
# run, which is the whole failure this is here to prevent. Closing it for the
# function covers everything the function forks, including future pipelines
# nobody thought to annotate.
#
# It does not release the lock: bash saves fd 9 across the redirection, so the
# open file description — and the flock on it — stays alive in this shell.
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
      if ! python3 scripts/check_file_mutations.py; then
        bad=1
      fi
      return $bad
      ;;
    tools)
      echo "── offline Python tool tests"
      scripts/test_tools.sh
      return $?
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
      capped "$FLUTTER" analyze lib test integration_test --no-fatal-infos 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
      # CI treats warnings as fatal; the exit code alone does not.
      if grep -qE '^\s*(error|warning) •' "$log"; then rc=1; fi
      ;;
    test)
      capped "$FLUTTER" test --coverage 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
      if [[ $rc -eq 0 ]]; then
        scripts/check_coverage.sh coverage/lcov.info 2>&1 | tee -a "$log"
        rc=${PIPESTATUS[0]}
      fi
      ;;
    integration)
      capped "$FLUTTER" test integration_test/app_test.dart -d linux 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
      ;;
  esac
  if [[ $rc -eq 0 ]]; then
    mv "$log" "$key"
  else
    echo "── $step FAILED (rc=$rc); full log: $log"
    explain_137 "$rc" "$step"
  fi
  return $rc
} 9>&-

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
case "${STEPS[0]}" in
  status)
    if ! flock -n "$LOCK" true 2>/dev/null; then
      [[ -r "$HOLDER" ]] && echo "lock held: $(cat "$HOLDER")" \
                         || echo "lock held by an unrecorded job"
      # Who is *actually* holding it, which is not always who the holder file
      # names. A lock outliving its owner used to look like a job that had run
      # for forty-five minutes; printing the real holders makes it one line.
      for pid in $(lock_holders); do
        printf '  holder pid %s · %s\n' \
          "$pid" "$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-70)"
      done
      if [[ -r "$HOLDER" ]]; then
        owner=$(awk '{print $2}' "$HOLDER")
        if [[ $owner =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
          echo "  ⚠ pid $owner is gone — the holders above are orphans."
          echo "    'scripts/ci.sh unlock' clears them."
        fi
      fi
    else
      echo "lock free"
    fi
    h=$(tree_hash)
    echo "tree $h; cached passes:"
    ls "$CACHE_DIR"/"$h".* 2>/dev/null | sed 's|.*/||' || true
    exit 0
    ;;
  unlock)
    # The escape hatch, and deliberately a narrow one: it never breaks a lock
    # held by a live ci.sh, only one whose holders are orphans. With `capped`
    # closing fd 9 this should be unreachable; it exists because the failure it
    # answers cost the whole machine 45 minutes and nobody could see why.
    sweep_stale_scopes
    if flock -n "$LOCK" true 2>/dev/null; then
      rm -f "$HOLDER"
      echo "lock was already free"
      exit 0
    fi
    killed=0
    for pid in $(lock_holders); do
      cmdline=$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-70)
      if [[ $cmdline == *ci.sh* || $cmdline == *driver.py* ]]; then
        echo "refusing: pid $pid is a live job — $cmdline"
        exit 1
      fi
      echo "killing orphaned holder $pid · $cmdline"
      kill "$pid" 2>/dev/null && killed=$((killed + 1))
    done
    sleep 2
    for pid in $(lock_holders); do kill -9 "$pid" 2>/dev/null || true; done
    if flock -n "$LOCK" true 2>/dev/null; then
      rm -f "$HOLDER"
      echo "lock released ($killed orphan(s) cleared)"
      exit 0
    fi
    echo "lock still held after clearing $killed process(es)" >&2
    exit 1
    ;;
  with)
    # scripts/ci.sh with -- cmd…   → run cmd under the lock, no caching,
    # in the directory the caller was in (so a worktree can use it).
    shift_n=1; [[ "${STEPS[1]:-}" == "--" ]] && shift_n=2
    CMD=("${STEPS[@]:$shift_n}")
    acquire_lock "${CMD[*]:0:3}"
    cd "$CALLER_PWD" && { capped "${CMD[@]}"; } 9>&-
    rc=$?
    explain_137 "$rc" "${CMD[*]:0:3}"
    exit $rc
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
