/**
 * tree.c - Opening Tree Implementation
 */

#include "tree.h"
#include "repertoire.h"
#include "lichess_api.h"
#include "chess_logic.h"
#include "maia.h"
#include "engine_pool.h"
#include "database.h"
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
        .min_probability = 0.0001,          /* 0.01% */
        .max_depth = 30,                    /* 30 ply = 15 moves each */
        .max_nodes = 0,                     /* Unlimited */
        .max_children = 0,                  /* Unlimited moves per position */
        .opponent_mass_target = 0.0,        /* 0 = disabled; 0.80 = cover 80% of prob mass */
        .rating_range = "2000,2200,2500",
        .speeds = "blitz,rapid,classical",
        .min_games = 10,
        .use_masters = false,
        .maia = NULL,
        .maia_elo = 2000,
        .maia_threshold = 0.01,             /* Fall back to Maia above 1% cumProb */
        .maia_min_prob = 0.02,              /* Skip Maia moves below 2% */
        .progress_callback = NULL
    };
    return config;
}


Tree* tree_create(void) {
    Tree *tree = (Tree *)calloc(1, sizeof(Tree));
    if (!tree) {
        return NULL;
    }
    
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
    
    if (tree->root) {
        node_destroy(tree->root);
    }
    
    free(tree);
}


/**
 * Internal recursive build function
 */
static void build_recursive(Tree *tree, TreeNode *node, 
                            const TreeConfig *config, 
                            LichessExplorer *explorer) {
    /* Check stop conditions */
    if (!tree->is_building) return;
    
    if (node->depth >= config->max_depth) return;
    
    if (node->cumulative_probability < config->min_probability) return;
    
    if (config->max_nodes > 0 && tree->total_nodes >= (size_t)config->max_nodes) return;

    /* Resume support: skip nodes that were already explored.
       A node with children was explored and had valid moves.
       A childless node with total_games > 0 was queried but yielded nothing. */
    if (node->children_count > 0) {
        for (size_t i = 0; i < node->children_count; i++) {
            build_recursive(tree, node->children[i], config, explorer);
        }
        return;
    }
    if (node->explored) {
        return;
    }
    
    /* Query Lichess explorer for this position */
    ExplorerResponse response;
    bool query_ok = config->use_masters
        ? lichess_explorer_query_masters(explorer, node->fen, &response)
        : lichess_explorer_query(explorer, node->fen, &response);
    if (!query_ok) {
        fprintf(stderr, "Warning: Explorer query failed for %s\n", node->fen);
        return;
    }

    bool use_maia = false;
    MaiaResponse maia_resp;
    memset(&maia_resp, 0, sizeof(maia_resp));

    if (!response.success || response.move_count == 0 ||
        response.total_games < (uint64_t)config->min_games) {
        /*
         * Explorer exhausted or insufficient data.
         * Fall back to Maia if the line is likely enough.
         */
        if (config->maia &&
            node->cumulative_probability >= config->maia_threshold) {
            if (maia_evaluate(config->maia, node->fen,
                              config->maia_elo, &maia_resp) &&
                maia_resp.success && maia_resp.move_count > 0) {
                use_maia = true;
            }
        }

        if (!use_maia) {
            /* Mark as explored-but-empty so resume skips it */
            node->explored = true;
            if (response.success && response.total_games > 0)
                node_set_lichess_stats(node,
                    response.total_white_wins,
                    response.total_black_wins,
                    response.total_draws);
            return;
        }
    }

    /* Update node with total stats (explorer path only) */
    node->explored = true;
    if (!use_maia) {
        node_set_lichess_stats(node, 
                               response.total_white_wins,
                               response.total_black_wins, 
                               response.total_draws);

        if (response.has_opening) {
            strncpy(node->opening_name, response.opening_name, sizeof(node->opening_name) - 1);
            strncpy(node->opening_eco, response.opening_eco, sizeof(node->opening_eco) - 1);
        }
    }

    uint64_t total = use_maia ? 0 : response.total_games;

    bool is_our_move = (node->is_white_to_move == config->play_as_white);
    int children_added = 0;
    double mass_covered = 0.0;
    size_t move_count = use_maia ? (size_t)maia_resp.move_count
                                 : response.move_count;

    for (size_t i = 0; i < move_count; i++) {
        /* Extract move data from either source */
        const char *uci;
        const char *san;
        double prob;
        uint64_t mw = 0, mb = 0, md = 0;

        if (use_maia) {
            uci  = maia_resp.moves[i].uci;
            san  = maia_resp.moves[i].uci;   /* UCI as SAN placeholder */
            prob = maia_resp.moves[i].probability;
            if (prob < config->maia_min_prob) continue;
        } else {
            ExplorerMove *move = &response.moves[i];
            uci = move->uci;
            san = move->san;
            uint64_t move_games = move->white_wins + move->draws + move->black_wins;
            prob = (double)move_games / (double)total;
            mw = move->white_wins;
            mb = move->black_wins;
            md = move->draws;
            if (move_games < (uint64_t)config->min_games) continue;
        }

        if (config->max_children > 0 && children_added >= config->max_children)
            break;
        if (config->opponent_mass_target > 0.0 && mass_covered >= config->opponent_mass_target)
            break;

        double new_cumul = is_our_move
            ? node->cumulative_probability
            : node->cumulative_probability * prob;

        if (new_cumul < config->min_probability)
            continue;
        
        /* Generate child FEN */
        ChessPosition chess_pos;
        if (!position_from_fen(&chess_pos, node->fen)) {
            fprintf(stderr, "Warning: Failed to parse FEN: %s\n", node->fen);
            continue;
        }
        if (!position_apply_uci(&chess_pos, uci)) {
            fprintf(stderr, "Warning: Failed to apply move %s to %s\n", uci, node->fen);
            continue;
        }
        char child_fen[MAX_FEN_LENGTH];
        position_to_fen(&chess_pos, child_fen, MAX_FEN_LENGTH);
        
        TreeNode *child = node_create(child_fen, san, uci, node);
        if (!child) {
            fprintf(stderr, "Error: Failed to allocate child node\n");
            continue;
        }
        
        child->move_probability = prob;
        child->cumulative_probability = new_cumul;
        if (!use_maia) node_set_lichess_stats(child, mw, mb, md);
        
        if (!node_add_child(node, child)) {
            node_destroy_single(child);
            continue;
        }
        
        tree->total_nodes++;
        children_added++;
        mass_covered += prob;
        
        if (child->depth > tree->max_depth_reached)
            tree->max_depth_reached = child->depth;
        
        if (config->progress_callback)
            config->progress_callback(tree->total_nodes, child->depth, child->fen);
        
        build_recursive(tree, child, config, explorer);
    }
}


