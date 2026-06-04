/**
 * tree_db_build.c - Phase-1 DB explorer tree construction from PgnFreqMap
 */

#include "tree_db_build.h"
#include "fen_map.h"
#include "chess_logic.h"
#include "san_convert.h"
#include "database.h"
#include "engine_pool.h"
#include "eval_chain.h"
#include "progress_line.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

extern volatile int g_interrupted;

typedef struct DbBuildQueue {
    TreeNode **items;
    size_t head;
    size_t tail;
    size_t capacity;
} DbBuildQueue;

static bool db_queue_init(DbBuildQueue *q) {
    q->capacity = 256;
    q->head = q->tail = 0;
    q->items = (TreeNode **)calloc(q->capacity, sizeof(TreeNode *));
    return q->items != NULL;
}

static void db_queue_destroy(DbBuildQueue *q) {
    free(q->items);
    q->items = NULL;
    q->head = q->tail = q->capacity = 0;
}

static bool db_queue_grow(DbBuildQueue *q) {
    size_t len = q->tail - q->head;
    size_t new_cap = q->capacity * 2;
    TreeNode **ni = (TreeNode **)calloc(new_cap, sizeof(TreeNode *));
    if (!ni) return false;
    for (size_t i = 0; i < len; i++)
        ni[i] = q->items[q->head + i];
    free(q->items);
    q->items = ni;
    q->head = 0;
    q->tail = len;
    q->capacity = new_cap;
    return true;
}

static bool db_queue_push(DbBuildQueue *q, TreeNode *node) {
    if (q->tail >= q->capacity && !db_queue_grow(q))
        return false;
    q->items[q->tail++] = node;
    return true;
}

static TreeNode *db_queue_pop(DbBuildQueue *q) {
    if (q->head >= q->tail) return NULL;
    return q->items[q->head++];
}

static bool apply_uci(const char *fen, const char *uci,
                      char *out_fen, size_t out_len) {
    ChessPosition pos;
    if (!position_from_fen(&pos, fen)) return false;
    if (!position_apply_uci(&pos, uci)) return false;
    position_to_fen(&pos, out_fen, out_len);
    return true;
}

static TreeNode *make_child(TreeNode *parent, const char *fen,
                            const char *san, const char *uci,
                            Tree *tree) {
    for (size_t i = 0; i < parent->children_count; i++) {
        if (strcmp(parent->children[i]->fen, fen) == 0)
            return NULL;
    }

    TreeNode *child = node_create(fen, san, uci, parent);
    if (!child) return NULL;
    if (!node_add_child(parent, child)) {
        node_destroy_single(child);
        return NULL;
    }
    tree->total_nodes++;
    if (child->depth > tree->max_depth_reached)
        tree->max_depth_reached = child->depth;
    return child;
}

static bool propagate_cumP_recursive(TreeNode *node, double ratio,
                                     double min_prob, DbBuildQueue *q) {
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        child->cumulative_probability *= ratio;
        if (child->children_count > 0) {
            if (!propagate_cumP_recursive(child, ratio, min_prob, q))
                return false;
        } else if (!child->explored &&
                   child->cumulative_probability >= min_prob) {
            if (!db_queue_push(q, child))
                return false;
        }
    }
    return true;
}

static bool propagate_higher_cumP(TreeNode *canonical, double new_cumP,
                                const DbBuildConfig *cfg, DbBuildQueue *q) {
    if (!canonical || new_cumP <= canonical->cumulative_probability) return true;
    double ratio = new_cumP / canonical->cumulative_probability;
    canonical->cumulative_probability = new_cumP;
    return propagate_cumP_recursive(canonical, ratio, cfg->min_probability, q);
}

