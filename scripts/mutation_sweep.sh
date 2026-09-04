#!/usr/bin/env bash
# Run a mutation campaign over every pair in scripts/mutation_targets.txt.
#
#   scripts/mutation_sweep.sh [--max N] [--seed N] [--out DIR] [target-file]
#
# The lock is taken PER TARGET, not for the whole sweep, so other agents can
# still slip their own test runs in between files. A full sweep is long — run
# it when you want the number, not before every commit.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

MAX=18; SEED=1; OUT=${CHESS_PREP_MUTATION_OUT:-/tmp/chess-prep-mutation-reports}
TARGETS=scripts/mutation_targets.txt
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max) MAX=$2; shift 2 ;;
    --seed) SEED=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) TARGETS=$1; shift ;;
  esac
done
mkdir -p "$OUT"

fail=0
while IFS='|' read -r lib test confirm; do
  [[ -z "$lib" || "$lib" == \#* ]] && continue
  name=$(basename "$lib" .dart)
  echo "======== $lib"
  # shellcheck disable=SC2086  # $confirm is a deliberate word list
  scripts/ci.sh with -- python3 scripts/mutation_test.py \
      --target "$lib" --tests "$test" --max "$MAX" --seed "$SEED" \
      ${confirm:+--confirm-tests $confirm} \
      --json "$OUT/$name.json" || fail=1
done < "$TARGETS"

echo
echo "──────── sweep summary"
python3 - "$OUT" <<'PY'
import json, glob, sys, os
out = sys.argv[1]
rows = []
for f in sorted(glob.glob(os.path.join(out, "*.json"))):
    d = json.load(open(f))
    rows.append((d["score"], d["killed"], d["valid"], d["target"]))
rows.sort()
for score, k, v, target in rows:
    print(f"  {score:5.0f}%  {k:>2}/{v:<2}  {target}")
if rows:
    tk = sum(r[1] for r in rows); tv = sum(r[2] for r in rows)
    print(f"\n  overall: {tk}/{tv} killed ({100*tk/tv:.0f}%)")
PY
exit $fail
