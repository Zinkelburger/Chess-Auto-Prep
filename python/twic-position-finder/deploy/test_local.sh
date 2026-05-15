#!/usr/bin/env bash
set -euo pipefail

# ── Local smoke test ─────────────────────────────────────────────
# Tests the full pipeline locally without sending emails.
# Run from python/twic-position-finder/

cd "$(dirname "$0")/.."

echo "==> Installing dependencies"
pip install -r requirements.txt -q

echo ""
echo "==> Downloading a single TWIC issue (#1637)"
python downloader.py -n 1637

echo ""
echo "==> Ingesting into positions.db"
python ingest.py data/twic1637.pgn

echo ""
echo "==> Querying: French Defense (1.e4 e6)"
python query.py "rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2" --limit 5

echo ""
echo "==> Opening tree from starting position"
python query.py "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1" --tree

echo ""
echo "==> Weekly dry run (no emails sent)"
python weekly.py --dry-run

echo ""
echo "==> Starting API server (Ctrl-C to stop)"
echo "    Try: curl http://localhost:8000/api/stats"
python server.py