static bool expand_our_move(Tree *tree, TreeNode *node,
                            const PgnFreqPosition *pos,
                            const DbBuildConfig *cfg, DbBuildQueue *q) {
    char san_buf[MAX_MOVE_LENGTH];

    for (int i = 0; i < pos->move_count; i++) {
        if (cfg->max_nodes > 0 &&
            tree->total_nodes >= (size_t)cfg->max_nodes)
            break;

        const PgnFreqMove *m = &pos->moves[i];
        char child_fen[MAX_FEN_LENGTH];
        if (!apply_uci(node->fen, m->uci, child_fen, MAX_FEN_LENGTH))
            continue;

        const char *san = m->san[0] ? m->san : m->uci;
        if (!m->san[0] &&
            uci_to_san(node->fen, m->uci, san_buf, sizeof(san_buf)))
            san = san_buf;

        TreeNode *child = make_child(node, child_fen, san, m->uci, tree);
        if (!child) continue;

        child->move_probability = 1.0;
        child->cumulative_probability = node->cumulative_probability;
        if (!db_queue_push(q, child))
            return false;
    }
    return true;
}

static bool expand_opponent_move(Tree *tree, TreeNode *node,
                                 const PgnFreqPosition *pos,
                                 const DbBuildConfig *cfg, DbBuildQueue *q) {
    char san_buf[MAX_MOVE_LENGTH];
    PgnFreqMove filtered[MAX_CHILDREN];
    int n_filtered = pgn_freq_filtered_moves(pos, cfg->db_min_games,
                                             cfg->db_min_prob,
                                             filtered, MAX_CHILDREN);

    uint64_t reach = pos->reach_count;
    if (reach == 0) {
        for (int i = 0; i < pos->move_count; i++)
            reach += pos->moves[i].count;
    }
    if (reach == 0) return true;

    for (int i = 0; i < n_filtered; i++) {
        if (cfg->max_nodes > 0 &&
            tree->total_nodes >= (size_t)cfg->max_nodes)
            break;

        const PgnFreqMove *m = &filtered[i];
        double prob = (double)m->count / (double)reach;
        double new_cumul = node->cumulative_probability * prob;
        if (new_cumul < cfg->min_probability) continue;

        char child_fen[MAX_FEN_LENGTH];
        if (!apply_uci(node->fen, m->uci, child_fen, MAX_FEN_LENGTH))
            continue;

        const char *san = m->san[0] ? m->san : m->uci;
        if (!m->san[0] &&
            uci_to_san(node->fen, m->uci, san_buf, sizeof(san_buf)))
            san = san_buf;

        TreeNode *child = make_child(node, child_fen, san, m->uci, tree);
        if (!child) continue;

        child->move_probability = prob;
        child->cumulative_probability = new_cumul;
        if (!db_queue_push(q, child))
            return false;
    }
    return true;
}

static bool process_node(Tree *tree, TreeNode *node,
                         const PgnFreqMap *freq,
                         const DbBuildConfig *cfg,
                         FenMap *fmap, DbBuildQueue *q) {
    if (node->depth >= cfg->max_depth) {
        node->explored = true;
        return true;
    }
    if (node->cumulative_probability < cfg->min_probability) {
        node->explored = true;
        return true;
    }
    if (cfg->max_nodes > 0 &&
        tree->total_nodes >= (size_t)cfg->max_nodes) {
        node->explored = true;
        return true;
    }

    const PgnFreqPosition *pos = pgn_freq_get(freq, node->fen);
    if (!pos || pos->move_count == 0) {
        node->explored = true;
        return true;
    }

    node->total_games = pos->reach_count;

    /* Transposition detection (same ring logic as tree.c build_process_node) */
    TreeNode *canonical = fen_map_get(fmap, node->fen);
    if (canonical) {
        if (canonical->next_equivalent) {
            node->next_equivalent = canonical->next_equivalent;
        } else {
            node->next_equivalent = canonical;
        }
        canonical->next_equivalent = node;
        node->explored = true;

        if (node->cumulative_probability > canonical->cumulative_probability &&
            !propagate_higher_cumP(canonical, node->cumulative_probability,
                                   cfg, q))
            return false;
        return true;
    }
    if (!fen_map_put(fmap, node->fen, node))
        return false;

    bool is_our_move = (node->is_white_to_move == cfg->play_as_white);
    if (is_our_move) {
        if (!expand_our_move(tree, node, pos, cfg, q))
            return false;
    } else if (!expand_opponent_move(tree, node, pos, cfg, q)) {
        return false;
    }

    node->explored = true;
    return true;
}

