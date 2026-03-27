/**
 * tree.c - Opening Tree Implementation
 *
 * The build pass interleaves Lichess explorer queries with Stockfish
 * evaluation.  At our-move nodes, Stockfish MultiPV finds candidates
 * and the eval filter prunes immediately.  At opponent-move nodes,
 * Lichess (or Maia) provides likely human responses and the engine's
 * top-1 move is added if it's not already present.
 */

#include "tree.h"
#include "repertoire.h"
#include "lichess_api.h"
#include "chess_logic.h"
#include "engine_pool.h"
#include "database.h"
#include "maia.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>


/* Ease calculation constants (matching the Flutter/Python implementation) */
#define EASE_ALPHA (1.0/3.0)
#define EASE_BETA  1.5


TreeConfig tree_config_default(void) {
    TreeConfig config = {
        .play_as_white = true,
        .min_probability = 0.0001,
        .max_depth = 30,
        .max_nodes = 0,

        .engine_pool = NULL,
        .db = NULL,
        .eval_depth = 20,

        .our_multipv = 5,
        .our_max_candidates_early = 8,
        .our_max_candidates_late = 2,
        .taper_depth = 8,
        .max_eval_loss_cp = 50,

        .opp_max_children = 6,
        .opp_mass_target = 0.80,

        .min_eval_cp = -50,
        .max_eval_cp = 300,

        .rating_range = "2000,2200,2500",
        .speeds = "blitz,rapid,classical",
        .min_games = 10,
        .use_masters = false,

        .maia = NULL,
        .maia_elo = 2000,
        .maia_threshold = 0.01,
        .maia_min_prob = 0.02,
        .progress_callback = NULL,
    };
    return config;
}


void tree_config_set_color_defaults(TreeConfig *config) {
    if (config->play_as_white) {
        config->min_eval_cp = 0;
        config->max_eval_cp = 200;
    } else {
        config->min_eval_cp = -200;
        config->max_eval_cp = 100;
    }
}


Tree* tree_create(void) {
    Tree *tree = (Tree *)calloc(1, sizeof(Tree));
    if (!tree) return NULL;

    tree->root = NULL;
    tree->config = tree_config_default();
    tree->total_nodes = 0;
    tree->max_depth_reached = 0;
    tree->is_building = false;
    tree->next_node_id = 1;

    return tree;
}


void tree_destroy(Tree *tree) {
    if (!tree) return;
    if (tree->root) node_destroy(tree->root);
    free(tree);
}


/* ========== Build helpers ========== */

