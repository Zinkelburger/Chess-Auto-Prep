/**
 * cdbdirect_eval.h - TerarkDB ChessDB dump lookup via cdbdirect.
 *
 * When built with HAS_CDBDIRECT, links against libcdbdirect + TerarkDB.
 * Response parsing and directory validation compile without TerarkDB.
 *
 * FEN keys use 4-field canonical form; cdbdirect expects strict X-FEN EP
 * (positions from tree nodes already satisfy this via position_to_fen).
 */

#ifndef CDBDIRECT_EVAL_H
#define CDBDIRECT_EVAL_H

#include "eval_source.h"
#include <stdbool.h>
#include <stddef.h>

typedef struct CdbDirectEval CdbDirectEval;

/**
 * Parse cdbdirect_get response string.
 *
 * Supports:
 *   move:e2e4,score:30,rank:0,...|move:d2d4,score:25,...
 *   e2e4:30|d2d4:25
 *   eval:42
 *
 * Returns false on NULL, empty, "unknown", or unparseable input.
 * [out_eval_cp] is STM-perspective centipawns (best / first ranked move).
 */
bool cdbdirect_parse_response(const char *response, int *out_eval_cp,
                              int *out_depth, char *out_best_move,
                              size_t best_move_cap);

/** True when [path] looks like a TerarkDB data directory. */
bool cdbdirect_validate_data_dir(const char *path);

CdbDirectEval *cdbdirect_eval_open(const char *path, bool read_ahead_hint);
void cdbdirect_eval_close(CdbDirectEval *h);

long cdbdirect_eval_count(CdbDirectEval *h);

void cdbdirect_eval_lookup_result(CdbDirectEval *h, const char *fen,
                                  int min_depth, EvalLookupResult *out);

/** Wrap as EvalSource (caller must eval_source_destroy). */
EvalSource *cdbdirect_eval_as_source(CdbDirectEval *h);

/**
 * Prefetch evals for [fens] (sorted for HDD locality) into an internal cache.
 * Used when --batch-eval-lookups is enabled.
 */
void cdbdirect_eval_prefetch(CdbDirectEval *h, const char **fens, size_t count);

#endif /* CDBDIRECT_EVAL_H */
