/**
 * repertoire.c - Automatic Repertoire Generation
 *
 * Selection phase: runs AFTER the interleaved build has populated the
 * tree with engine evaluations.  Computes ease scores, ECA values,
 * and selects one move at each our-move node.
 *
 * At our-move nodes: pick the child with the best blended score.
 * At opponent nodes: traverse all children (already capped during build).
 */

#include "repertoire.h"
#include "chess_logic.h"
#include "cJSON.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <float.h>

/* Ease formula constants */
#define EASE_ALPHA (1.0/3.0)
#define EASE_BETA  1.5
#define Q_SIGMOID_K 0.004


/* ========== Utility Functions ========== */

static double cp_to_q(int cp) {
    if (abs(cp) > 9000) return cp > 0 ? 1.0 : -1.0;
    double win_prob = 1.0 / (1.0 + exp(-Q_SIGMOID_K * cp));
    return 2.0 * win_prob - 1.0;
}

static double cp_to_win_prob(int cp) {
    return 1.0 / (1.0 + exp(-0.00368208 * cp));
}

static double normalize_eval(int eval_cp, bool play_as_white) {
    double wp = cp_to_win_prob(eval_cp);
    return play_as_white ? wp : (1.0 - wp);
}

static double normalize_winrate(uint64_t wins, uint64_t draws, uint64_t total,
                                 bool play_as_white) {
    if (total == 0) return 0.5;
    uint64_t our_wins = play_as_white ? wins : (total - wins - draws);
    return ((double)our_wins + 0.5 * (double)draws) / (double)total;
}

static int get_eval_for_us(const TreeNode *node, bool play_as_white) {
    if (!node->has_engine_eval) return 0;
    int eval_white = node->is_white_to_move ? node->engine_eval_cp
                                            : -node->engine_eval_cp;
    return play_as_white ? eval_white : -eval_white;
}


/* ========== Configuration ========== */

RepertoireConfig repertoire_config_default(void) {
    RepertoireConfig config = {
        .play_as_white = true,
        .max_depth = 30,
        .min_probability = 0.0001,
        .min_games = 10,

        .weight_eval = 0.30,
        .weight_ease = 0.25,
        .weight_winrate = 0.25,
        .weight_sharpness = 0.20,

        .eval_depth = 20,
        .quick_eval_depth = 15,

        .depth_discount = 1.0,
        .eval_weight = 0.40,
        .leaf_confidence = 1.0,
        .min_eval_cp = -50,
        .max_eval_cp = 300,
        .max_eval_loss_cp = 50,

        .max_candidates_per_position = 8,
        .candidate_min_prob = 0.01,
        .verbose_search = false,
        .start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        .name = "",
    };
    return config;
}


void repertoire_config_set_color_defaults(RepertoireConfig *config) {
    if (config->play_as_white) {
        config->min_eval_cp = 0;
        config->max_eval_cp = 200;
    } else {
        config->min_eval_cp = -200;
        config->max_eval_cp = 100;
    }
}


/* ========== Ease (for fallback scoring) ========== */

static double calculate_ease_for_node(TreeNode *node, RepertoireDB *db) {
    if (!node || node->children_count == 0) return -1.0;

    int best_eval = -100000;
    bool has_any_eval = false;

    for (size_t i = 0; i < node->children_count; i++) {
        int eval_cp;
        int depth;
        if (rdb_get_eval(db, node->children[i]->fen, &eval_cp, &depth)) {
            int eval_for_us = -eval_cp;
            if (eval_for_us > best_eval) best_eval = eval_for_us;
            has_any_eval = true;
        } else if (node->children[i]->has_engine_eval) {
            int eval_for_us = -node->children[i]->engine_eval_cp;
            if (eval_for_us > best_eval) best_eval = eval_for_us;
            has_any_eval = true;
        }
    }
    if (!has_any_eval) return -1.0;

    double q_max = cp_to_q(best_eval);
    double sum_weighted_regret = 0.0;

    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        double prob = child->move_probability;
        if (prob < 0.01) continue;

        int child_eval;
        int depth;
        if (rdb_get_eval(db, child->fen, &child_eval, &depth))
            child_eval = -child_eval;
        else if (child->has_engine_eval)
            child_eval = -child->engine_eval_cp;
        else
            continue;

        double q_val = cp_to_q(child_eval);
        double regret = fmax(0.0, q_max - q_val);
        sum_weighted_regret += pow(prob, EASE_BETA) * regret;
    }

    double raw_ease = 1.0 - pow(sum_weighted_regret / 2.0, EASE_ALPHA);
    if (raw_ease < 0.0) raw_ease = 0.0;
    if (raw_ease > 1.0) raw_ease = 1.0;
    return raw_ease;
}


