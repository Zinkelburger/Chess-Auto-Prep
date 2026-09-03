"""The opening book's schema, shared verbatim with the Dart reader.

Modelled on the master-games `book` table
(`lib/services/master_games/master_games_db.dart`), because the explorer in
front of it is the same shape: a position key, one row per continuation, and
the aggregate a move list needs.

Two tables rather than one.  `edge` is pruned -- a continuation played once
in twenty years is noise, and keeping the singletons multiplies the book by
six for nothing.  `node` is aggregated *before* that pruning, so a position
can honestly say "1,240 games" while listing only the twelve continuations
worth showing.  Without the split, pruning would silently deflate every
total in the explorer.
"""

from __future__ import annotations

SCHEMA_VERSION = 1

CREATE_SQL = """
CREATE TABLE IF NOT EXISTS edge(
  pos      INTEGER NOT NULL,   -- FNV-1a of the canonical dual FEN
  move     TEXT    NOT NULL,   -- 'A:e4', 'b:N@f3' -- board+mover, then SAN
  games    INTEGER NOT NULL,
  team_a   INTEGER NOT NULL,   -- games won by WhiteA's team (result '1-0')
  team_b   INTEGER NOT NULL,   -- games won by BlackA's team (result '0-1')
  draws    INTEGER NOT NULL,
  unknown  INTEGER NOT NULL,   -- result '*': aborted, adjourned, disconnected
  elo_sum  INTEGER NOT NULL,   -- sum of the 4-player average, for a mean
  elo_n    INTEGER NOT NULL,
  max_elo  INTEGER NOT NULL,
  last_year INTEGER NOT NULL,
  top_game INTEGER NOT NULL,   -- BughouseDBGameNo of the strongest game
  PRIMARY KEY(pos, move)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS node(
  pos      INTEGER PRIMARY KEY,
  games    INTEGER NOT NULL,
  team_a   INTEGER NOT NULL,
  team_b   INTEGER NOT NULL,
  draws    INTEGER NOT NULL,
  unknown  INTEGER NOT NULL,
  moves    INTEGER NOT NULL    -- distinct continuations kept in `edge`
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS meta(
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"""

# Merging a worker's partial book into the accumulating one.  Every SET's
# right-hand side sees the pre-update row, so `top_game` can test the old
# `max_elo` even though the same statement replaces it.
MERGE_SQL = """
INSERT INTO edge SELECT * FROM part.edge WHERE true
ON CONFLICT(pos, move) DO UPDATE SET
  games     = edge.games    + excluded.games,
  team_a    = edge.team_a   + excluded.team_a,
  team_b    = edge.team_b   + excluded.team_b,
  draws     = edge.draws    + excluded.draws,
  unknown   = edge.unknown  + excluded.unknown,
  elo_sum   = edge.elo_sum  + excluded.elo_sum,
  elo_n     = edge.elo_n    + excluded.elo_n,
  top_game  = CASE WHEN excluded.max_elo > edge.max_elo
                   THEN excluded.top_game ELSE edge.top_game END,
  max_elo   = MAX(edge.max_elo,   excluded.max_elo),
  last_year = MAX(edge.last_year, excluded.last_year)
"""
