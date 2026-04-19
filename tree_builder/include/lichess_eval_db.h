/**
 * lichess_eval_db.h - Read-only Lichess eval cache lookup.
 *
 * Thin wrapper around the slim SQLite DB produced by build_lichess_eval_db.
 * Schema:  lichess_evals(fen PK, move, cp, mate, depth)
 *
 * Used by the tree builder to short-circuit Stockfish single-PV calls on
 * opponent-move nodes when a Lichess community eval already exists at
 * sufficient depth.  Lookups are microsecond-scale; a hit replaces a
 * ~400ms Stockfish call with a B-tree seek.
 *
 * The FEN passed to lookup() is canonicalized internally to the 4-field
 * form Lichess uses (pieces, side-to-move, castling, en passant).
 *
 * Convention: `out_eval_cp` is returned using the same STM-perspective
 * convention as the rest of the codebase (matches `engine_eval_cp` on
 * TreeNode).  Mate scores are mapped to the same ±10000−N encoding that
 * engine_pool uses so callers can treat a hit identically to a Stockfish
 * EvalJob.
 */

#ifndef LICHESS_EVAL_DB_H
#define LICHESS_EVAL_DB_H

#include <stdbool.h>

typedef struct LichessEvalDB LichessEvalDB;

/**
 * Open the eval DB (read-only).  Returns NULL if the file is missing,
 * unreadable, or has the wrong schema.  Prints a diagnostic on failure.
 */
LichessEvalDB* lichess_eval_db_open(const char *path);

/**
 * Close and free the DB handle.  Safe to call with NULL.
 */
void lichess_eval_db_close(LichessEvalDB *db);

/**
 * Look up a position.
 *
 * @param db            Handle (may be NULL — treated as a miss)
 * @param fen           Full FEN (will be canonicalized internally)
 * @param out_eval_cp   STM-perspective cp (mate mapped to ±10000−N)
 * @param out_depth     Search depth of the cached eval
 * @return true if a row was found
 */
bool lichess_eval_db_lookup(LichessEvalDB *db, const char *fen,
                             int *out_eval_cp, int *out_depth);

/**
 * Reports the number of rows in the DB (for banner/diagnostics).
 * Returns -1 on NULL handle or query failure.
 */
long lichess_eval_db_count(LichessEvalDB *db);

#endif /* LICHESS_EVAL_DB_H */