/** Create a child node from a FEN, add it to the tree. */
static TreeNode *make_child(TreeNode *parent, const char *fen,
                             const char *san, const char *uci,
                             Tree *tree) {
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

/** Apply a UCI move to a FEN, write the resulting FEN into out_fen. */
static bool apply_uci(const char *fen, const char *uci,
                       char *out_fen, size_t out_len) {
    ChessPosition pos;
    if (!position_from_fen(&pos, fen)) return false;
    if (!position_apply_uci(&pos, uci)) return false;
    position_to_fen(&pos, out_fen, out_len);
    return true;
}

/** Eval from our perspective (positive = good for us). */
static int our_eval(const TreeNode *node, bool play_as_white) {
    if (!node->has_engine_eval) return 0;
    int eval_white = node->is_white_to_move ? node->engine_eval_cp
                                            : -node->engine_eval_cp;
    return play_as_white ? eval_white : -eval_white;
}

/**
 * Ensure a node has an engine evaluation.
 * Checks the DB cache first, then runs a single Stockfish eval.
 */
static void ensure_eval(TreeNode *node, const TreeConfig *config) {
    if (node->has_engine_eval) return;

    /* Try DB cache */
    if (config->db) {
        int cp, depth;
        if (rdb_get_eval(config->db, node->fen, &cp, &depth)) {
            node_set_eval(node, cp);
            return;
        }
    }

    /* Run engine */
    if (config->engine_pool) {
        EvalJob job;
        strncpy(job.fen, node->fen, MAX_EVAL_FEN_LENGTH - 1);
        job.fen[MAX_EVAL_FEN_LENGTH - 1] = '\0';
        if (engine_pool_evaluate_full(config->engine_pool, node->fen, &job) &&
            job.success) {
            node_set_eval(node, job.eval_cp);
            if (config->db)
                rdb_put_eval(config->db, node->fen, job.eval_cp, job.depth_reached);
        }
    }
}

/**
 * Batch-evaluate children that don't have evals yet.
 * Checks the DB cache first, then engine-evaluates the remainder.
 */
static void batch_eval_children(TreeNode *node, const TreeConfig *config) {
    if (!config->engine_pool || node->children_count == 0) return;

    /* Collect children needing evals */
    size_t n = node->children_count;
    EvalJob *jobs = (EvalJob *)calloc(n, sizeof(EvalJob));
    size_t *idx_map = (size_t *)calloc(n, sizeof(size_t));
    if (!jobs || !idx_map) { free(jobs); free(idx_map); return; }

    int job_count = 0;
    for (size_t i = 0; i < n; i++) {
        TreeNode *child = node->children[i];
        if (child->has_engine_eval) continue;

        /* Check DB cache */
        if (config->db) {
            int cp, depth;
            if (rdb_get_eval(config->db, child->fen, &cp, &depth)) {
                node_set_eval(child, cp);
                continue;
            }
        }

        strncpy(jobs[job_count].fen, child->fen, MAX_EVAL_FEN_LENGTH - 1);
        idx_map[job_count] = i;
        job_count++;
    }

    if (job_count > 0) {
        engine_pool_evaluate_batch(config->engine_pool, jobs, job_count, NULL, NULL);
        for (int k = 0; k < job_count; k++) {
            if (!jobs[k].success) continue;
            TreeNode *child = node->children[idx_map[k]];
            node_set_eval(child, jobs[k].eval_cp);
            if (config->db)
                rdb_put_eval(config->db, child->fen,
                             jobs[k].eval_cp, jobs[k].depth_reached);
        }
    }

    free(jobs);
    free(idx_map);
}


/* ========== Interleaved build ========== */

static void build_recursive(Tree *tree, TreeNode *node,
                             const TreeConfig *config,
                             LichessExplorer *explorer);

/**
 * OUR MOVE: Stockfish MultiPV → eval filter → recurse.
 *
 * Also queries Lichess for SAN notation and win-rate enrichment.
 */
static void build_our_move(Tree *tree, TreeNode *node,
                            const TreeConfig *config,
                            LichessExplorer *explorer) {
    /* 1. Run Stockfish MultiPV */
    MultiPVJob mpv;
    if (!engine_pool_evaluate_multipv(config->engine_pool, node->fen,
                                      config->eval_depth,
                                      config->our_multipv, &mpv))
        return;
    if (!mpv.success || mpv.num_lines == 0) return;

    /* Set node's own eval from the top line if not already set */
    if (!node->has_engine_eval) {
        node_set_eval(node, mpv.lines[0].eval_cp);
        if (config->db)
            rdb_put_eval(config->db, node->fen,
                         mpv.lines[0].eval_cp, mpv.lines[0].depth_reached);
    }

    /* 2. Query Lichess for SAN notation and win rates (enrichment only) */
    ExplorerResponse lichess;
    memset(&lichess, 0, sizeof(lichess));
    bool has_lichess = config->use_masters
        ? lichess_explorer_query_masters(explorer, node->fen, &lichess)
        : lichess_explorer_query(explorer, node->fen, &lichess);

    if (has_lichess && lichess.success) {
        node_set_lichess_stats(node, lichess.total_white_wins,
                               lichess.total_black_wins, lichess.total_draws);
        if (lichess.has_opening) {
            strncpy(node->opening_name, lichess.opening_name,
                    sizeof(node->opening_name) - 1);
            strncpy(node->opening_eco, lichess.opening_eco,
                    sizeof(node->opening_eco) - 1);
        }
    }

    /* 3. Filter candidates by eval threshold, depth-dependent cap */
    int best_cp = mpv.lines[0].eval_cp;
    int max_cands = (node->depth < config->taper_depth)
                  ? config->our_max_candidates_early
                  : config->our_max_candidates_late;

    int added = 0;
    for (int pv = 0; pv < mpv.num_lines && added < max_cands; pv++) {
        MultiPVLine *line = &mpv.lines[pv];
        if (line->move_uci[0] == '\0') continue;
        if (best_cp - line->eval_cp > config->max_eval_loss_cp) continue;

        char child_fen[MAX_FEN_LENGTH];
        if (!apply_uci(node->fen, line->move_uci, child_fen, MAX_FEN_LENGTH))
            continue;

        /* Look up SAN from Lichess data; fall back to UCI */
        const char *san = line->move_uci;
        if (has_lichess && lichess.success) {
            for (size_t j = 0; j < lichess.move_count; j++) {
                if (strcmp(lichess.moves[j].uci, line->move_uci) == 0) {
                    san = lichess.moves[j].san;
                    break;
                }
            }
        }

        TreeNode *child = make_child(node, child_fen, san, line->move_uci, tree);
        if (!child) continue;

        child->move_probability = 1.0;
        child->cumulative_probability = node->cumulative_probability;
        node_set_eval(child, -line->eval_cp);
        if (config->db)
            rdb_put_eval(config->db, child_fen,
                         -line->eval_cp, line->depth_reached);

        /* Enrich with Lichess win-rate stats if available */
        if (has_lichess && lichess.success) {
            for (size_t j = 0; j < lichess.move_count; j++) {
                if (strcmp(lichess.moves[j].uci, line->move_uci) == 0) {
                    node_set_lichess_stats(child,
                        lichess.moves[j].white_wins,
                        lichess.moves[j].black_wins,
                        lichess.moves[j].draws);
                    break;
                }
            }
        }

        added++;
        if (config->progress_callback)
            config->progress_callback(tree->total_nodes, child->depth, child->fen);
    }

    /* 4. Recurse into children */
    for (size_t i = 0; i < node->children_count; i++) {
        if (!tree->is_building) break;
        build_recursive(tree, node->children[i], config, explorer);
    }
}


/**
 * OPPONENT MOVE: Lichess DB (+ Maia fallback) + engine top-1 → recurse.
 *
 * Children are batch-evaluated before recursion so the eval window
 * can prune immediately.
 */
static void build_opponent_move(Tree *tree, TreeNode *node,
                                 const TreeConfig *config,
                                 LichessExplorer *explorer) {
    /* 1. Query Lichess explorer */
    ExplorerResponse response;
    memset(&response, 0, sizeof(response));
    bool query_ok = config->use_masters
        ? lichess_explorer_query_masters(explorer, node->fen, &response)
        : lichess_explorer_query(explorer, node->fen, &response);

    bool use_maia = false;
    MaiaResponse maia_resp;
    memset(&maia_resp, 0, sizeof(maia_resp));

    if (!query_ok || !response.success || response.move_count == 0 ||
        response.total_games < (uint64_t)config->min_games) {
        if (config->maia &&
            node->cumulative_probability >= config->maia_threshold) {
            if (maia_evaluate(config->maia, node->fen,
                              config->maia_elo, &maia_resp) &&
                maia_resp.success && maia_resp.move_count > 0) {
                use_maia = true;
            }
        }
        if (!use_maia) {
            if (response.success && response.total_games > 0)
                node_set_lichess_stats(node,
                    response.total_white_wins,
                    response.total_black_wins,
                    response.total_draws);
            return;
        }
    }

    /* Set Lichess stats on this node */
    if (!use_maia) {
        node_set_lichess_stats(node,
                               response.total_white_wins,
                               response.total_black_wins,
                               response.total_draws);
        if (response.has_opening) {
            strncpy(node->opening_name, response.opening_name,
                    sizeof(node->opening_name) - 1);
            strncpy(node->opening_eco, response.opening_eco,
                    sizeof(node->opening_eco) - 1);
        }
    }

    uint64_t total = use_maia ? 0 : response.total_games;
    size_t move_count = use_maia ? (size_t)maia_resp.move_count
                                 : response.move_count;

    /* 2. Add Lichess/Maia children (capped by mass and count) */
    int children_added = 0;
    double mass_covered = 0.0;

    for (size_t i = 0; i < move_count; i++) {
        const char *uci, *san;
        double prob;
        uint64_t mw = 0, mb = 0, md = 0;

        if (use_maia) {
            uci = maia_resp.moves[i].uci;
            san = maia_resp.moves[i].uci;
            prob = maia_resp.moves[i].probability;
            if (prob < config->maia_min_prob) continue;
        } else {
            ExplorerMove *move = &response.moves[i];
            uci = move->uci;
            san = move->san;
            uint64_t games = move->white_wins + move->draws + move->black_wins;
            prob = (double)games / (double)total;
            mw = move->white_wins;
            mb = move->black_wins;
            md = move->draws;
            if (games < (uint64_t)config->min_games) continue;
        }

        if (config->opp_max_children > 0 &&
            children_added >= config->opp_max_children)
            break;
        if (config->opp_mass_target > 0.0 &&
            mass_covered >= config->opp_mass_target)
            break;

        double new_cumul = node->cumulative_probability * prob;
        if (new_cumul < config->min_probability) continue;

        char child_fen[MAX_FEN_LENGTH];
        if (!apply_uci(node->fen, uci, child_fen, MAX_FEN_LENGTH))
            continue;

        TreeNode *child = make_child(node, child_fen, san, uci, tree);
        if (!child) continue;

        child->move_probability = prob;
        child->cumulative_probability = new_cumul;
        if (!use_maia) node_set_lichess_stats(child, mw, mb, md);

        children_added++;
        mass_covered += prob;

        if (config->progress_callback)
            config->progress_callback(tree->total_nodes, child->depth, child->fen);
    }

    /* 3. Add engine top-1 if not already in children */
    if (config->engine_pool) {
        EvalJob best_job;
        if (engine_pool_evaluate_full(config->engine_pool, node->fen, &best_job) &&
            best_job.success && best_job.bestmove[0]) {
            /* Set node's own eval from this call */
            if (!node->has_engine_eval) {
                node_set_eval(node, best_job.eval_cp);
                if (config->db)
                    rdb_put_eval(config->db, node->fen,
                                 best_job.eval_cp, best_job.depth_reached);
            }

            bool exists = false;
            for (size_t c = 0; c < node->children_count; c++) {
                if (strcmp(node->children[c]->move_uci, best_job.bestmove) == 0) {
                    /* Already present — just make sure it has an eval */
                    if (!node->children[c]->has_engine_eval) {
                        node_set_eval(node->children[c], -best_job.eval_cp);
                        if (config->db)
                            rdb_put_eval(config->db, node->children[c]->fen,
                                         -best_job.eval_cp, best_job.depth_reached);
                    }
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                char child_fen[MAX_FEN_LENGTH];
                if (apply_uci(node->fen, best_job.bestmove,
                              child_fen, MAX_FEN_LENGTH)) {
                    TreeNode *child = make_child(node, child_fen,
                                                  best_job.bestmove,
                                                  best_job.bestmove, tree);
                    if (child) {
                        child->move_probability = 0.01;
                        child->cumulative_probability =
                            node->cumulative_probability * 0.01;
                        node_set_eval(child, -best_job.eval_cp);
                        if (config->db)
                            rdb_put_eval(config->db, child_fen,
                                         -best_job.eval_cp, best_job.depth_reached);
                    }
                }
            }
        }
    }

    /* 4. Batch-evaluate children that still lack evals */
    batch_eval_children(node, config);

    /* 5. Recurse into children */
    for (size_t i = 0; i < node->children_count; i++) {
        if (!tree->is_building) break;
        build_recursive(tree, node->children[i], config, explorer);
    }
}


/**
 * Main recursive build — the single DFS that builds the tree.
 *
 * At each node:
 *   1. Check stop conditions (depth, cumP, interrupt)
 *   2. Resume support (skip explored nodes, recurse into existing children)
 *   3. Ensure this node has an eval (for window pruning)
 *   4. Eval-window pruning
 *   5. Dispatch to build_our_move or build_opponent_move
 */
static void build_recursive(Tree *tree, TreeNode *node,
                             const TreeConfig *config,
                             LichessExplorer *explorer) {
    if (!tree->is_building) return;
    if (node->depth >= config->max_depth) return;
    if (node->cumulative_probability < config->min_probability) return;
    if (config->max_nodes > 0 && tree->total_nodes >= (size_t)config->max_nodes)
        return;

    /* Resume: skip nodes that were already explored */
    if (node->children_count > 0) {
        for (size_t i = 0; i < node->children_count; i++)
            build_recursive(tree, node->children[i], config, explorer);
        return;
    }
    if (node->explored) return;

    /* Ensure this node has an eval for window pruning.
       (Most non-root nodes will already have one from their parent.) */
    ensure_eval(node, config);

    /* Eval-window pruning */
    if (node->has_engine_eval) {
        int eval_us = our_eval(node, config->play_as_white);
        if (eval_us <= config->min_eval_cp ||
            eval_us >= config->max_eval_cp) {
            node->explored = true;
            return;
        }
    }

    bool is_our_move = (node->is_white_to_move == config->play_as_white);
    node->explored = true;

    if (is_our_move)
        build_our_move(tree, node, config, explorer);
    else
        build_opponent_move(tree, node, config, explorer);
}


bool tree_build(Tree *tree, const char *start_fen,
                const TreeConfig *config, LichessExplorer *explorer) {
    if (!tree || !start_fen || !explorer) return false;
    if (!config->engine_pool) {
        fprintf(stderr, "Error: engine_pool is required for tree_build\n");
        return false;
    }

    tree->config = *config;

    if (tree->root) {
        /* Resuming — keep existing tree intact */
    } else {
        tree->root = node_create(start_fen, NULL, NULL, NULL);
        if (!tree->root) return false;
        tree->total_nodes = 1;
    }
    if (tree->total_nodes <= 1) tree->max_depth_reached = 0;
    tree->is_building = true;

    build_recursive(tree, tree->root, config, explorer);

    tree->build_complete = tree->is_building;
    tree->is_building = false;

    return true;
}


void tree_stop_build(Tree *tree) {
    if (tree) tree->is_building = false;
}


/* ========== Search / utility ========== */

static TreeNode* find_by_fen_recursive(TreeNode *node, const char *fen) {
    if (!node) return NULL;
    if (strcmp(node->fen, fen) == 0) return node;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *found = find_by_fen_recursive(node->children[i], fen);
        if (found) return found;
    }
    return NULL;
}

TreeNode* tree_find_by_fen(const Tree *tree, const char *fen) {
    if (!tree || !tree->root || !fen) return NULL;
    return find_by_fen_recursive(tree->root, fen);
}

TreeNode* tree_find_by_moves(const Tree *tree, const char **moves, size_t num_moves) {
    if (!tree || !tree->root || !moves) return NULL;
    TreeNode *current = tree->root;
    for (size_t m = 0; m < num_moves; m++) {
        TreeNode *next = NULL;
        for (size_t i = 0; i < current->children_count; i++) {
            if (strcmp(current->children[i]->move_san, moves[m]) == 0) {
                next = current->children[i];
                break;
            }
        }
        if (!next) return NULL;
        current = next;
    }
    return current;
}


static void collect_leaves(TreeNode *node, TreeNode **leaves,
                           size_t *count, size_t max_count) {
    if (!node || *count >= max_count) return;
    if (node->children_count == 0) {
        leaves[*count] = node;
        (*count)++;
        return;
    }
    for (size_t i = 0; i < node->children_count; i++)
        collect_leaves(node->children[i], leaves, count, max_count);
}

size_t tree_get_leaves(const Tree *tree, TreeNode **out_leaves, size_t max_leaves) {
    if (!tree || !tree->root || !out_leaves) return 0;
    size_t count = 0;
    collect_leaves(tree->root, out_leaves, &count, max_leaves);
    return count;
}


static void collect_at_depth(TreeNode *node, int target_depth,
                              TreeNode **nodes, size_t *count, size_t max_count) {
    if (!node || *count >= max_count) return;
    if (node->depth == target_depth) { nodes[*count] = node; (*count)++; return; }
    if (node->depth > target_depth) return;
    for (size_t i = 0; i < node->children_count; i++)
        collect_at_depth(node->children[i], target_depth, nodes, count, max_count);
}

size_t tree_get_nodes_at_depth(const Tree *tree, int depth,
                                TreeNode **out_nodes, size_t max_nodes) {
    if (!tree || !tree->root || !out_nodes) return 0;
    size_t count = 0;
    collect_at_depth(tree->root, depth, out_nodes, &count, max_nodes);
    return count;
}


/* ========== Ease calculation ========== */

static double ease_cp_to_q(int cp) {
    if (abs(cp) > 9000) return cp > 0 ? 1.0 : -1.0;
    double wp = 1.0 / (1.0 + exp(-0.004 * cp));
    return 2.0 * wp - 1.0;
}

static void calculate_node_ease(TreeNode *node) {
    if (!node || node->children_count == 0) return;

    int best_eval = -100000;
    bool has_evals = false;
    for (size_t i = 0; i < node->children_count; i++) {
        if (node->children[i]->has_engine_eval) {
            int eval_for_us = -node->children[i]->engine_eval_cp;
            if (eval_for_us > best_eval) best_eval = eval_for_us;
            has_evals = true;
        }
    }
    if (!has_evals) return;

    double q_max = ease_cp_to_q(best_eval);
    double sum_weighted_regret = 0.0;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_engine_eval) continue;
        if (child->move_probability < 0.01) continue;
        double q_val = ease_cp_to_q(-child->engine_eval_cp);
        double regret = fmax(0.0, q_max - q_val);
        sum_weighted_regret += pow(child->move_probability, EASE_BETA) * regret;
    }

    double ease = 1.0 - pow(sum_weighted_regret / 2.0, EASE_ALPHA);
    if (ease < 0.0) ease = 0.0;
    if (ease > 1.0) ease = 1.0;
    node_set_ease(node, ease);
}

