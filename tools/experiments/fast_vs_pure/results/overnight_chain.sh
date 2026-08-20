#!/usr/bin/env bash
cd "$(dirname "$0")/../../../.."
S=tools/experiments/fast_vs_pure/run_overnight.sh
R=tools/experiments/fast_vs_pure/results
echo "chain start $(date -Is)"
MAX_PLY=8  EVAL_DEPTH=14 THREADS=6 BUDGET_MIN=0   $S $R/ply8_d14
MAX_PLY=10 EVAL_DEPTH=14 THREADS=6 BUDGET_MIN=240 $S $R/ply10_d14
echo "chain done $(date -Is)"