bool tree_build(Tree *tree, const char *start_fen, 
                const TreeConfig *config, LichessExplorer *explorer) {
    if (!tree || !start_fen || !explorer) {
        return false;
    }
    
    /* Store config */
    tree->config = *config;

    /* Reuse existing root if present (resume), otherwise create new */
    if (tree->root) {
        /* Resuming — keep existing tree intact */
    } else {
        tree->root = node_create(start_fen, NULL, NULL, NULL);
        if (!tree->root) {
            return false;
        }
        tree->total_nodes = 1;
    }
    if (tree->total_nodes <= 1) tree->max_depth_reached = 0;
    tree->is_building = true;
    
    /* Build recursively */
    build_recursive(tree, tree->root, config, explorer);
    
    tree->build_complete = tree->is_building; /* true only if not interrupted */
    tree->is_building = false;
    
    return true;
}


void tree_stop_build(Tree *tree) {
    if (tree) {
        tree->is_building = false;
    }
}


/**
 * Internal recursive search by FEN
 */
static TreeNode* find_by_fen_recursive(TreeNode *node, const char *fen) {
    if (!node) return NULL;
    
    if (strcmp(node->fen, fen) == 0) {
        return node;
    }
    
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


/**
 * Internal recursive leaf collection
 */
static void collect_leaves(TreeNode *node, TreeNode **leaves, 
                           size_t *count, size_t max_count) {
    if (!node || *count >= max_count) return;
    
    if (node->children_count == 0) {
        leaves[*count] = node;
        (*count)++;
        return;
    }
    
    for (size_t i = 0; i < node->children_count; i++) {
        collect_leaves(node->children[i], leaves, count, max_count);
    }
}


size_t tree_get_leaves(const Tree *tree, TreeNode **out_leaves, size_t max_leaves) {
    if (!tree || !tree->root || !out_leaves) return 0;
    
    size_t count = 0;
    collect_leaves(tree->root, out_leaves, &count, max_leaves);
    return count;
}


/**
 * Internal recursive depth collection
 */
static void collect_at_depth(TreeNode *node, int target_depth,
                              TreeNode **nodes, size_t *count, size_t max_count) {
    if (!node || *count >= max_count) return;
    
    if (node->depth == target_depth) {
        nodes[*count] = node;
        (*count)++;
        return;
    }
    
    if (node->depth > target_depth) return;
    
    for (size_t i = 0; i < node->children_count; i++) {
        collect_at_depth(node->children[i], target_depth, nodes, count, max_count);
    }
}


size_t tree_get_nodes_at_depth(const Tree *tree, int depth, 
                                TreeNode **out_nodes, size_t max_nodes) {
    if (!tree || !tree->root || !out_nodes) return 0;
    
    size_t count = 0;
    collect_at_depth(tree->root, depth, out_nodes, &count, max_nodes);
    return count;
}


/* Q-value conversion: maps centipawns to [-1, 1] with diminishing returns */
static double ease_cp_to_q(int cp) {
    if (abs(cp) > 9000) return cp > 0 ? 1.0 : -1.0;
    double wp = 1.0 / (1.0 + exp(-0.004 * cp));
    return 2.0 * wp - 1.0;
}

/**
 * Calculate ease for a single node based on children evaluations.
 * Uses Q-value regret (matching the Flutter/Python implementation):
 *   ease = 1 - (Σ(prob^β × max(0, Q_best - Q_move)) / 2)^α
 */
static void calculate_node_ease(TreeNode *node) {
    if (!node || node->children_count == 0) {
        return;
    }

    /* Find best evaluation among children (from parent's side-to-move perspective) */
    int best_eval = -100000;
    bool has_evals = false;

    for (size_t i = 0; i < node->children_count; i++) {
        if (node->children[i]->has_engine_eval) {
            int eval_for_us = -node->children[i]->engine_eval_cp;
            if (eval_for_us > best_eval) {
                best_eval = eval_for_us;
            }
            has_evals = true;
        }
    }

    if (!has_evals) {
        return;
    }

    double q_max = ease_cp_to_q(best_eval);

    double sum_weighted_regret = 0.0;

    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_engine_eval) continue;
        if (child->move_probability < 0.01) continue;

        int child_eval = -child->engine_eval_cp;
        double q_val = ease_cp_to_q(child_eval);
        double regret = fmax(0.0, q_max - q_val);
        sum_weighted_regret += pow(child->move_probability, EASE_BETA) * regret;
    }

    double ease = 1.0 - pow(sum_weighted_regret / 2.0, EASE_ALPHA);

    if (ease < 0.0) ease = 0.0;
    if (ease > 1.0) ease = 1.0;

    node_set_ease(node, ease);
}