static size_t calculate_ease_recursive(TreeNode *node) {
    if (!node) return 0;
    size_t count = 0;
    if (node->children_count > 0) {
        calculate_node_ease(node);
        if (node->has_ease) count++;
    }
    for (size_t i = 0; i < node->children_count; i++)
        count += calculate_ease_recursive(node->children[i]);
    return count;
}

size_t tree_calculate_ease(Tree *tree) {
    if (!tree || !tree->root) return 0;
    return calculate_ease_recursive(tree->root);
}


/* ========== ECA (Expected Centipawn Advantage) ========== */

double win_probability(int cp) {
    if (abs(cp) > 9000) return cp > 0 ? 1.0 : 0.0;
    return 1.0 / (1.0 + exp(-0.00368208 * cp));
}

static int eca_eval_for_us(const TreeNode *child, bool play_as_white) {
    if (!child->has_engine_eval) return 0;
    int eval_white = child->is_white_to_move ? child->engine_eval_cp
                                             : -child->engine_eval_cp;
    return play_as_white ? eval_white : -eval_white;
}

static double eca_wp_us(const TreeNode *child, bool play_as_white) {
    if (!child->has_engine_eval) return 0.5;
    int eval_white = child->is_white_to_move ? child->engine_eval_cp
                                             : -child->engine_eval_cp;
    double wp_white = win_probability(eval_white);
    return play_as_white ? wp_white : (1.0 - wp_white);
}