/* ========== Position Scoring (fallback when no ECA) ========== */

double score_position(int eval_cp, double ease, double opponent_ease,
                       double win_rate, double probability,
                       uint64_t total_games, const RepertoireConfig *config,
                       bool is_our_move) {
    if (!config) return 0.0;

    double eval_score = normalize_eval(eval_cp, config->play_as_white);

    double ease_component;
    if (is_our_move)
        ease_component = ease >= 0 ? ease : 0.5;
    else
        ease_component = opponent_ease >= 0 ? (1.0 - opponent_ease) : 0.5;

    double sharpness = opponent_ease >= 0 ? (1.0 - opponent_ease) : 0.5;
    double wr_component = win_rate >= 0 ? win_rate : 0.5;

    double confidence = 1.0;
    if (total_games < 100)
        confidence = 0.5 + 0.5 * ((double)total_games / 100.0);

    double score = config->weight_eval * eval_score
                 + config->weight_ease * ease_component
                 + config->weight_winrate * wr_component
                 + config->weight_sharpness * sharpness;
    score *= confidence;

    double prob_factor = 1.0;
    if (probability > 0)
        prob_factor = 0.5 + 0.5 * sqrt(probability);
    score *= prob_factor;

    return score;
}


/* ========== Trap Score ========== */

double calculate_trap_score(const TreeNode *node, RepertoireDB *db) {
    if (!node || node->children_count < 2 || !db) return -1.0;

    TreeNode *most_popular = NULL;
    TreeNode *best_move_node = NULL;
    double highest_prob = 0;
    int best_eval = -100000;

    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (child->move_probability > highest_prob) {
            highest_prob = child->move_probability;
            most_popular = child;
        }
        int eval_cp, depth;
        if (rdb_get_eval(db, child->fen, &eval_cp, &depth)) {
            int eval_for_mover = -eval_cp;
            if (eval_for_mover > best_eval) {
                best_eval = eval_for_mover;
                best_move_node = child;
            }
        }
    }

    if (!most_popular || !best_move_node) return -1.0;
    if (most_popular == best_move_node) return 0.0;

    int popular_eval, depth;
    if (!rdb_get_eval(db, most_popular->fen, &popular_eval, &depth))
        return -1.0;
    popular_eval = -popular_eval;

    double eval_diff = (double)(best_eval - popular_eval);
    if (eval_diff < 0) eval_diff = 0;
    double trap = eval_diff / 200.0;
    if (trap > 1.0) trap = 1.0;
    trap *= highest_prob;

    return trap;
}


/* ========== Repertoire Selection ========== */

