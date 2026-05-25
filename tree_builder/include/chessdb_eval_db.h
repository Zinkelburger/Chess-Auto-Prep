/**
 * chessdb_eval_db.h - Read-only ChessDB local SQLite eval lookup.
 *
 * Schema matches lichess_eval_db:
 *   chessdb_evals(fen TEXT PRIMARY KEY, move TEXT, cp INT, mate INT, depth INT)
 *
 * Also exposes an EvalSource wrapper via chessdb_eval_db_as_source().
 */

#ifndef CHESSDB_EVAL_DB_H
#define CHESSDB_EVAL_DB_H

#include "eval_source.h"
#include <stdbool.h>

typedef struct ChessDBEvalDB ChessDBEvalDB;

ChessDBEvalDB *chessdb_eval_db_open(const char *path);
void chessdb_eval_db_close(ChessDBEvalDB *db);

bool chessdb_eval_db_lookup(ChessDBEvalDB *db, const char *fen,
                            int *out_eval_cp, int *out_depth);

/** Full lookup with shallow / hard_miss flags. */
void chessdb_eval_db_lookup_result(ChessDBEvalDB *db, const char *fen,
                                   int min_depth, EvalLookupResult *out);

long chessdb_eval_db_count(ChessDBEvalDB *db);

/** Wrap as EvalSource (caller must eval_source_destroy). */
EvalSource *chessdb_eval_db_as_source(ChessDBEvalDB *db);

#endif /* CHESSDB_EVAL_DB_H */