static void compute_local_eca(TreeNode *node) {
    if (!node || node->children_count == 0) return;

    double best_wp = -1.0;
    bool has_any = false;
    for (size_t i = 0; i < node->children_count; i++) {
        if (!node->children[i]->has_engine_eval) continue;
        double mover_wp = 1.0 - win_probability(node->children[i]->engine_eval_cp);
        if (mover_wp > best_wp) best_wp = mover_wp;
        has_any = true;
    }
    if (!has_any) return;

    double sum = 0.0;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_engine_eval) continue;
        if (child->move_probability < 0.01) continue;
        double mover_wp = 1.0 - win_probability(child->engine_eval_cp);
        double delta = best_wp - mover_wp;
        if (delta < 0) delta = 0;
        sum += child->move_probability * delta;
    }
    node->local_cpl = sum;
}


int score_our_move_children(TreeNode *node,
                            const struct RepertoireConfig *config,
                            ScoredChild *best_out) {
    if (!node || !config || !best_out) return 0;

    best_out->child = NULL;
    best_out->score = -1e9;
    best_out->accumulated_eca = 0.0;

    int best_child_cp = -100000;
    for (size_t i = 0; i < node->children_count; i++) {
        if (!node->children[i]->has_engine_eval) continue;
        int cp_us = eca_eval_for_us(node->children[i], config->play_as_white);
        if (cp_us > best_child_cp) best_child_cp = cp_us;
    }

    int passing = 0;
    double best_score = -1e9;
    TreeNode *best_child = NULL;
    double best_eca = 0.0;

    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_eca) continue;
        int cp_us = eca_eval_for_us(child, config->play_as_white);
        if (cp_us < best_child_cp - config->max_eval_loss_cp) continue;
        double eval_us_wp = eca_wp_us(child, config->play_as_white);
        if (eval_us_wp < config->eval_guard_threshold) continue;
        passing++;
        double score = config->eval_weight * eval_us_wp
                     + (1.0 - config->eval_weight) * child->accumulated_eca;
        if (score > best_score) {
            best_score = score;
            best_child = child;
            best_eca = child->accumulated_eca;
        }
    }

    /* Fallback: all filtered out → re-score without filters */
    if (passing == 0) {
        best_score = -1e9;
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (!child->has_eca) continue;
            double eval_us_wp = eca_wp_us(child, config->play_as_white);
            double score = config->eval_weight * eval_us_wp
                         + (1.0 - config->eval_weight) * child->accumulated_eca;
            if (score > best_score) {
                best_score = score;
                best_child = child;
                best_eca = child->accumulated_eca;
            }
        }
    }

    best_out->child = best_child;
    best_out->score = best_score;
    best_out->accumulated_eca = best_eca;
    return passing;
}


