/**
 * repertoire.c - Automatic Repertoire Generation
 *
 * Selection phase: runs AFTER the interleaved build has populated the
 * tree with engine evaluations.  Computes expectimax values and selects
 * one move at each our-move node.
 *
 * At our-move nodes: pick the child with the highest expectimax value.
 * At opponent nodes: traverse all children (already capped during build).
 */

#include "repertoire.h"
#include "chess_logic.h"
#include "cJSON.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

/* ========== Configuration ========== */

RepertoireConfig repertoire_config_default(void) {
    RepertoireConfig config = {
        .play_as_white = true,
        .max_depth = 20,
        .min_probability = 0.0001,
        .min_games = 10,

        .eval_depth = 20,
        .quick_eval_depth = 15,

        .leaf_confidence = 1.0,
        .novelty_weight = 0,
        .min_eval_cp = 0,
        .max_eval_cp = 200,
        .max_eval_loss_cp = 50,

        .max_candidates_per_position = 8,
        .verbose_search = false,
        .start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        .name = "",
    };
    return config;
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


/* ========== Transposition Resolution ========== */

static TreeNode* resolve_transposition(TreeNode *node) {
    if (!node || node->children_count > 0 || !node->next_equivalent)
        return node;
    TreeNode *equiv = node->next_equivalent;
    while (equiv != node) {
        if (equiv->children_count > 0)
            return equiv;
        if (!equiv->next_equivalent || equiv->next_equivalent == node)
            break;
        equiv = equiv->next_equivalent;
    }
    return node;
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

    node = resolve_transposition(node);
    if (node->children_count == 0) return;

    if (node->depth > 0) {
        int eval_us = node_eval_for_us(node, config->play_as_white);
        if (eval_us < config->min_eval_cp || eval_us > config->max_eval_cp)
            return;
    }

    bool is_our_move = config->play_as_white
                     ? node->is_white_to_move
                     : !node->is_white_to_move;

    if (is_our_move) {
        ScoredChild winner;
        score_our_move_children(node, config, &winner);

        if (winner.child && *num_moves < max_moves) {
            TreeNode *best_child = winner.child;
            RepertoireMove *rm = &out_moves[*num_moves];
            strncpy(rm->fen, node->fen, sizeof(rm->fen) - 1);
            strncpy(rm->move_san, best_child->move_san, sizeof(rm->move_san) - 1);
            strncpy(rm->move_uci, best_child->move_uci, sizeof(rm->move_uci) - 1);
            rm->composite_score = winner.expectimax_value;
            rm->depth = node->depth;
            rm->probability = node->cumulative_probability;
            rm->eval_cp = best_child->has_engine_eval ? best_child->engine_eval_cp : 0;
            rm->total_games = best_child->total_games;
            (*num_moves)++;

            rdb_save_repertoire_move(db, node->fen, best_child->move_san,
                                      best_child->move_uci, winner.expectimax_value);

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
    TreeNode *resolved = resolve_transposition(node);
    for (int m = 0; m < num_moves; m++) {
        if (strcmp(moves[m].fen, node->fen) != 0) continue;
        for (size_t c = 0; c < resolved->children_count; c++) {
            if (strcmp(resolved->children[c]->move_san, moves[m].move_san) == 0)
                return resolved->children[c];
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
        int depth;
    } LineState;

    int stack_cap = max_lines < 2000 ? 2000 : max_lines;
    LineState *stack = (LineState *)calloc(stack_cap, sizeof(LineState));
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
            if (selected && stack_top < stack_cap) {
                LineState *next = &stack[stack_top];
                next->node = selected;
                next->depth = current.depth + 1;
                memcpy(next->moves_san, current.moves_san, sizeof(current.moves_san));
                memcpy(next->moves_uci, current.moves_uci, sizeof(current.moves_uci));
                strncpy(next->moves_san[current.depth], selected->move_san, 15);
                strncpy(next->moves_uci[current.depth], selected->move_uci, 15);
                stack_top++;
                pushed_any = true;
            }
        } else {
            TreeNode *resolved = resolve_transposition(node);
            for (size_t i = 0; i < resolved->children_count; i++) {
                TreeNode *child = resolved->children[i];
                if (child->cumulative_probability < config->min_probability) continue;
                if (stack_top < stack_cap) {
                    LineState *next = &stack[stack_top];
                    next->node = child;
                    next->depth = current.depth + 1;
                    memcpy(next->moves_san, current.moves_san, sizeof(current.moves_san));
                    memcpy(next->moves_uci, current.moves_uci, sizeof(current.moves_uci));
                    strncpy(next->moves_san[current.depth], child->move_san, 15);
                    strncpy(next->moves_uci[current.depth], child->move_uci, 15);
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
    int max_lines = max_moves < 10000 ? max_moves : 10000;
    result->moves = (RepertoireMove *)calloc(max_moves, sizeof(RepertoireMove));
    result->lines = (RepertoireLine *)calloc(max_lines, sizeof(RepertoireLine));
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
        int root_eval = node_eval_for_us(tree->root, cfg_local.play_as_white);
        printf("  Root eval (our perspective): %+dcp\n", root_eval);
        cfg_local.min_eval_cp += root_eval;
        cfg_local.max_eval_cp += root_eval;
        printf("  Relative: min=%+d, max=%+d\n",
               cfg_local.min_eval_cp, cfg_local.max_eval_cp);
    }

    /* Expectimax value propagation */
    if (progress) progress("Expectimax calculation", 0, (int)tree->total_nodes);
    size_t emx_count = tree_calculate_expectimax(tree, config);
    printf("  Computed expectimax for %zu nodes\n", emx_count);
    if (tree->root && tree->root->has_expectimax)
        printf("  Root expectimax value: %.4f\n",
               tree->root->expectimax_value);

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
                                       config, result->lines, max_lines);
    printf("  Extracted %d complete lines\n", result->num_lines);

    /* Summary statistics */
    result->total_positions_analyzed = (int)tree->total_nodes;
    double total_eval = 0;
    int eval_count = 0;
    for (int i = 0; i < result->num_moves; i++) {
        total_eval += result->moves[i].eval_cp;
        eval_count++;
    }
    result->avg_eval = eval_count > 0 ? total_eval / eval_count : 0;

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
        {
            time_t now = time(NULL);
            struct tm *tm = localtime(&now);
            fprintf(f, "[Date \"%04d.%02d.%02d\"]\n",
                    tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday);
        }
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
        if (config->build_time_seconds > 0) {
            fprintf(f, "[BuildTimeSeconds \"%.1f\"]\n", config->build_time_seconds);
            fprintf(f, "[BuildNodes \"%d\"]\n", config->build_nodes);
            fprintf(f, "[BuildNodesPerMin \"%.1f\"]\n", config->nodes_per_minute);
            fprintf(f, "[BuildBranchingFactor \"%.2f\"]\n", config->branching_factor);
            fprintf(f, "[BuildThreads \"%d\"]\n", config->build_threads);
            fprintf(f, "[BuildEvalDepth \"%d\"]\n", config->build_eval_depth);
        }
        fprintf(f, "[Result \"*\"]\n\n");

        fprintf(f, "{CumProb %.3f%%, Eval %d cp",
                line->probability * 100.0,
                line->leaf_prune_reason == PRUNE_EVAL_TOO_HIGH
                    ? line->leaf_prune_eval_cp
                    : (int)line->final_eval);
        if (line->leaf_prune_reason == PRUNE_EVAL_TOO_HIGH) {
            fprintf(f, ", Already winning (%+.1f)",
                    line->leaf_prune_eval_cp / 100.0);
        }
        fprintf(f, "}\n");

        for (int j = 0; j < line->num_moves; j++) {
            int ply = j + (root_white_to_move ? 0 : 1);
            if (ply % 2 == 0)
                fprintf(f, "%d. ", (ply / 2) + 1);
            else if (j == 0 && !root_white_to_move)
                fprintf(f, "%d... ", (ply / 2) + 1);
            fprintf(f, "%s ", line->moves_san[j]);
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
