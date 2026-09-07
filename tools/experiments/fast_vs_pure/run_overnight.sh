#!/usr/bin/env bash
# Historical entrypoint; now runs a bounded, paired Fast/Pure benchmark.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"
exec scripts/ci.sh with -- python3 tools/experiments/fast_vs_pure/benchmark.py "$@"