static size_t calculate_eca_recursive(TreeNode *node,
                                       const RepertoireConfig *config) {
    if (!node) return 0;
    size_t count = 0;
    for (size_t i = 0; i < node->children_count; i++)
        count += calculate_eca_recursive(node->children[i], config);

    compute_local_eca(node);

    double gamma_d = pow(config->depth_discount, (double)node->depth);
    bool is_our_move = (node->is_white_to_move == config->play_as_white);

    if (node->children_count == 0) {
        node->accumulated_eca = gamma_d * node->local_cpl;
    } else if (is_our_move) {
        ScoredChild best;
        score_our_move_children(node, config, &best);
        node->accumulated_eca = best.child ? best.accumulated_eca : 0.0;
    } else {
        double future = 0.0;
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (!child->has_eca) continue;
            future += child->move_probability * child->accumulated_eca;
        }
        node->accumulated_eca = gamma_d * node->local_cpl + future;
    }

    node->has_eca = true;
    count++;
    return count;
}

size_t tree_calculate_eca(Tree *tree, const struct RepertoireConfig *config) {
    if (!tree || !tree->root || !config) return 0;
    return calculate_eca_recursive(tree->root, config);
}


/* ========== Probability recalculation ========== */

static void recalc_prob_recursive(TreeNode *node, double parent_cumul,
                                   bool play_as_white) {
    if (!node) return;
    bool parent_was_our_move = (node->parent &&
                                node->parent->is_white_to_move == play_as_white);
    node->cumulative_probability = parent_was_our_move
        ? parent_cumul
        : parent_cumul * node->move_probability;

    for (size_t i = 0; i < node->children_count; i++)
        recalc_prob_recursive(node->children[i],
                              node->cumulative_probability, play_as_white);
}

