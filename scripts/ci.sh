#!/usr/bin/env bash
# Focused local checks. Full batch checks run in .github/workflows/ci.yml.
# ci.sh [analyze|lint|format|test [FILES/OPTIONS...]|tools|integration [FILES...]|profile [FILE]|full]
# ci.sh with -- COMMAND... runs any heavy command under the same limits.
set -uo pipefail
CALLER_PWD=$PWD
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
FLUTTER=${FLUTTER:-$HOME/sdk/flutter/bin/flutter}
[[ -x "$FLUTTER" ]] || FLUTTER=$(command -v flutter || true)
DART="$(dirname "$FLUTTER")/dart"
JOB=(python3 "$ROOT/scripts/agent_job.py")
[[ ${1:-} == --fresh ]] && shift  # Compatibility; local checks no longer cache.
[[ $# -gt 0 ]] || set -- analyze lint

run_step() {
  local step=$1
  shift
  case "$step" in
    format)
      "$DART" format lib test integration_test
      ;;
    lint)
      echo "── lint greps"
      local bad=0
      if grep -rlE "import '.*(widgets/|screens/)" lib/core lib/models lib/services lib/utils 2>/dev/null; then
        echo "lint: layering violation (core/models/services/utils importing widgets/screens)"; bad=1
      fi
      local feat
      feat=$(grep -rlE "import '.*(widgets/|screens/)" lib/features/*/controllers lib/features/*/services lib/features/*/models 2>/dev/null || true)
      if [[ -n "$feat" ]]; then
        echo "$feat"; echo "lint: feature non-widget layer importing widgets/screens"; bad=1
      fi
      if grep -rnE "fontSize: (9|10|10\.5|11|11\.5)[,)]" lib | grep -v board_coordinates; then
        echo "lint: fontSize below the 12px floor"; bad=1
      fi
      if ! python3 scripts/test_architecture_boundaries.py; then
        bad=1
      fi
      if ! python3 scripts/test_ci_dispatch.py; then
        bad=1
      fi
      if ! python3 scripts/check_architecture_boundaries.py; then
        bad=1
      fi
      if ! python3 scripts/check_file_mutations.py; then
        bad=1
      fi
      if ! python3 scripts/sync_agent_rules.py --check; then
        bad=1
      fi
      return $bad
      ;;
    analyze)
      "${JOB[@]}" run -- "$FLUTTER" gen-l10n || return $?
      local targets=(lib test integration_test widgetbook)
      [[ ! -d test_driver ]] || targets+=(test_driver)
      "${JOB[@]}" run -- "$FLUTTER" analyze "${targets[@]}" --no-fatal-infos
      ;;
    test)
      "${JOB[@]}" run -- "$FLUTTER" gen-l10n || return $?
      "${JOB[@]}" run -- "$FLUTTER" test --concurrency=2 "$@"
      ;;
    tools)
      "${JOB[@]}" run -- bash scripts/test_tools.sh
      ;;
    profile)
      "${JOB[@]}" run -- "$FLUTTER" gen-l10n || return $?
      local target=${1:-integration_test/renewal_performance_test.dart}
      if [[ $# -gt 1 ]]; then
        echo 'ci.sh profile accepts one integration target' >&2
        return 2
      fi
      "${JOB[@]}" run --headless -- "$FLUTTER" drive --profile -d linux \
        --driver=test_driver/renewal_profile_driver.dart --target="$target"
      ;;
    integration)
      "${JOB[@]}" run -- "$FLUTTER" gen-l10n || return $?
      local targets=("$@")
      [[ ${#targets[@]} -gt 0 ]] || targets=(integration_test/app_test.dart)
      # Each executable gets its own display/bus. Reusing one Flutter device
      # session for multiple native test files can retain its debug connection.
      local target
      for target in "${targets[@]}"; do
        "${JOB[@]}" run --headless -- "$FLUTTER" test "$target" -d linux || return $?
      done
      ;;
    *) echo "ci.sh: unknown step '$step'" >&2; return 2 ;;
  esac
}

case "$1" in
  status) exec "${JOB[@]}" status ;;
  unlock)
    echo 'Jobs release reservations automatically. No process is killed by unlock.'
    exec "${JOB[@]}" status ;;
  with)
    shift
    [[ ${1:-} == -- ]] && shift
    cd "$CALLER_PWD"
    exec "${JOB[@]}" run -- "$@" ;;
  full) set -- format analyze test tools lint integration ;;
  -h|--help)
    sed -n '2,4p' "$0"; exit 0 ;;
esac

# A test followed by paths/options is a focused run; otherwise accept the
# familiar list of named steps (e.g. analyze test lint).
if [[ ( $1 == test || $1 == integration || $1 == profile ) && $# -gt 1 ]]; then
  case "$2" in
    format|analyze|test|tools|lint|integration|profile) ;;
    *) step=$1; shift; run_step "$step" "$@"; exit $? ;;
  esac
fi
# Validate the whole named-step batch before launching any job. Otherwise
# `analyze lint test test/foo.dart` silently starts the entire suite and only
# discovers the misplaced target after that expensive run has finished.
for step in "$@"; do
  case "$step" in
    format|analyze|test|tools|lint|integration|profile) ;;
    *)
      echo "ci.sh: unknown step '$step'. Run focused tests separately: scripts/ci.sh test PATH..." >&2
      exit 2
      ;;
  esac
done
for step in "$@"; do
  echo "── $step"
  run_step "$step" || exit $?
done
echo "── all green: $*"