static void build_repertoire_recursive(TreeNode *node, Tree *tree,
                                         RepertoireDB *db, EnginePool *engine_pool,
                                         const RepertoireConfig *config,
                                         RepertoireMove *out_moves, int *num_moves,
                                         int max_moves,
                                         void (*progress)(const char *, int, int)) {
    (void)engine_pool;
    (void)progress;
    if (!node || *num_moves >= max_moves) return;
    if (node->depth >= config->max_depth) return;
    if (node->cumulative_probability < config->min_probability) return;
    if (node->children_count == 0) return;

    if (node->depth > 0) {
        int eval_us = get_eval_for_us(node, config->play_as_white);
        if (eval_us <= config->min_eval_cp || eval_us >= config->max_eval_cp)
            return;
    }

    bool is_our_move = config->play_as_white
                     ? node->is_white_to_move
                     : !node->is_white_to_move;

    if (is_our_move) {
        TreeNode *best_child = NULL;
        double best_score = -DBL_MAX;
        bool using_eca = false;

        for (size_t i = 0; i < node->children_count; i++)
            if (node->children[i]->has_eca) { using_eca = true; break; }

        if (using_eca) {
            ScoredChild winner;
            score_our_move_children(node, config, &winner);
            best_child = winner.child;
            best_score = winner.score;
        } else {
            for (size_t i = 0; i < node->children_count; i++) {
                TreeNode *child = node->children[i];
                int eval_cp = child->has_engine_eval ? child->engine_eval_cp : 0;
                double ease = child->has_ease ? child->ease : -1.0;
                double opp_ease = calculate_ease_for_node(child, db);
                double win_rate = 0.5;
                if (child->total_games > 0)
                    win_rate = normalize_winrate(child->white_wins, child->draws,
                                                 child->total_games,
                                                 config->play_as_white);
                double score = score_position(eval_cp, ease, opp_ease, win_rate,
                                              child->cumulative_probability,
                                              child->total_games, config, true);
                if (score > best_score) {
                    best_score = score;
                    best_child = child;
                }
            }
        }

        if (best_child && *num_moves < max_moves) {
            RepertoireMove *rm = &out_moves[*num_moves];
            strncpy(rm->fen, node->fen, sizeof(rm->fen) - 1);
            strncpy(rm->move_san, best_child->move_san, sizeof(rm->move_san) - 1);
            strncpy(rm->move_uci, best_child->move_uci, sizeof(rm->move_uci) - 1);
            rm->composite_score = best_score;
            rm->depth = node->depth;
            rm->probability = node->cumulative_probability;
            rm->eval_cp = best_child->has_engine_eval ? best_child->engine_eval_cp : 0;
            rm->total_games = best_child->total_games;
            (*num_moves)++;

            rdb_save_repertoire_move(db, node->fen, best_child->move_san,
                                      best_child->move_uci, best_score);

            build_repertoire_recursive(best_child, tree, db, engine_pool,
                                        config, out_moves, num_moves, max_moves,
                                        progress);
        }
    } else {
        /* Opponent: traverse all children (already capped during build) */
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (child->cumulative_probability < config->min_probability) continue;

            build_repertoire_recursive(child, tree, db, engine_pool,
                                        config, out_moves, num_moves, max_moves,
                                        progress);
        }
    }
}


/* ========== Line Extraction ========== */

static TreeNode* find_repertoire_child(TreeNode *node,
                                        const RepertoireMove *moves, int num_moves) {
    for (int m = 0; m < num_moves; m++) {
        if (strcmp(moves[m].fen, node->fen) != 0) continue;
        for (size_t c = 0; c < node->children_count; c++) {
            if (strcmp(node->children[c]->move_san, moves[m].move_san) == 0)
                return node->children[c];
        }
    }
    return NULL;
}