void tree_recalculate_probabilities(Tree *tree) {
    if (!tree || !tree->root) return;
    tree->root->cumulative_probability = 1.0;
    for (size_t i = 0; i < tree->root->children_count; i++)
        recalc_prob_recursive(tree->root->children[i], 1.0,
                              tree->config.play_as_white);
}


size_t tree_get_line_to_node(const TreeNode *node,
                              char (*out_moves)[MAX_MOVE_LENGTH],
                              size_t max_moves) {
    if (!node || !out_moves) return 0;
    size_t depth = 0;
    const TreeNode *temp = node;
    while (temp->parent) { depth++; temp = temp->parent; }
    if (depth == 0) return 0;
    if (depth > max_moves) depth = max_moves;

    size_t idx = depth - 1;
    temp = node;
    while (temp->parent && idx < depth) {
        snprintf(out_moves[idx], MAX_MOVE_LENGTH, "%s", temp->move_san);
        idx--;
        temp = temp->parent;
    }
    return depth;
}


void tree_print_stats(const Tree *tree) {
    if (!tree) { printf("Tree: (null)\n"); return; }
    printf("\n=== Tree Statistics ===\n");
    printf("Total nodes: %zu\n", tree->total_nodes);
    printf("Max depth reached: %d ply\n", tree->max_depth_reached);
    if (tree->root) {
        printf("Root FEN: %s\n", tree->root->fen);
        printf("Actual node count: %zu\n", node_count_subtree(tree->root));
        if (tree->root->total_games > 0)
            printf("Root position games: %lu\n",
                   (unsigned long)tree->root->total_games);
    }
    printf("\nConfiguration:\n");
    printf("  Min probability: %.4f%%\n", tree->config.min_probability * 100.0);
    printf("  Max depth: %d ply\n", tree->config.max_depth);
    printf("  Our MultiPV: %d (early %d / late %d, taper at %d)\n",
           tree->config.our_multipv,
           tree->config.our_max_candidates_early,
           tree->config.our_max_candidates_late,
           tree->config.taper_depth);
    printf("  Opponent: max %d children, %.0f%% mass target\n",
           tree->config.opp_max_children,
           tree->config.opp_mass_target * 100.0);
    printf("  Eval window: [%+d, %+d] cp\n",
           tree->config.min_eval_cp, tree->config.max_eval_cp);
    printf("========================\n\n");
}