bool tree_build_from_freqmap(Tree *tree, const PgnFreqMap *freq,
                             const DbBuildConfig *cfg) {
    if (!tree || !freq || !cfg || !cfg->start_fen)
        return false;

    if (!tree->root) {
        tree->root = node_create(cfg->start_fen, NULL, NULL, NULL);
        if (!tree->root) return false;
        tree->total_nodes = 1;
        tree->max_depth_reached = 0;
    }

    tree->config.play_as_white = cfg->play_as_white;
    tree->config.max_depth = cfg->max_depth;
    tree->config.min_probability = cfg->min_probability;
    tree->config.max_nodes = cfg->max_nodes;
    tree->config.build_mode = BUILD_MODE_DB_EXPLORER;

    const PgnFreqPosition *root_pos = pgn_freq_get(freq, tree->root->fen);
    if (root_pos)
        tree->root->total_games = root_pos->reach_count;
    tree->root->explored = false;
    tree->root->cumulative_probability = 1.0;

    FenMap *fmap = fen_map_create();
    if (!fmap) return false;

    DbBuildQueue q;
    if (!db_queue_init(&q)) {
        fen_map_destroy(fmap);
        return false;
    }

    tree->is_building = true;
    tree->build_complete = false;

    if (!db_queue_push(&q, tree->root)) {
        db_queue_destroy(&q);
        fen_map_destroy(fmap);
        return false;
    }

    bool build_ok = true;
    while (build_ok && !g_interrupted) {
        TreeNode *node = db_queue_pop(&q);
        if (!node) break;
        if (node->explored) continue;
        if (!process_node(tree, node, freq, cfg, fmap, &q)) {
            fprintf(stderr, "Error: out of memory during DB tree build\n");
            build_ok = false;
            break;
        }
    }

    tree->is_building = false;
    tree->build_complete = build_ok && !g_interrupted;

    db_queue_destroy(&q);
    fen_map_destroy(fmap);
    return build_ok;
}


/* ========== Post-build eval enrichment ========== */

typedef struct {
    TreeNode **nodes;
    size_t count;
    size_t capacity;
} NoEvalList;

typedef struct {
    NoEvalList list;
    bool collect_failed;
} CollectNoEvalCtx;

static bool no_eval_push(NoEvalList *list, TreeNode *node) {
    if (list->count >= list->capacity) {
        size_t new_cap = list->capacity ? list->capacity * 2 : 64;
        TreeNode **ni = (TreeNode **)realloc(list->nodes,
                                             new_cap * sizeof(TreeNode *));
        if (!ni) return false;
        list->nodes = ni;
        list->capacity = new_cap;
    }
    list->nodes[list->count++] = node;
    return true;
}

static void collect_no_eval_cb(TreeNode *node, void *user_data) {
    CollectNoEvalCtx *ctx = (CollectNoEvalCtx *)user_data;
    if (!node->has_engine_eval &&
        !no_eval_push(&ctx->list, node))
        ctx->collect_failed = true;
}

static EvalChainContext enrich_chain_from_config(const TreeConfig *config) {
    EvalChainContext ctx = {
        .cdbdirect = config->cdbdirect,
        .chessdb_eval_db = config->chessdb_eval_db,
        .lichess_eval_db = config->lichess_eval_db,
        .chessdb_api = config->chessdb_api,
        .eval_depth = config->eval_depth,
        .ext_eval_subtree_skip = config->ext_eval_subtree_skip,
        .stats = config->stats,
    };
    return ctx;
}

static int find_fen_job(const EvalJob *jobs, int n_jobs, const char *fen) {
    for (int i = 0; i < n_jobs; i++)
        if (strcmp(jobs[i].fen, fen) == 0)
            return i;
    return -1;
}

