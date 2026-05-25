/**
 * eval_chain.c - see eval_chain.h
 */

#include "eval_chain.h"
#include "cdbdirect_eval.h"
#include "chessdb_eval_db.h"
#include "lichess_eval_db.h"
#include "chessdb_api.h"

#include <stddef.h>

#define STATS_INC(ctx, field) \
    do { if ((ctx)->stats) (ctx)->stats->field++; } while (0)

static void maybe_mark_subtree_skip(TreeNode *node, const EvalChainContext *ctx,
                                    bool local_hard_miss, bool local_hit) {
    if (local_hard_miss && !local_hit && ctx->ext_eval_subtree_skip)
        node->skip_ext_eval = true;
}

bool eval_chain_try_external(TreeNode *node, const EvalChainContext *ctx,
                             int *out_cp, int *out_depth,
                             const char **out_src_label) {
    if (!node || !ctx) return false;

    if (node->skip_ext_eval) {
        STATS_INC(ctx, ext_eval_skipped);
        return false;
    }

    int min_depth = ctx->eval_depth;
    bool local_hard_miss = false;
    bool local_hit = false;

    if (ctx->cdbdirect) {
        EvalLookupResult r;
        cdbdirect_eval_lookup_result(ctx->cdbdirect, node->fen, min_depth, &r);
        if (r.hard_miss) {
            STATS_INC(ctx, cdbdirect_misses);
            local_hard_miss = true;
        } else if (r.found && !r.shallow) {
            STATS_INC(ctx, cdbdirect_hits);
            local_hit = true;
            if (out_cp) *out_cp = r.eval_cp;
            if (out_depth) *out_depth = r.depth;
            if (out_src_label) *out_src_label = "cdbdirect";
            return true;
        } else if (r.found && r.shallow) {
            STATS_INC(ctx, cdbdirect_shallow);
        }
    }

    if (ctx->chessdb_eval_db) {
        EvalLookupResult r;
        chessdb_eval_db_lookup_result(ctx->chessdb_eval_db, node->fen,
                                      min_depth, &r);
        if (r.hard_miss) {
            STATS_INC(ctx, chessdb_local_misses);
            local_hard_miss = true;
        } else if (r.found && !r.shallow) {
            STATS_INC(ctx, chessdb_local_hits);
            local_hit = true;
            if (out_cp) *out_cp = r.eval_cp;
            if (out_depth) *out_depth = r.depth;
            if (out_src_label) *out_src_label = "chessdb_local";
            return true;
        } else if (r.found && r.shallow) {
            STATS_INC(ctx, chessdb_local_shallow);
        }
    }

    if (ctx->lichess_eval_db) {
        EvalLookupResult r;
        lichess_eval_db_lookup_result(ctx->lichess_eval_db, node->fen,
                                      min_depth, &r);
        if (r.hard_miss) {
            STATS_INC(ctx, lichess_eval_db_misses);
            local_hard_miss = true;
        } else if (r.found && !r.shallow) {
            STATS_INC(ctx, lichess_eval_db_hits);
            local_hit = true;
            if (out_cp) *out_cp = r.eval_cp;
            if (out_depth) *out_depth = r.depth;
            if (out_src_label) *out_src_label = "lichess_db";
            return true;
        } else if (r.found && r.shallow) {
            STATS_INC(ctx, lichess_eval_db_shallow);
        }
    }

    maybe_mark_subtree_skip(node, ctx, local_hard_miss, local_hit);

    if (ctx->chessdb_api && chessdb_api_is_enabled(ctx->chessdb_api)) {
        if (!chessdb_api_quota_remaining(ctx->chessdb_api)) {
            STATS_INC(ctx, chessdb_api_quota_exhausted);
        } else {
            int cp = 0, depth = 0;
            if (chessdb_api_query_score(ctx->chessdb_api, node->fen, &cp, &depth)) {
                STATS_INC(ctx, chessdb_api_hits);
                if (out_cp) *out_cp = cp;
                if (out_depth) *out_depth = depth;
                if (out_src_label) *out_src_label = "chessdb_api";
                return true;
            }
            STATS_INC(ctx, chessdb_api_misses);
        }
    }

    return false;
}