static int extract_lines(Tree *tree, const RepertoireMove *moves, int num_moves,
                          const RepertoireConfig *config,
                          RepertoireLine *out_lines, int max_lines) {
    if (!tree || !tree->root || !moves || num_moves == 0) return 0;

    int num_lines = 0;

    typedef struct {
        TreeNode *node;
        char moves_san[128][16];
        char moves_uci[128][16];
        bool is_engine_injected[128];
        int depth;
    } LineState;

    LineState *stack = (LineState *)calloc(10000, sizeof(LineState));
    if (!stack) return 0;

    int stack_top = 0;
    stack[0].node = tree->root;
    stack[0].depth = 0;
    stack_top = 1;

    while (stack_top > 0 && num_lines < max_lines) {
        LineState current = stack[--stack_top];
        TreeNode *node = current.node;

        if (!node || current.depth >= 128) {
            if (current.depth > 0) goto record_line;
            continue;
        }

        bool is_our_move = config->play_as_white
                         ? node->is_white_to_move
                         : !node->is_white_to_move;

        bool pushed_any = false;

        if (is_our_move) {
            TreeNode *selected = find_repertoire_child(node, moves, num_moves);
            if (selected && stack_top < 10000) {
                LineState *next = &stack[stack_top];
                next->node = selected;
                next->depth = current.depth + 1;
                memcpy(next->moves_san, current.moves_san, sizeof(current.moves_san));
                memcpy(next->moves_uci, current.moves_uci, sizeof(current.moves_uci));
                memcpy(next->is_engine_injected, current.is_engine_injected, sizeof(current.is_engine_injected));
                strncpy(next->moves_san[current.depth], selected->move_san, 15);
                strncpy(next->moves_uci[current.depth], selected->move_uci, 15);
                next->is_engine_injected[current.depth] = selected->engine_injected;
                stack_top++;
                pushed_any = true;
            }
        } else {
            for (size_t i = 0; i < node->children_count; i++) {
                TreeNode *child = node->children[i];
                if (child->cumulative_probability < config->min_probability) continue;
                if (stack_top < 10000) {
                    LineState *next = &stack[stack_top];
                    next->node = child;
                    next->depth = current.depth + 1;
                    memcpy(next->moves_san, current.moves_san, sizeof(current.moves_san));
                    memcpy(next->moves_uci, current.moves_uci, sizeof(current.moves_uci));
                    memcpy(next->is_engine_injected, current.is_engine_injected, sizeof(current.is_engine_injected));
                    strncpy(next->moves_san[current.depth], child->move_san, 15);
                    strncpy(next->moves_uci[current.depth], child->move_uci, 15);
                    next->is_engine_injected[current.depth] = child->engine_injected;
                    stack_top++;
                    pushed_any = true;
                }
            }
        }

        if (!pushed_any && current.depth > 0) goto record_line;
        continue;

    record_line:
        {
            int depth = current.depth;
            if (depth > 0 && current.node) {
                bool last_is_our_move = config->play_as_white
                    ? !current.node->is_white_to_move
                    : current.node->is_white_to_move;
                if (!last_is_our_move) depth--;
            }
            if (depth <= 0) continue;

            RepertoireLine *line = &out_lines[num_lines];
            memcpy(line->moves_san, current.moves_san, sizeof(current.moves_san));
            memcpy(line->moves_uci, current.moves_uci, sizeof(current.moves_uci));
            memcpy(line->is_engine_injected, current.is_engine_injected, sizeof(current.is_engine_injected));
            line->num_moves = depth;
            line->probability = current.node
                ? current.node->cumulative_probability : 0;
            line->line_score = 0;
            line->avg_ease_for_us = 0;
            line->avg_ease_for_opponent = 0;
            line->mistake_potential = 0;
            if (current.node) {
                line->leaf_prune_reason = current.node->prune_reason;
                line->leaf_prune_eval_cp = current.node->prune_eval_cp;
            }
            num_lines++;
        }
    }

    free(stack);
    return num_lines;
}


/* ========== Main Entry Point ========== */

static void load_evals_callback(TreeNode *node, void *user_data) {
    RepertoireDB *d = (RepertoireDB *)user_data;
    if (node->has_engine_eval) return;
    int eval_cp, depth;
    if (rdb_get_eval(d, node->fen, &eval_cp, &depth))
        node_set_eval(node, eval_cp);
}

