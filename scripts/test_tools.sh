#!/usr/bin/env bash
# Deterministic, offline tests for the Python tooling shipped with the repo.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

TESTS=(
  tools/test_agent_jobs.py
  tools/test_file_mutation_lint.py
  tools/verify_maia_model.py
  tools/test_vc_redist.py
  tools/mcp/test_chess_prep.py
  tools/mcp/test_opening_tree.py
  tools/mcp/test_expectimax.py
  tools/mcp/test_engine_tournament.py
  tools/mcp/test_master_games.py
  tools/mcp/test_chessdb.py
  tools/mcp/test_bughouse.py
  tools/test_bughouse_db.py
)

for test_file in "${TESTS[@]}"; do
  echo "── $test_file"
  PYTHONWARNINGS=error::ResourceWarning python3 "$test_file"
done
