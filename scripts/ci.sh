#!/usr/bin/env bash
# Focused local checks. Full PR checks remain in .github/workflows/ci.yml.
# ci.sh [analyze|lint|format|test [FILES/OPTIONS...]|tools|integration|full]
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
    analyze)
      "${JOB[@]}" run -- "$FLUTTER" analyze lib test integration_test --no-fatal-infos
      ;;
    test)
      if [[ $# -gt 0 ]]; then
        "${JOB[@]}" run -- "$FLUTTER" test --concurrency=2 "$@"
      else
        "${JOB[@]}" run -- "$FLUTTER" test --concurrency=2 --coverage &&
          scripts/check_coverage.sh coverage/lcov.info
      fi
      ;;
    tools)
      "${JOB[@]}" run -- bash scripts/test_tools.sh
      ;;
    integration)
      "${JOB[@]}" run --headless -- "$FLUTTER" test integration_test/app_test.dart -d linux
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
if [[ $1 == test && $# -gt 1 ]]; then
  case "$2" in
    format|analyze|test|tools|lint|integration) ;;
    *) shift; run_step test "$@"; exit $? ;;
  esac
fi
for step in "$@"; do
  echo "── $step"
  run_step "$step" || exit $?
done
echo "── all green: $*"