static void print_recursive(TreeNode *node, int max_depth) {
    if (!node) return;
    if (max_depth >= 0 && node->depth > max_depth) return;
    node_print(node, node->depth);
    for (size_t i = 0; i < node->children_count; i++)
        print_recursive(node->children[i], max_depth);
}

void tree_print(const Tree *tree, int max_depth) {
    if (!tree || !tree->root) { printf("Tree: (empty)\n"); return; }
    printf("\n=== Tree Structure ===\n");
    print_recursive(tree->root, max_depth);
    printf("======================\n\n");
}


/* ========== Traversal ========== */

static void traverse_dfs_recursive(TreeNode *node,
                                    void (*callback)(TreeNode *, void *),
                                    void *user_data) {
    if (!node) return;
    callback(node, user_data);
    for (size_t i = 0; i < node->children_count; i++)
        traverse_dfs_recursive(node->children[i], callback, user_data);
}

void tree_traverse_dfs(const Tree *tree,
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data) {
    if (!tree || !tree->root || !callback) return;
    traverse_dfs_recursive(tree->root, callback, user_data);
}


typedef struct {
    TreeNode **nodes;
    size_t capacity, head, count;
} NodeQueue;

static NodeQueue* queue_create(size_t capacity) {
    NodeQueue *q = (NodeQueue *)malloc(sizeof(NodeQueue));
    if (!q) return NULL;
    q->nodes = (TreeNode **)malloc(capacity * sizeof(TreeNode *));
    if (!q->nodes) { free(q); return NULL; }
    q->capacity = capacity;
    q->head = 0;
    q->count = 0;
    return q;
}