static void enrich_sf_progress(int completed, int total, void *ud) {
    (void)ud;
    char buf[96];
    snprintf(buf, sizeof(buf),
             "  Enriching evals: %d/%d Stockfish...", completed, total);
    if (progress_line_is_tty())
        progress_line_update(buf);
    else if (completed == total || completed % 10 == 0)
        printf("%s\n", buf);
}

bool tree_enrich_evals(Tree *tree, const TreeConfig *config,
                       EvalEnrichStats *stats) {
    if (!tree || !tree->root || !config) return false;

    if (stats)
        memset(stats, 0, sizeof(*stats));

    CollectNoEvalCtx pending = {0};
    tree_traverse_dfs(tree, collect_no_eval_cb, &pending);
    if (pending.collect_failed) {
        fprintf(stderr,
                "Warning: out of memory collecting nodes for eval enrichment — "
                "results may be incomplete\n");
    }
    if (pending.list.count == 0) {
        free(pending.list.nodes);
        return !pending.collect_failed;
    }

    if (stats)
        stats->total_nodes = (int)pending.list.count;

    EvalChainContext chain = enrich_chain_from_config(config);

    /* Phase 1: project DB cache + external eval sources */
    for (size_t i = 0; i < pending.list.count && !g_interrupted; i++) {
        TreeNode *node = pending.list.nodes[i];
        if (node->has_engine_eval) continue;

        if (config->db) {
            int cp, depth;
            if (rdb_get_eval(config->db, node->fen, &cp, &depth)) {
                node_set_eval(node, cp);
                if (stats) stats->cache_hits++;
                continue;
            }
        }

        int cp = 0, depth = 0;
        const char *src = NULL;
        if (eval_chain_try_external(node, &chain, &cp, &depth, &src)) {
            node_set_eval(node, cp);
            if (config->db)
                rdb_put_eval(config->db, node->fen, cp, depth);
            if (stats) stats->ext_hits++;
        }
        (void)src;
    }

    /* Phase 2: Stockfish batch for remaining unique FENs */
    size_t still_need = 0;
    for (size_t i = 0; i < pending.list.count; i++)
        if (!pending.list.nodes[i]->has_engine_eval)
            still_need++;

    if (still_need > 0 && config->engine_pool && !g_interrupted) {
        EvalJob *jobs = (EvalJob *)calloc(still_need, sizeof(EvalJob));
        if (!jobs) {
            free(pending.list.nodes);
            return false;
        }

        int n_jobs = 0;
        for (size_t i = 0; i < pending.list.count; i++) {
            TreeNode *node = pending.list.nodes[i];
            if (node->has_engine_eval) continue;
            if (find_fen_job(jobs, n_jobs, node->fen) >= 0) continue;

            snprintf(jobs[n_jobs].fen, MAX_EVAL_FEN_LENGTH, "%s", node->fen);
            n_jobs++;
        }

        if (n_jobs > 0) {
            engine_pool_set_depth(config->engine_pool, config->eval_depth);
            engine_pool_evaluate_batch(config->engine_pool, jobs, n_jobs,
                                       enrich_sf_progress, NULL);
            progress_line_clear();

            for (int j = 0; j < n_jobs; j++) {
                if (!jobs[j].success) continue;
                if (stats) stats->sf_evals++;
                if (config->db)
                    rdb_put_eval(config->db, jobs[j].fen, jobs[j].eval_cp,
                                 jobs[j].depth_reached);
                for (size_t i = 0; i < pending.list.count; i++) {
                    TreeNode *node = pending.list.nodes[i];
                    if (!node->has_engine_eval &&
                        strcmp(node->fen, jobs[j].fen) == 0)
                        node_set_eval(node, jobs[j].eval_cp);
                }
            }
        }

        free(jobs);
    }

    if (stats) {
        for (size_t i = 0; i < pending.list.count; i++)
            if (!pending.list.nodes[i]->has_engine_eval)
                stats->failed++;
    }

    free(pending.list.nodes);
    return !stats || stats->failed == 0;
}
