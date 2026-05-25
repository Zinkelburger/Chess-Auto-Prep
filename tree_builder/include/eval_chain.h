/**
 * eval_chain.h - 3-phase external eval lookup (local DBs → API).
 *
 * Used by tree.c ensure_eval / build_our_move and unit tests.
 */

#ifndef EVAL_CHAIN_H
#define EVAL_CHAIN_H

#include "eval_source.h"
#include "tree.h"
#include "node.h"

struct ChessDBEvalDB;
struct ChessDBAPI;
struct CdbDirectEval;
struct LichessEvalDB;

typedef struct EvalChainContext {
    struct CdbDirectEval   *cdbdirect;
    struct ChessDBEvalDB *chessdb_eval_db;
    struct LichessEvalDB *lichess_eval_db;
    struct ChessDBAPI    *chessdb_api;
    int                   eval_depth;
    bool                  ext_eval_subtree_skip;
    BuildStats           *stats;
} EvalChainContext;

/**
 * Try cdbdirect → ChessDB local → Lichess local → ChessDB API.
 * Respects node->skip_ext_eval.  On local hard miss (no shallow-only),
 * may set node->skip_ext_eval for descendants when ext_eval_subtree_skip.
 *
 * @return true if a depth-qualified eval was found
 */
bool eval_chain_try_external(TreeNode *node, const EvalChainContext *ctx,
                             int *out_cp, int *out_depth,
                             const char **out_src_label);

#endif /* EVAL_CHAIN_H */