RepertoireResult* generate_repertoire(Tree *tree, RepertoireDB *db,
                                       EnginePool *engine_pool,
                                       const RepertoireConfig *config_in,
                                       void (*progress)(const char *stage,
                                                         int current, int total)) {
    if (!tree || !tree->root || !db || !config_in) return NULL;

    RepertoireConfig cfg_local = *config_in;
    const RepertoireConfig *config = &cfg_local;

    RepertoireResult *result = (RepertoireResult *)calloc(1, sizeof(RepertoireResult));
    if (!result) return NULL;

    int max_moves = (int)tree->total_nodes;
    result->moves = (RepertoireMove *)calloc(max_moves, sizeof(RepertoireMove));
    result->lines = (RepertoireLine *)calloc(10000, sizeof(RepertoireLine));
    if (!result->moves || !result->lines) {
        free(result->moves);
        free(result->lines);
        free(result);
        return NULL;
    }

    /* Load DB-cached evals into nodes (needed for trees loaded from JSON) */
    if (progress) progress("Loading evals", 0, (int)tree->total_nodes);
    tree_traverse_bfs(tree, load_evals_callback, db);

    /* Resolve --relative eval offsets */
    if (cfg_local.relative_eval) {
        int root_eval = get_eval_for_us(tree->root, cfg_local.play_as_white);
        printf("  Root eval (our perspective): %+dcp\n", root_eval);
        cfg_local.min_eval_cp += root_eval;
        cfg_local.max_eval_cp += root_eval;
        printf("  Relative: min=%+d, max=%+d\n",
               cfg_local.min_eval_cp, cfg_local.max_eval_cp);
    }

    /* Ease scores (from node evals, computed in tree.c) */
    if (progress) progress("Ease calculation", 0, (int)tree->total_nodes);
    size_t ease_count = tree_calculate_ease(tree);
    printf("  Computed %zu ease scores\n", ease_count);

    /* ECA (Expected Centipawn Advantage) */
    if (progress) progress("ECA calculation", 0, (int)tree->total_nodes);
    size_t eca_count = tree_calculate_eca(tree, config);
    printf("  Computed ECA for %zu nodes (depth-decay=%.2f, eval-weight=%.2f)\n",
           eca_count, config->depth_discount, config->eval_weight);
    if (tree->root && tree->root->has_eca)
        printf("  Root accumulated ECA: %.4f wp-delta\n",
               tree->root->accumulated_eca);

    /* Select repertoire moves */
    if (progress) progress("Move selection", 0, (int)tree->total_nodes);
    result->num_moves = 0;
    build_repertoire_recursive(tree->root, tree, db, engine_pool, config,
                                result->moves, &result->num_moves, max_moves,
                                progress);
    printf("  Selected %d repertoire moves\n", result->num_moves);

    /* Extract complete lines */
    if (progress) progress("Line extraction", 0, 0);
    result->num_lines = extract_lines(tree, result->moves, result->num_moves,
                                       config, result->lines, 10000);
    printf("  Extracted %d complete lines\n", result->num_lines);

    /* Summary statistics */
    result->total_positions_analyzed = (int)tree->total_nodes;
    double total_eval = 0, total_ease = 0;
    int eval_count = 0, ease_count2 = 0;
    for (int i = 0; i < result->num_moves; i++) {
        total_eval += result->moves[i].eval_cp;
        eval_count++;
        if (result->moves[i].ease_score >= 0) {
            total_ease += result->moves[i].ease_score;
            ease_count2++;
        }
    }
    result->avg_eval = eval_count > 0 ? total_eval / eval_count : 0;
    result->avg_ease = ease_count2 > 0 ? total_ease / ease_count2 : 0;

    return result;
}


void repertoire_result_free(RepertoireResult *result) {
    if (!result) return;
    free(result->moves);
    free(result->lines);
    free(result);
}


/* ========== Mistake-Prone Lines ========== */

typedef struct {
    TreeNode *node;
    double trap_score;
} TrapCandidate;

typedef struct {
    TrapCandidate *cands;
    int *count;
    int max;
    RepertoireDB *db;
    bool as_white;
} TrapCtx;

static int trap_score_cmp_desc(const void *a, const void *b) {
    double sa = ((const TrapCandidate *)a)->trap_score;
    double sb = ((const TrapCandidate *)b)->trap_score;
    return (sa < sb) - (sa > sb);
}

static void find_traps_callback(TreeNode *node, void *user_data) {
    TrapCtx *ctx = (TrapCtx *)user_data;
    bool is_opponent_move = ctx->as_white
        ? !node->is_white_to_move
        : node->is_white_to_move;
    if (!is_opponent_move) return;
    if (node->children_count < 2) return;

    double trap = calculate_trap_score(node, ctx->db);
    if (trap > 0.05 && *ctx->count < ctx->max) {
        ctx->cands[*ctx->count].node = node;
        ctx->cands[*ctx->count].trap_score = trap;
        (*ctx->count)++;
    }
}