/**
 * Internal recursive ease calculation
 */
static size_t calculate_ease_recursive(TreeNode *node) {
    if (!node) return 0;
    
    size_t count = 0;
    
    /* Calculate ease for this node */
    if (node->children_count > 0) {
        calculate_node_ease(node);
        if (node->has_ease) count++;
    }
    
    /* Recurse into children */
    for (size_t i = 0; i < node->children_count; i++) {
        count += calculate_ease_recursive(node->children[i]);
    }
    
    return count;
}


size_t tree_calculate_ease(Tree *tree) {
    if (!tree || !tree->root) return 0;
    return calculate_ease_recursive(tree->root);
}


/* ========== ECA (Expected Centipawn Advantage — win-probability-delta) ========== */

/**
 * Win probability from centipawns (Lichess-calibrated sigmoid).
 * Maps centipawns to [0, 1] from White's perspective.
 */
double win_probability(int cp) {
    if (abs(cp) > 9000) return cp > 0 ? 1.0 : 0.0;
    return 1.0 / (1.0 + exp(-0.00368208 * cp));
}

/**
 * Centipawn eval from our perspective.
 * child->engine_eval_cp is from the child's STM perspective.
 */
static int eval_for_us(const TreeNode *child, bool play_as_white) {
    if (!child->has_engine_eval) return 0;
    int cp = child->engine_eval_cp;
    int eval_white = child->is_white_to_move ? cp : -cp;
    return play_as_white ? eval_white : -eval_white;
}

/**
 * Win probability from our perspective for a child node.
 */
