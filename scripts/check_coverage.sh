#!/usr/bin/env bash
# Enforce the repository's line-coverage floor without requiring lcov tools.
set -euo pipefail

LCOV_FILE=${1:-coverage/lcov.info}
MINIMUM=${COVERAGE_MINIMUM:-55.0}

if [[ ! -s "$LCOV_FILE" ]]; then
  echo "coverage: missing or empty report: $LCOV_FILE" >&2
  exit 2
fi

read -r COVERED TOTAL < <(
  awk -F'[:,]' '
    /^DA:/ {
      total++
      if ($3 > 0) covered++
    }
    END { print covered + 0, total + 0 }
  ' "$LCOV_FILE"
)

if [[ "$TOTAL" -eq 0 ]]; then
  echo "coverage: report contains no executable lines: $LCOV_FILE" >&2
  exit 2
fi

PERCENT=$(awk -v covered="$COVERED" -v total="$TOTAL" \
  'BEGIN { printf "%.1f", covered * 100 / total }')
echo "coverage: $COVERED/$TOTAL lines ($PERCENT%; minimum $MINIMUM%)"

awk -v actual="$PERCENT" -v minimum="$MINIMUM" \
  'BEGIN { exit(actual + 0 < minimum + 0) }' || {
    echo "coverage: below the required floor" >&2
    exit 1
  }