int find_mistake_prone_lines(const Tree *tree, RepertoireDB *db,
                              bool play_as_white,
                              RepertoireLine *out_lines, int max_lines) {
    if (!tree || !tree->root || !db || !out_lines) return 0;

    int max_candidates = (int)tree->total_nodes;
    TrapCandidate *candidates = (TrapCandidate *)calloc(max_candidates,
                                                         sizeof(TrapCandidate));
    if (!candidates) return 0;

    int num_candidates = 0;
    TrapCtx ctx = { candidates, &num_candidates, max_candidates, db, play_as_white };
    tree_traverse_dfs(tree, find_traps_callback, &ctx);

    qsort(candidates, num_candidates, sizeof(TrapCandidate), trap_score_cmp_desc);

    int num_lines = 0;
    for (int i = 0; i < num_candidates && num_lines < max_lines; i++) {
        TreeNode *node = candidates[i].node;
        RepertoireLine *line = &out_lines[num_lines];

        char moves[128][16];
        size_t path_len = tree_get_line_to_node(node, moves, 128);

        for (size_t j = 0; j < path_len && j < 128; j++)
            strncpy(line->moves_san[j], moves[j], 15);
        line->num_moves = (int)path_len;
        line->mistake_potential = candidates[i].trap_score;
        line->probability = node->cumulative_probability;

        num_lines++;
    }

    free(candidates);
    return num_lines;
}


/* ========== Export Functions ========== */

bool repertoire_export_pgn(const RepertoireResult *result,
                            const char *filename,
                            const RepertoireConfig *config) {
    if (!result || !filename) return false;

    FILE *f = fopen(filename, "w");
    if (!f) return false;

    bool root_white_to_move = true;
    if (config && config->start_fen[0]) {
        const char *sp = strchr(config->start_fen, ' ');
        if (sp && *(sp + 1) == 'b') root_white_to_move = false;
    }

    bool has_name = config && config->name[0];

    for (int i = 0; i < result->num_lines; i++) {
        const RepertoireLine *line = &result->lines[i];

        if (has_name)
            fprintf(f, "[Event \"%s Line #%d\"]\n", config->name, i + 1);
        else
            fprintf(f, "[Event \"Repertoire Line #%d\"]\n", i + 1);
        fprintf(f, "[Site \"tree_builder\"]\n");
        fprintf(f, "[Date \"????.??.??\"]\n");
        fprintf(f, "[Round \"-\"]\n");
        fprintf(f, "[White \"%s\"]\n",
                config->play_as_white ? "Repertoire" : "Opponent");
        fprintf(f, "[Black \"%s\"]\n",
                config->play_as_white ? "Opponent" : "Repertoire");
        if (config && config->start_fen[0] &&
            strcmp(config->start_fen,
                   "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") != 0) {
            fprintf(f, "[FEN \"%s\"]\n", config->start_fen);
            fprintf(f, "[SetUp \"1\"]\n");
        }
        fprintf(f, "[Result \"*\"]\n\n");

        for (int j = 0; j < line->num_moves; j++) {
            int ply = j + (root_white_to_move ? 0 : 1);
            if (ply % 2 == 0)
                fprintf(f, "%d. ", (ply / 2) + 1);
            else if (j == 0 && !root_white_to_move)
                fprintf(f, "%d... ", (ply / 2) + 1);
            fprintf(f, "%s ", line->moves_san[j]);
            if (line->is_engine_injected[j] &&
                (j == 0 || !line->is_engine_injected[j - 1])) {
                fprintf(f, "{Engine best move} ");
            }
        }
        if (line->leaf_prune_reason == PRUNE_EVAL_TOO_HIGH) {
            fprintf(f, "{Already winning (%+.1f); no further preparation needed} ",
                    line->leaf_prune_eval_cp / 100.0);
        }
        fprintf(f, "*\n");
    }

    fclose(f);
    return true;
}