static double wp_us(const TreeNode *child, bool play_as_white) {
    if (!child->has_engine_eval) return 0.5;
    int cp = child->engine_eval_cp;
    int eval_white = child->is_white_to_move ? cp : -cp;
    double wp_white = win_probability(eval_white);
    return play_as_white ? wp_white : (1.0 - wp_white);
}


/**
 * Compute local trickiness (wp-delta) for a single node from its children.
 *
 * Measures how much win probability the side-to-move hands the other side
 * by playing database moves instead of the best move.
 *
 * wp_for_mover(child) = 1 - wp(child.engine_eval_cp), since the child eval
 * is from the next-STM perspective (the mover's opponent).
 *
 * best_wp   = max(wp_for_mover(child)) over all children with evals
 * local_cpl = Σ(prob_i × max(0, best_wp - wp_for_mover(child_i)))
 *             for children with prob >= 0.01
 */
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


/**
 * Score all children at an our-move node with the blended formula.
 * Applies eval-guard and max-eval-loss filters; falls back to
 * scoring all children (no filters) when every child is excluded.
 *
 * Both the accumulation DFS and the selection DFS call this, so the
 * chosen child is guaranteed to be the same in both phases.
 */
int score_our_move_children(TreeNode *node,
                            const struct RepertoireConfig *config,
                            ScoredChild *best_out) {
    if (!node || !config || !best_out) return 0;

    best_out->child = NULL;
    best_out->score = -1e9;
    best_out->accumulated_eca = 0.0;

    /* Find best child eval (our perspective) for the max-eval-loss filter */
    int best_child_cp = -100000;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_engine_eval) continue;
        int cp_us = eval_for_us(child, config->play_as_white);
        if (cp_us > best_child_cp) best_child_cp = cp_us;
    }

    int passing = 0;
    double best_score = -1e9;
    TreeNode *best_child = NULL;
    double best_eca = 0.0;

    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_eca) continue;

        int cp_us = eval_for_us(child, config->play_as_white);
        if (cp_us < best_child_cp - config->max_eval_loss_cp) continue;

        double eval_us_wp = wp_us(child, config->play_as_white);
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

    /* Fallback: all filtered out → re-score all with blended (no filters) */
    if (passing == 0) {
        best_score = -1e9;
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (!child->has_eca) continue;
            double eval_us_wp = wp_us(child, config->play_as_white);
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


/**
 * Post-order DFS: compute local wp-delta values, then accumulate bottom-up.
 */
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


/**
 * Internal recursive probability recalculation.
 * Only opponent moves reduce cumulative probability — our moves are 100% certain.
 */
static void recalc_prob_recursive(TreeNode *node, double parent_cumul, bool play_as_white) {
    if (!node) return;

    /* The parent chose this move. If it was OUR move, cumP doesn't decrease.
     * If it was the OPPONENT's move, cumP = parent × moveProb. */
    bool parent_was_our_move = (node->parent &&
                                node->parent->is_white_to_move == play_as_white);
    node->cumulative_probability = parent_was_our_move
        ? parent_cumul
        : parent_cumul * node->move_probability;

    for (size_t i = 0; i < node->children_count; i++) {
        recalc_prob_recursive(node->children[i], node->cumulative_probability, play_as_white);
    }
}


void tree_recalculate_probabilities(Tree *tree) {
    if (!tree || !tree->root) return;
    
    tree->root->cumulative_probability = 1.0;
    
    for (size_t i = 0; i < tree->root->children_count; i++) {
        recalc_prob_recursive(tree->root->children[i], 1.0, tree->config.play_as_white);
    }
}


size_t tree_get_line_to_node(const TreeNode *node, char (*out_moves)[MAX_MOVE_LENGTH], 
                              size_t max_moves) {
    if (!node || !out_moves) return 0;
    
    /* Count depth to root */
    size_t depth = 0;
    const TreeNode *temp = node;
    while (temp->parent) {
        depth++;
        temp = temp->parent;
    }
    
    if (depth == 0) return 0;
    if (depth > max_moves) depth = max_moves;
    
    /* Walk back from node, filling in moves from end */
    size_t idx = depth - 1;
    temp = node;
    while (temp->parent && idx < depth) {
        /* Use snprintf for safer string copy */
        snprintf(out_moves[idx], MAX_MOVE_LENGTH, "%s", temp->move_san);
        idx--;
        temp = temp->parent;
    }
    
    return depth;
}


void tree_print_stats(const Tree *tree) {
    if (!tree) {
        printf("Tree: (null)\n");
        return;
    }
    
    printf("\n=== Tree Statistics ===\n");
    printf("Total nodes: %zu\n", tree->total_nodes);
    printf("Max depth reached: %d ply\n", tree->max_depth_reached);
    
    if (tree->root) {
        printf("Root FEN: %s\n", tree->root->fen);
        printf("Actual node count: %zu\n", node_count_subtree(tree->root));
        
        if (tree->root->total_games > 0) {
            printf("Root position games: %lu\n", (unsigned long)tree->root->total_games);
        }
    }
    
    printf("\nConfiguration:\n");
    printf("  Min probability: %.4f%%\n", tree->config.min_probability * 100.0);
    printf("  Max depth: %d ply\n", tree->config.max_depth);
    printf("  Rating range: %s\n", tree->config.rating_range ? tree->config.rating_range : "(default)");
    printf("  Speeds: %s\n", tree->config.speeds ? tree->config.speeds : "(default)");
    printf("========================\n\n");
}


/**
 * Internal recursive print
 */
static void print_recursive(TreeNode *node, int max_depth) {
    if (!node) return;
    
    if (max_depth >= 0 && node->depth > max_depth) return;
    
    node_print(node, node->depth);
    
    for (size_t i = 0; i < node->children_count; i++) {
        print_recursive(node->children[i], max_depth);
    }
}


void tree_print(const Tree *tree, int max_depth) {
    if (!tree || !tree->root) {
        printf("Tree: (empty)\n");
        return;
    }
    
    printf("\n=== Tree Structure ===\n");
    print_recursive(tree->root, max_depth);
    printf("======================\n\n");
}


/**
 * Internal DFS traversal
 */
static void traverse_dfs_recursive(TreeNode *node,
                                    void (*callback)(TreeNode *, void *),
                                    void *user_data) {
    if (!node) return;
    
    callback(node, user_data);
    
    for (size_t i = 0; i < node->children_count; i++) {
        traverse_dfs_recursive(node->children[i], callback, user_data);
    }
}


void tree_traverse_dfs(const Tree *tree, 
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data) {
    if (!tree || !tree->root || !callback) return;
    traverse_dfs_recursive(tree->root, callback, user_data);
}


/**
 * Simple queue for BFS
 */
typedef struct {
    TreeNode **nodes;
    size_t capacity;
    size_t head;
    size_t count;
} NodeQueue;


static NodeQueue* queue_create(size_t capacity) {
    NodeQueue *q = (NodeQueue *)malloc(sizeof(NodeQueue));
    if (!q) return NULL;
    
    q->nodes = (TreeNode **)malloc(capacity * sizeof(TreeNode *));
    if (!q->nodes) {
        free(q);
        return NULL;
    }
    
    q->capacity = capacity;
    q->head = 0;
    q->count = 0;
    
    return q;
}


static void queue_destroy(NodeQueue *q) {
    if (q) {
        free(q->nodes);
        free(q);
    }
}


static bool queue_push(NodeQueue *q, TreeNode *node) {
    if (q->head + q->count >= q->capacity) {
        if (q->head > 0) {
            memmove(q->nodes, q->nodes + q->head, q->count * sizeof(TreeNode *));
            q->head = 0;
        } else {
            size_t new_cap = q->capacity * 2;
            TreeNode **new_nodes = (TreeNode **)realloc(q->nodes, new_cap * sizeof(TreeNode *));
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
            for (size_t i = 0; i < node->children_count; i++) {
                if (node->children[i])
                    queue_push(queue, node->children[i]);
            }
        }
    }
    
    queue_destroy(queue);
}


/* ========== Stockfish Discovery Pass ========== */

DiscoveryConfig discovery_config_default(void) {
    DiscoveryConfig config = {
        .play_as_white = true,
        .multipv = 3,
        .search_depth = 20,
        .max_eval_loss_cp = 50,
        .expansion_depth = 4,
        .min_probability = 0.0001,
        .maia_elo = 2000,
        .maia_min_prob = 0.02,
        .max_maia_responses = 3,
    };
    return config;
}


/**
 * Create a child node by applying a UCI move.
 * Returns the new node (already added to parent), or NULL on failure.
 */
static TreeNode *add_child_from_uci(TreeNode *parent, const char *uci,
                                     Tree *tree) {
    ChessPosition pos;
    if (!position_from_fen(&pos, parent->fen)) return NULL;
    if (!position_apply_uci(&pos, uci)) return NULL;

    char child_fen[MAX_FEN_LENGTH];
    position_to_fen(&pos, child_fen, MAX_FEN_LENGTH);

    TreeNode *child = node_create(child_fen, uci, uci, parent);
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


/**
 * Expand a newly discovered branch with opponent responses.
 *
 * At our-move nodes:       Stockfish top-1 → single child
 * At opponent-move nodes:  Maia top-N + Stockfish top-1 (deduplicated)
 */
static void expand_new_branch(TreeNode *node, int remaining_ply,
                               Tree *tree, EnginePool *engine_pool,
                               MaiaContext *maia, RepertoireDB *db,
                               const DiscoveryConfig *config) {
    if (!node || remaining_ply <= 0 || !tree->is_building) return;

    bool is_our_move = (node->is_white_to_move == config->play_as_white);

    if (is_our_move) {
        EvalJob job;
        if (!engine_pool_evaluate_full(engine_pool, node->fen, &job)) return;
        if (!job.success || job.bestmove[0] == '\0') return;

        TreeNode *child = add_child_from_uci(node, job.bestmove, tree);
        if (!child) return;

        child->move_probability = 1.0;
        child->cumulative_probability = node->cumulative_probability;
        node_set_eval(child, -job.eval_cp);
        if (db) rdb_put_eval(db, child->fen, -job.eval_cp, job.depth_reached);

        expand_new_branch(child, remaining_ply - 1,
                          tree, engine_pool, maia, db, config);
    } else {
        /* Opponent: Maia for likely human responses */
        int children_added = 0;

        if (maia) {
            MaiaResponse maia_resp;
            if (maia_evaluate(maia, node->fen, config->maia_elo, &maia_resp) &&
                maia_resp.success) {
                for (int m = 0; m < maia_resp.move_count &&
                                children_added < config->max_maia_responses; m++) {
                    if (maia_resp.moves[m].probability < config->maia_min_prob)
                        continue;

                    TreeNode *child = add_child_from_uci(
                        node, maia_resp.moves[m].uci, tree);
                    if (!child) continue;

                    child->move_probability = maia_resp.moves[m].probability;
                    child->cumulative_probability =
                        node->cumulative_probability * maia_resp.moves[m].probability;
                    children_added++;
                }
            }
        }

        /* Opponent: Stockfish top-1 (deduplicate against Maia) */
        EvalJob job;
        if (engine_pool_evaluate_full(engine_pool, node->fen, &job) &&
            job.success && job.bestmove[0]) {
            bool found = false;
            for (size_t c = 0; c < node->children_count; c++) {
                if (strcmp(node->children[c]->move_uci, job.bestmove) == 0) {
                    if (!node->children[c]->has_engine_eval)
                        node_set_eval(node->children[c], -job.eval_cp);
                    if (db) rdb_put_eval(db, node->children[c]->fen,
                                          -job.eval_cp, job.depth_reached);
                    found = true;
                    break;
                }
            }
            if (!found) {
                TreeNode *child = add_child_from_uci(node, job.bestmove, tree);
                if (child) {
                    child->move_probability = 0.01;
                    child->cumulative_probability =
                        node->cumulative_probability * 0.01;
                    node_set_eval(child, -job.eval_cp);
                    if (db) rdb_put_eval(db, child->fen,
                                          -job.eval_cp, job.depth_reached);
                }
            }
        }

        /* Recurse into all children of this opponent node */
        size_t n = node->children_count;
        for (size_t c = 0; c < n; c++) {
            expand_new_branch(node->children[c], remaining_ply - 1,
                              tree, engine_pool, maia, db, config);
        }
    }
}


int tree_discover_engine_moves(Tree *tree,
                                EnginePool *engine_pool,
                                MaiaContext *maia,
                                RepertoireDB *db,
                                const DiscoveryConfig *config,
                                void (*progress)(int discovered, int scanned,
                                                  const char *info)) {
    if (!tree || !tree->root || !engine_pool || !config) return 0;

    /* Phase 1: Collect our-move nodes that were explored by Lichess */
    size_t max_nodes = tree->total_nodes;
    TreeNode **our_nodes = (TreeNode **)calloc(max_nodes, sizeof(TreeNode *));
    if (!our_nodes) return 0;

    size_t num_our_nodes = 0;
    TreeNode **stack = (TreeNode **)malloc(max_nodes * sizeof(TreeNode *));
    if (!stack) { free(our_nodes); return 0; }

    int stack_top = 0;
    stack[stack_top++] = tree->root;

    while (stack_top > 0) {
        TreeNode *node = stack[--stack_top];
        if (!node) continue;

        bool is_our_move = (node->is_white_to_move == config->play_as_white);
        if (is_our_move &&
            node->children_count > 0 &&
            node->cumulative_probability >= config->min_probability) {
            our_nodes[num_our_nodes++] = node;
        }

        for (size_t i = 0; i < node->children_count; i++) {
            if (stack_top < (int)max_nodes)
                stack[stack_top++] = node->children[i];
        }
    }
    free(stack);

    printf("  Scanning %zu our-move positions (MultiPV %d, depth %d)...\n",
           num_our_nodes, config->multipv, config->search_depth);

    /* Phase 2: Run MultiPV on each our-move node */
    int total_discovered = 0;
    tree->is_building = true;

    size_t new_branch_cap = 256;
    TreeNode **new_branches = (TreeNode **)malloc(new_branch_cap * sizeof(TreeNode *));
    size_t num_new = 0;

    for (size_t i = 0; i < num_our_nodes; i++) {
        if (!tree->is_building) break;

        TreeNode *node = our_nodes[i];
        MultiPVJob mpv;
        if (!engine_pool_evaluate_multipv(engine_pool, node->fen,
                                           config->search_depth,
                                           config->multipv, &mpv))
            continue;
        if (!mpv.success || mpv.num_lines == 0) continue;

        int best_cp = mpv.lines[0].eval_cp;

        for (int pv = 0; pv < mpv.num_lines; pv++) {
            MultiPVLine *line = &mpv.lines[pv];
            if (line->move_uci[0] == '\0') continue;
            if (best_cp - line->eval_cp > config->max_eval_loss_cp) continue;

            /* Check if already a child */
            bool exists = false;
            for (size_t c = 0; c < node->children_count; c++) {
                if (strcmp(node->children[c]->move_uci, line->move_uci) == 0) {
                    if (!node->children[c]->has_engine_eval) {
                        node_set_eval(node->children[c], -line->eval_cp);
                        if (db) rdb_put_eval(db, node->children[c]->fen,
                                              -line->eval_cp, line->depth_reached);
                    }
                    exists = true;
                    break;
                }
            }
            if (exists) continue;

            /* New move: create child node */
            TreeNode *child = add_child_from_uci(node, line->move_uci, tree);
            if (!child) continue;

            child->move_probability = 0.0;
            child->cumulative_probability = node->cumulative_probability;
            node_set_eval(child, -line->eval_cp);
            if (db) rdb_put_eval(db, child->fen,
                                  -line->eval_cp, line->depth_reached);

            total_discovered++;

            /* Track for expansion */
            if (num_new >= new_branch_cap) {
                new_branch_cap *= 2;
                TreeNode **tmp = (TreeNode **)realloc(
                    new_branches, new_branch_cap * sizeof(TreeNode *));
                if (tmp) new_branches = tmp;
                else break;
            }
            new_branches[num_new++] = child;

            if (progress) {
                char info[128];
                snprintf(info, sizeof(info), "ply %d: %s (%+d cp)",
                         node->depth, line->move_uci, line->eval_cp);
                progress(total_discovered, (int)(i + 1), info);
            }
        }
    }

    printf("  Discovered %d new engine moves\n", total_discovered);

    /* Phase 3: Expand new branches */
    if (config->expansion_depth > 0 && num_new > 0) {
        printf("  Expanding %zu new branches (%d ply deep)...\n",
               num_new, config->expansion_depth);
        for (size_t i = 0; i < num_new; i++) {
            if (!tree->is_building) break;
            expand_new_branch(new_branches[i], config->expansion_depth,
                              tree, engine_pool, maia, db, config);
        }
        printf("  Tree now has %zu nodes (max depth %d)\n",
               tree->total_nodes, tree->max_depth_reached);
    }

    tree->is_building = false;
    free(our_nodes);
    free(new_branches);
    return total_discovered;
}

