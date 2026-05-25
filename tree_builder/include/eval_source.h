/**
 * eval_source.h - Generic evaluation lookup interface.
 *
 * Backends (Lichess SQLite, ChessDB SQLite, ChessDB API, mock) share one
 * contract so tree.c can walk a uniform 3-phase eval chain.
 */

#ifndef EVAL_SOURCE_H
#define EVAL_SOURCE_H

#include <stdbool.h>

typedef struct EvalLookupResult {
    bool found;       /* qualifying eval available */
    bool shallow;     /* row/score found but depth below min_depth */
    bool hard_miss;   /* local DB: FEN absent (triggers subtree skip) */
    int  eval_cp;     /* STM-perspective centipawns (mate mapped) */
    int  mate;        /* raw mate plies when source reports mate, else 0 */
    int  depth;       /* search depth when known */
} EvalLookupResult;

typedef struct EvalSource EvalSource;

struct EvalSource {
    void *ctx;
    void (*lookup)(void *ctx, const char *fen, int min_depth,
                   EvalLookupResult *out);
    void (*close_fn)(void *ctx);
};

/** Release backend resources and free the EvalSource wrapper. */
void eval_source_destroy(EvalSource *src);

/** Initialize out to a clean miss. */
void eval_lookup_result_clear(EvalLookupResult *out);

/**
 * Map raw cp/mate columns (Lichess/ChessDB SQLite schema) to engine_eval_cp.
 * Returns false when neither cp nor mate is present.
 */
bool eval_map_sqlite_score(int cp_val, int cp_null, int mate_val, int mate_null,
                           int *out_eval_cp, int *out_mate);

/** Truncate FEN to 4 fields in-place (transposition key). */
void eval_canonicalize_fen(char *fen);

#endif /* EVAL_SOURCE_H */