bool repertoire_export_json(const RepertoireResult *result, const char *filename) {
    if (!result || !filename) return false;

    cJSON *root = cJSON_CreateObject();
    if (!root) return false;

    cJSON_AddStringToObject(root, "type", "auto_repertoire");
    cJSON_AddNumberToObject(root, "total_moves", result->num_moves);
    cJSON_AddNumberToObject(root, "total_lines", result->num_lines);
    cJSON_AddNumberToObject(root, "positions_analyzed",
                            result->total_positions_analyzed);
    cJSON_AddNumberToObject(root, "avg_eval", result->avg_eval);
    cJSON_AddNumberToObject(root, "avg_ease", result->avg_ease);

    cJSON *moves = cJSON_CreateArray();
    for (int i = 0; i < result->num_moves; i++) {
        const RepertoireMove *rm = &result->moves[i];
        cJSON *move = cJSON_CreateObject();
        cJSON_AddStringToObject(move, "fen", rm->fen);
        cJSON_AddStringToObject(move, "move_san", rm->move_san);
        cJSON_AddStringToObject(move, "move_uci", rm->move_uci);
        cJSON_AddNumberToObject(move, "score", rm->composite_score);
        cJSON_AddNumberToObject(move, "eval_cp", rm->eval_cp);
        cJSON_AddNumberToObject(move, "probability", rm->probability);
        cJSON_AddNumberToObject(move, "total_games", (double)rm->total_games);
        cJSON_AddNumberToObject(move, "depth", rm->depth);
        cJSON_AddItemToArray(moves, move);
    }
    cJSON_AddItemToObject(root, "moves", moves);

    cJSON *lines = cJSON_CreateArray();
    for (int i = 0; i < result->num_lines; i++) {
        const RepertoireLine *rl = &result->lines[i];
        cJSON *line = cJSON_CreateObject();
        cJSON *line_moves = cJSON_CreateArray();
        for (int j = 0; j < rl->num_moves; j++)
            cJSON_AddItemToArray(line_moves, cJSON_CreateString(rl->moves_san[j]));
        cJSON_AddItemToObject(line, "moves", line_moves);
        cJSON_AddNumberToObject(line, "score", rl->line_score);
        cJSON_AddNumberToObject(line, "probability", rl->probability);
        cJSON_AddNumberToObject(line, "mistake_potential", rl->mistake_potential);
        if (rl->opening_name[0])
            cJSON_AddStringToObject(line, "opening", rl->opening_name);
        cJSON_AddItemToArray(lines, line);
    }
    cJSON_AddItemToObject(root, "lines", lines);

    char *json_str = cJSON_Print(root);
    cJSON_Delete(root);
    if (!json_str) return false;

    FILE *f = fopen(filename, "w");
    if (!f) { free(json_str); return false; }
    fputs(json_str, f);
    fclose(f);
    free(json_str);

    return true;
}


void repertoire_print_summary(const RepertoireResult *result) {
    if (!result) return;

    printf("\n");
    printf("  Positions analyzed: %d\n", result->total_positions_analyzed);
    printf("  Repertoire moves:  %d\n", result->num_moves);
    printf("  Complete lines:    %d\n", result->num_lines);
    printf("  Average eval:      %+.0f cp\n", result->avg_eval);
    printf("  Average ease:      %.3f\n", result->avg_ease);

    if (result->num_lines > 0) {
        printf("\n  Top lines:\n");
        int show = result->num_lines < 10 ? result->num_lines : 10;
        for (int i = 0; i < show; i++) {
            const RepertoireLine *line = &result->lines[i];
            printf("  %d. ", i + 1);
            for (int j = 0; j < line->num_moves && j < 20; j++) {
                if (j % 2 == 0) printf("%d.", (j / 2) + 1);
                printf("%s ", line->moves_san[j]);
            }
            if (line->num_moves > 20) printf("...");
            printf(" (prob=%.2f%%", line->probability * 100);
            if (line->mistake_potential > 0)
                printf(", trap=%.1f%%", line->mistake_potential * 100);
            printf(")\n");
        }
    }
    printf("\n");
}