static void queue_destroy(NodeQueue *q) {
    if (q) { free(q->nodes); free(q); }
}

static bool queue_push(NodeQueue *q, TreeNode *node) {
    if (q->head + q->count >= q->capacity) {
        if (q->head > 0) {
            memmove(q->nodes, q->nodes + q->head,
                    q->count * sizeof(TreeNode *));
            q->head = 0;
        } else {
            size_t new_cap = q->capacity * 2;
            TreeNode **new_nodes = (TreeNode **)realloc(
                q->nodes, new_cap * sizeof(TreeNode *));
            if (!new_nodes) return false;
            q->nodes = new_nodes;
            q->capacity = new_cap;
        }
    }
    q->nodes[q->head + q->count] = node;
    q->count++;
    return true;
}

static TreeNode* queue_pop(NodeQueue *q) {
    if (q->count == 0) return NULL;
    TreeNode *node = q->nodes[q->head];
    q->head++;
    q->count--;
    return node;
}

void tree_traverse_bfs(const Tree *tree,
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data) {
    if (!tree || !tree->root || !callback) return;
    NodeQueue *queue = queue_create(256);
    if (!queue) return;
    queue_push(queue, tree->root);
    while (queue->count > 0) {
        TreeNode *node = queue_pop(queue);
        if (!node) continue;
        callback(node, user_data);
        if (node->children) {
            for (size_t i = 0; i < node->children_count; i++)
                if (node->children[i]) queue_push(queue, node->children[i]);
        }
    }
    queue_destroy(queue);
}
