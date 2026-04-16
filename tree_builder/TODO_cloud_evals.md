# TODO: Download Lichess Cloud Evals

## What

Download the full Lichess evaluated-positions database (~369M positions) and
import it into our local SQLite cache so tree builds get free depth 40-55 evals
from DB hits instead of computing depth 20 locally.

**Download URL:** `https://database.lichess.org/lichess_db_eval.jsonl.zst`

- Compressed: ~19 GB (zstd)
- Uncompressed: ~100-190 GB (JSONL, one position per line)
- Last updated: 2026-04-02
- Format: JSONL with FEN, multiple evals at varying PV counts and depths

## Steps

1. Download `lichess_db_eval.jsonl.zst`
2. Decompress with `zstd -d` (need ~200 GB free disk)
3. Parse JSONL and import into SQLite — index by FEN
4. Wire into `rdb_get_eval` / `rdb_get_multipv` so cache hits return cloud
   evals instead of running local Stockfish

## Known issues / things to figure out

- **Not all PVs may be present at the depth we want.** Each position can have
  multiple eval entries with different PV counts (1, 2, 3, ...). Our tree
  builder requests MultiPV 5 — the cloud data may only have 1-3 PVs for many
  positions, or have 5 PVs but at a shallower depth than the 1-PV entry.
  Need to decide: do we prefer deeper 1-PV data or shallower 5-PV data?

- **FEN normalization.** Lichess drops the en-passant square from FENs when
  no en-passant capture is actually legal. Our FENs may include the EP square
  even when no capture is possible (e.g. `e3` after `1. e4`). Lookups will
  miss unless we normalize FENs to match Lichess's convention.

- **Disk space.** The uncompressed JSONL is ~100-190 GB. Importing into SQLite
  with an index on FEN will likely be 50-100+ GB on disk. Need to decide where
  to store this — probably a shared system-wide DB rather than per-repertoire.

- **Import time.** Parsing 369M JSON lines and inserting into SQLite will take
  a while. Should be a one-time setup script with progress reporting. Probably
  want WAL mode + batched transactions (e.g. commit every 100K rows).

- **Eval format mismatch.** Cloud evals store `cp` and `line` (UCI move
  sequence). Our `evaluations` table stores `eval_cp`, `depth`, `bestmove`,
  `pv`. Our `multipv_cache` uses a packed binary blob. Need an adapter or a
  separate table for cloud evals.

- **Freshness.** Lichess updates this dump periodically. May want a script to
  re-download and diff/update.

- **Cloud API prefetch as alternative.** For small repertoires (< 1000
  positions) it may be simpler to just query the cloud eval API one position
  at a time before the build starts, caching results locally. Rate limited to
  ~0.7 pos/sec so ~25 min for 1000 positions. Not viable for the full dump
  but fine for warming the cache for a specific opening.
