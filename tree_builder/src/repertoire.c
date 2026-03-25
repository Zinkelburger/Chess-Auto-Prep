/**
 * repertoire.c - Automatic Repertoire Generation
 * 
 * Core algorithm:
 * 
 * For each position where it's OUR turn:
 *   1. Evaluate all candidate moves with Stockfish
 *   2. Calculate ease for resulting positions
 *   3. Score each move: eval + ease_for_us - ease_for_opponent + win_rate
 *   4. Select the move with the highest composite score
 * 
 * For each position where it's OPPONENT's turn:
 *   1. Use Lichess database probabilities (what they actually play)
 *   2. Traverse all moves above probability threshold
 *   3. Calculate "trap score" (how likely they are to blunder)
 * 
 * The ease metric (matching Flutter/Python):
 *   ease = 1 - (sum_weighted_regret / 2)^(1/3)
 *   weighted_regret = Σ prob^1.5 × max(0, q_max - q_move)
 *   q = 2/(1+e^(-0.004*cp)) - 1
 */

#include "repertoire.h"
#include "chess_logic.h"
#include "cJSON.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <float.h>

/* Ease formula constants (matching ease_service.dart / ease_calculator.py) */
#define EASE_ALPHA (1.0/3.0)
#define EASE_BETA  1.5

/* Q-value conversion constant */
#define Q_SIGMOID_K 0.004

/* Shared context types for tree traversal callbacks */
typedef struct {
    char **fens;
    int *count;
    int max;
} FenCollector;

typedef struct {
    RepertoireDB *db;
    int *calc;
    int total;
    void (*prog)(const char *, int, int);
} EaseCtx;

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

/**
 * Get centipawn eval from our perspective for a node.
 * Returns eval_cp in "our" centipawns, or 0 if unavailable.
 */
static int get_eval_for_us(const TreeNode *node, RepertoireDB *db,
                           bool play_as_white) {
    int eval_cp = 0;
    int edepth = 0;
    if (!rdb_get_eval(db, node->fen, &eval_cp, &edepth)) {
        if (node->has_engine_eval) eval_cp = node->engine_eval_cp;
        else return 0;
    }
    int eval_white = node->is_white_to_move ? eval_cp : -eval_cp;
    return play_as_white ? eval_white : -eval_white;
}


/* ========== Utility Functions ========== */

/**
 * Convert centipawn evaluation to Q-value [-1, 1]
 * Matches the Flutter _scoreToQ function
 */
static double cp_to_q(int cp) {
    if (abs(cp) > 9000) return cp > 0 ? 1.0 : -1.0;
    double win_prob = 1.0 / (1.0 + exp(-Q_SIGMOID_K * cp));
    return 2.0 * win_prob - 1.0;
}

/**
 * Lichess winning chances formula
 * cp -> win probability [0, 1] from White's perspective
 */
static double cp_to_win_prob(int cp) {
    return 1.0 / (1.0 + exp(-0.00368208 * cp));
}

/**
 * Normalize evaluation to [0, 1] range for scoring
 * 0.5 = equal, 1.0 = winning, 0.0 = losing
 */
static double normalize_eval(int eval_cp, bool play_as_white) {
    double wp = cp_to_win_prob(eval_cp);
    return play_as_white ? wp : (1.0 - wp);
}

/**
 * Normalize win rate from database.
 * 'wins' is always white wins from Lichess data.
 */
static double normalize_winrate(uint64_t wins, uint64_t draws, uint64_t total,
                                 bool play_as_white) {
    if (total == 0) return 0.5;
    uint64_t our_wins = play_as_white ? wins : (total - wins - draws);
    return ((double)our_wins + 0.5 * (double)draws) / (double)total;
}


/* ========== Configuration ========== */

RepertoireConfig repertoire_config_default(void) {
    RepertoireConfig config = {
        .play_as_white = true,
        .max_depth = 30,                /* 15 full moves */
        .min_probability = 0.0001,      /* 0.01% */
        .min_games = 10,
        
        .weight_eval = 0.30,            /* 30% engine evaluation */
        .weight_ease = 0.25,            /* 25% ease (opponent mistakes) */
        .weight_winrate = 0.25,         /* 25% database win rate */
        .weight_sharpness = 0.20,       /* 20% position sharpness */
        
        .eval_depth = 20,               /* Stockfish search depth (matches CLI default) */
        .quick_eval_depth = 15,         /* Quick depth for filtering */
        
        .depth_discount = 0.90,
        .eval_weight = 0.40,
        .eval_guard_threshold = 0.35,

        .min_eval_cp = -50,             /* stop if we're worse than -50cp */
        .max_eval_cp = 300,             /* stop if we're already +300cp (won) */
        .max_eval_loss_cp = 50,         /* candidates within 50cp of best */

        .max_candidates_per_position = 8,
        .candidate_min_prob = 0.01,     /* 1% minimum for candidates */
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


/* ========== Ease Calculation ========== */

/**
 * Calculate ease for a position given its children's evaluations and probabilities
 * 
 * This matches the Flutter/Python implementation exactly:
 * - Get database move probabilities from Lichess explorer (what humans play)
 * - Get engine evaluation for each likely move
 * - Calculate regret = how much worse each human move is vs best
 * - Ease = 1 - (weighted_sum_of_regret / 2)^(1/3)
 */
static double calculate_ease_for_node(TreeNode *node, RepertoireDB *db) {
    if (!node || node->children_count == 0) return -1.0;
    
    /* Find the best evaluation among all children */
    int best_eval = -100000;
    bool has_any_eval = false;
    
    for (size_t i = 0; i < node->children_count; i++) {
        int eval_cp;
        int depth;
        if (rdb_get_eval(db, node->children[i]->fen, &eval_cp, &depth)) {
            /* Negate because child eval is from opponent's perspective */
            int eval_for_us = -eval_cp;
            if (eval_for_us > best_eval) {
                best_eval = eval_for_us;
            }
            has_any_eval = true;
        } else if (node->children[i]->has_engine_eval) {
            int eval_for_us = -node->children[i]->engine_eval_cp;
            if (eval_for_us > best_eval) {
                best_eval = eval_for_us;
            }
            has_any_eval = true;
        }
    }
    
    if (!has_any_eval) return -1.0;
    
    double q_max = cp_to_q(best_eval);
    
    /* Calculate weighted regret */
    double sum_weighted_regret = 0.0;
    
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        double prob = child->move_probability;
        
        if (prob < 0.01) continue; /* Skip very rare moves */
        
        int eval_cp;
        int depth;
        int child_eval;
        
        if (rdb_get_eval(db, child->fen, &eval_cp, &depth)) {
            child_eval = -eval_cp; /* Negate for our perspective */
        } else if (child->has_engine_eval) {
            child_eval = -child->engine_eval_cp;
        } else {
            continue; /* No eval available */
        }
        
        double q_val = cp_to_q(child_eval);
        double regret = fmax(0.0, q_max - q_val);
        double term = pow(prob, EASE_BETA) * regret;
        sum_weighted_regret += term;
    }
    
    /* Calculate ease */
    double raw_ease = 1.0 - pow(sum_weighted_regret / 2.0, EASE_ALPHA);
    
    /* Clamp to [0, 1] */
    if (raw_ease < 0.0) raw_ease = 0.0;
    if (raw_ease > 1.0) raw_ease = 1.0;
    
    return raw_ease;
}


/* ========== Position Scoring ========== */

double score_position(int eval_cp, double ease, double opponent_ease,
                       double win_rate, double probability,
                       uint64_t total_games, const RepertoireConfig *config,
                       bool is_our_move) {
    if (!config) return 0.0;
    
    /* Normalize evaluation to [0, 1] */
    double eval_score = normalize_eval(eval_cp, config->play_as_white);
    
    /* Ease component:
     * When it's OUR move: we want high ease (hard for us to blunder)
     * When it's OPPONENT's move: we want low ease (easy for them to err)
     */
    double ease_component;
    if (is_our_move) {
        ease_component = ease >= 0 ? ease : 0.5;  /* High ease = good for us */
    } else {
        ease_component = opponent_ease >= 0 ? (1.0 - opponent_ease) : 0.5; /* Low opp ease = good for us */
    }
    
    /* Sharpness: inverse of opponent's ease (they'll make mistakes) */
    double sharpness = opponent_ease >= 0 ? (1.0 - opponent_ease) : 0.5;
    
    /* Win rate component */
    double wr_component = win_rate >= 0 ? win_rate : 0.5;
    
    /* Statistical confidence bonus (more games = more reliable) */
    double confidence = 1.0;
    if (total_games < 100) {
        confidence = 0.5 + 0.5 * ((double)total_games / 100.0);
    }
    
    /* Composite score */
    double score = config->weight_eval * eval_score
                 + config->weight_ease * ease_component
                 + config->weight_winrate * wr_component
                 + config->weight_sharpness * sharpness;
    
    /* Apply confidence modifier */
    score *= confidence;
    
    /* Apply probability weighting (likely positions matter more) */
    double prob_factor = 1.0;
    if (probability > 0) {
        prob_factor = 0.5 + 0.5 * sqrt(probability); /* Sqrt dampens extremes */
    }
    score *= prob_factor;
    
    return score;
}


/* ========== Trap Score ========== */

double calculate_trap_score(const TreeNode *node, RepertoireDB *db) {
    if (!node || node->children_count < 2 || !db) return -1.0;
    
    /* Find the most popular move and the best move */
    TreeNode *most_popular = NULL;
    TreeNode *best_move_node = NULL;
    double highest_prob = 0;
    int best_eval = -100000;
    
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        
        /* Track most popular */
        if (child->move_probability > highest_prob) {
            highest_prob = child->move_probability;
            most_popular = child;
        }
        
        /* Track best eval */
        int eval_cp;
        int depth;
        if (rdb_get_eval(db, child->fen, &eval_cp, &depth)) {
            int eval_for_mover = -eval_cp; /* From side-to-move perspective */
            if (eval_for_mover > best_eval) {
                best_eval = eval_for_mover;
                best_move_node = child;
            }
        }
    }
    
    if (!most_popular || !best_move_node) return -1.0;
    
    /* If the most popular move IS the best move, no trap */
    if (most_popular == best_move_node) return 0.0;
    
    /* Get eval of the most popular move */
    int popular_eval;
    int depth;
    if (!rdb_get_eval(db, most_popular->fen, &popular_eval, &depth)) {
        return -1.0;
    }
    popular_eval = -popular_eval; /* From side-to-move perspective */
    
    /* Trap score = how much worse the popular move is */
    double eval_diff = (double)(best_eval - popular_eval);
    if (eval_diff < 0) eval_diff = 0;
    
    /* Normalize: 200cp difference = full trap score */
    double trap = eval_diff / 200.0;
    if (trap > 1.0) trap = 1.0;
    
    /* Weight by how popular the bad move is */
    trap *= highest_prob;
    
    return trap;
}


/* ========== Repertoire Generation ========== */

/**
 * Internal: recursively build repertoire by selecting our moves
 * and traversing all likely opponent moves
 */
static void build_repertoire_recursive(TreeNode *node, Tree *tree,
                                         RepertoireDB *db, EnginePool *engine_pool,
                                         const RepertoireConfig *config,
                                         RepertoireMove *out_moves, int *num_moves,
                                         int max_moves,
                                         void (*progress)(const char *, int, int)) {
    if (!node || *num_moves >= max_moves) return;
    if (node->depth >= config->max_depth) return;
    if (node->cumulative_probability < config->min_probability) return;
    if (node->children_count == 0) return;
    
    /* Eval-window pruning: stop exploring if position is too winning or too losing */
    if (node->depth > 0) {
        int eval_us = get_eval_for_us(node, db, config->play_as_white);
        if (eval_us <= config->min_eval_cp) {
            if (config->verbose_search) {
                printf("  [prune] eval %+dcp <= %+dcp min — stopping DFS at depth %d\n",
                       eval_us, config->min_eval_cp, node->depth);
            }
            return;
        }
        if (eval_us >= config->max_eval_cp) {
            if (config->verbose_search) {
                printf("  [prune] eval %+dcp >= %+dcp max — stopping DFS at depth %d\n",
                       eval_us, config->max_eval_cp, node->depth);
            }
            return;
        }
    }

    bool is_our_move;
    if (config->play_as_white) {
        is_our_move = node->is_white_to_move;
    } else {
        is_our_move = !node->is_white_to_move;
    }
    
    if (is_our_move) {
        /* === OUR MOVE: Select the best move === */
        double best_score = -DBL_MAX;
        TreeNode *best_child = NULL;
        bool using_eca = false;
        
        for (size_t i = 0; i < node->children_count; i++) {
            if (node->children[i]->has_eca) { using_eca = true; break; }
        }

        /* Pre-compute eval and ECA for all children so we can normalize */
        double max_eca = 0.0;
        double child_eval_for_us[256];
        int child_our_cp[256];
        bool child_passes_eval_loss[256];
        int best_child_cp = -100000;

        for (size_t i = 0; i < node->children_count && i < 256; i++) {
            TreeNode *child = node->children[i];
            int eval_cp = 0;
            int edepth = 0;
            if (!rdb_get_eval(db, child->fen, &eval_cp, &edepth)) {
                if (child->has_engine_eval) eval_cp = child->engine_eval_cp;
            }
            int eval_white = child->is_white_to_move ? eval_cp : -eval_cp;
            child_our_cp[i] = config->play_as_white ? eval_white : -eval_white;
            child_eval_for_us[i] = config->play_as_white
                ? cp_to_win_prob(eval_white)
                : 1.0 - cp_to_win_prob(eval_white);

            if (child_our_cp[i] > best_child_cp)
                best_child_cp = child_our_cp[i];

            if (using_eca && child->has_eca && child->accumulated_eca > max_eca)
                max_eca = child->accumulated_eca;
        }

        /* Mark children that pass the max-eval-loss filter */
        int passing_count = 0;
        for (size_t i = 0; i < node->children_count && i < 256; i++) {
            child_passes_eval_loss[i] =
                (child_our_cp[i] >= best_child_cp - config->max_eval_loss_cp) &&
                (child_our_cp[i] >= config->min_eval_cp);
            if (child_passes_eval_loss[i]) passing_count++;
        }
        if (passing_count == 0) {
            for (size_t i = 0; i < node->children_count && i < 256; i++)
                child_passes_eval_loss[i] = true;
        }

        if (config->verbose_search) {
            int ply = node->depth;
            int move_num = (ply / 2) + 1;
            const char *side = node->is_white_to_move ? "White" : "Black";
            printf("\n  ──── %s to move (move %d, ply %d) ────\n",
                   side, move_num, ply);
            printf("  FEN: %s\n", node->fen);
            printf("  Prob: %.2f%%  |  %zu candidates  |  eval-weight=%.2f (eval=%.0f%%, trick=%.0f%%)\n",
                   node->cumulative_probability * 100.0,
                   node->children_count,
                   config->eval_weight,
                   config->eval_weight * 100.0,
                   (1.0 - config->eval_weight) * 100.0);
            printf("  %-8s %7s %7s %8s %8s  %s\n",
                   "Move", "Eval", "WinPr", "ECA", "Score", "");
            printf("  %-8s %7s %7s %8s %8s  %s\n",
                   "────────", "───────", "───────", "────────", "────────", "──────");
        }

        for (size_t i = 0; i < node->children_count && i < 256; i++) {
            TreeNode *child = node->children[i];
            double score;

            /* Skip candidates too far from the best eval */
            if (!child_passes_eval_loss[i]) {
                if (config->verbose_search) {
                    printf("  %-8s %+6dcp %6s  %8s %8s  SKIP (>%dcp from best %+dcp)\n",
                           child->move_san, child_our_cp[i], "",
                           "", "",
                           config->max_eval_loss_cp, best_child_cp);
                }
                continue;
            }

            if (using_eca && child->has_eca) {
                double eval_us = child_eval_for_us[i];

                if (eval_us < config->eval_guard_threshold) {
                    if (config->verbose_search) {
                        printf("  %-8s %+6dcp %6.1f%% %7.1fcp %8s  SKIP (eval guard <%.0f%%)\n",
                               child->move_san, child_our_cp[i],
                               eval_us * 100.0,
                               child->accumulated_eca,
                               "—",
                               config->eval_guard_threshold * 100.0);
                    }
                    continue;
                }

                /* Normalize ECA to [0, 1] relative to best sibling */
                double norm_eca = max_eca > 0.0
                    ? child->accumulated_eca / max_eca
                    : 0.0;

                /* Blend: α × eval + (1-α) × ECA */
                double w = config->eval_weight;
                score = w * eval_us + (1.0 - w) * norm_eca;

                if (config->verbose_search) {
                    printf("  %-8s %+6dcp %6.1f%% %7.1fcp %7.3f",
                           child->move_san, child_our_cp[i],
                           eval_us * 100.0,
                           child->accumulated_eca,
                           score);
                }
            } else {
                int eval_cp = 0;
                int depth = 0;
                if (!rdb_get_eval(db, child->fen, &eval_cp, &depth)) {
                    if (child->has_engine_eval) eval_cp = child->engine_eval_cp;
                }
                double ease = -1.0;
                rdb_get_ease(db, child->fen, &ease);
                if (ease < 0 && child->has_ease) ease = child->ease;
                double opp_ease = -1.0;
                if (child->children_count > 0)
                    opp_ease = calculate_ease_for_node(child, db);
                double win_rate = 0.5;
                if (child->total_games > 0)
                    win_rate = normalize_winrate(child->white_wins, child->draws,
                                                 child->total_games,
                                                 config->play_as_white);
                score = score_position(eval_cp, ease, opp_ease, win_rate,
                                       child->cumulative_probability,
                                       child->total_games, config, true);

                if (config->verbose_search) {
                    printf("  %-8s  score=%.4f", child->move_san, score);
                }
            }

            if (score > best_score) {
                best_score = score;
                best_child = child;
                if (config->verbose_search) printf("  ◄ best");
            }
            if (config->verbose_search) printf("\n");
        }
        
        if (config->verbose_search && best_child) {
            printf("  ═══> Selected: %s (score=%.3f)\n", best_child->move_san, best_score);
        }

        if (best_child && *num_moves < max_moves) {
            /* Record this repertoire move */
            RepertoireMove *rm = &out_moves[*num_moves];
            strncpy(rm->fen, node->fen, sizeof(rm->fen) - 1);
            strncpy(rm->move_san, best_child->move_san, sizeof(rm->move_san) - 1);
            strncpy(rm->move_uci, best_child->move_uci, sizeof(rm->move_uci) - 1);
            rm->composite_score = best_score;
            rm->depth = node->depth;
            rm->probability = node->cumulative_probability;
            
            int eval_cp = 0;
            int depth = 0;
            rdb_get_eval(db, best_child->fen, &eval_cp, &depth);
            rm->eval_cp = eval_cp;
            rm->total_games = best_child->total_games;
            
            (*num_moves)++;
            
            /* Save to database */
            rdb_save_repertoire_move(db, node->fen, best_child->move_san,
                                      best_child->move_uci, best_score);
            
            /* Continue down this line only */
            build_repertoire_recursive(best_child, tree, db, engine_pool,
                                        config, out_moves, num_moves, max_moves,
                                        progress);
        }
        
    } else {
        /* === OPPONENT'S MOVE: Traverse likely responses with mass cutoff === */
        int opp_count = 0;
        double opp_mass = 0.0;

        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            
            /* Skip very improbable moves */
            if (child->move_probability < config->candidate_min_prob) continue;
            if (child->cumulative_probability < config->min_probability) continue;
            if (child->total_games < (uint64_t)config->min_games) continue;
            
            /* Max candidates cap for opponent too */
            if (config->max_candidates_per_position > 0 &&
                opp_count >= config->max_candidates_per_position)
                break;

            /* Recurse into opponent's response */
            build_repertoire_recursive(child, tree, db, engine_pool,
                                        config, out_moves, num_moves, max_moves,
                                        progress);
            opp_count++;
            opp_mass += child->move_probability;
        }
    }
}


/**
 * Collect all unique FENs in the tree for batch evaluation
 */
static void collect_fens_callback(TreeNode *node, void *user_data) {
    FenCollector *fc = (FenCollector *)user_data;
    
    if (*fc->count < fc->max && node->fen[0]) {
        fc->fens[*fc->count] = strdup(node->fen);
        (*fc->count)++;
    }
}


static void eval_progress_wrapper(int completed, int total, void *ud) {
    void (*prog)(const char *, int, int) = (void (*)(const char *, int, int))ud;
    if (prog) prog("Evaluating positions", completed, total);
}

/**
 * Batch evaluate all positions in the tree that need evaluation
 */
static int batch_evaluate_tree(Tree *tree, RepertoireDB *db, EnginePool *engine_pool,
                                int depth, void (*progress)(const char *, int, int)) {
    if (!tree || !tree->root) return 0;
    
    /* First pass: count positions needing evaluation */
    int total_nodes = (int)tree->total_nodes;
    char **fens = (char **)calloc(total_nodes, sizeof(char *));
    int fen_count = 0;
    
    FenCollector fc = { fens, &fen_count, total_nodes };
    
    tree_traverse_bfs(tree, collect_fens_callback, &fc);
    
    /* Filter to only positions not yet in DB at sufficient depth */
    EvalJob *jobs = (EvalJob *)calloc(fen_count, sizeof(EvalJob));
    int job_count = 0;
    
    for (int i = 0; i < fen_count; i++) {
        if (!fens[i]) continue;
        
        int existing_eval, existing_depth;
        if (rdb_get_eval(db, fens[i], &existing_eval, &existing_depth)) {
            if (existing_depth >= depth) {
                free(fens[i]);
                fens[i] = NULL;
                continue;
            }
        }
        
        strncpy(jobs[job_count].fen, fens[i], MAX_EVAL_FEN_LENGTH - 1);
        job_count++;
        free(fens[i]);
        fens[i] = NULL;
    }
    
    /* Free remaining fens */
    for (int i = 0; i < fen_count; i++) {
        free(fens[i]); /* free(NULL) is safe */
    }
    free(fens);
    
    if (job_count == 0) {
        free(jobs);
        return 0;
    }
    
    if (progress) {
        progress("Evaluating positions", 0, job_count);
    }
    
    /* Batch evaluate */
    engine_pool_evaluate_batch(engine_pool, jobs, job_count, 
                                eval_progress_wrapper, (void *)progress);
    
    /* Store results in database */
    rdb_begin_transaction(db);
    int stored = 0;
    for (int i = 0; i < job_count; i++) {
        if (jobs[i].success) {
            rdb_put_eval(db, jobs[i].fen, jobs[i].eval_cp, jobs[i].depth_reached);
            stored++;
        }
    }
    rdb_commit_transaction(db);
    
    free(jobs);
    
    return stored;
}


/**
 * Calculate ease scores for all positions in tree
 */
static void ease_callback(TreeNode *node, void *user_data) {
    EaseCtx *ctx = (EaseCtx *)user_data;

    double existing;
    if (rdb_get_ease(ctx->db, node->fen, &existing)) {
        (*ctx->calc)++;
        return;
    }

    double ease = calculate_ease_for_node(node, ctx->db);
    if (ease >= 0) {
        rdb_put_ease(ctx->db, node->fen, ease);
        node_set_ease(node, ease);
    }

    (*ctx->calc)++;

    if (ctx->prog && (*ctx->calc % 100 == 0)) {
        ctx->prog("Calculating ease", *ctx->calc, ctx->total);
    }
}

static int calculate_all_ease(Tree *tree, RepertoireDB *db,
                               void (*progress)(const char *, int, int)) {
    if (!tree || !tree->root || !db) return 0;

    int calculated = 0;
    int total = (int)tree->total_nodes;
    EaseCtx ctx = { db, &calculated, total, progress };

    rdb_begin_transaction(db);
    tree_traverse_bfs(tree, ease_callback, &ctx);
    rdb_commit_transaction(db);

    return calculated;
}


/**
 * Look up which move was selected as the repertoire move at a given FEN.
 * Returns the matching child node, or NULL if no repertoire move exists.
 */
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

/**
 * Extract complete lines from the repertoire moves.
 *
 * At our-move nodes: follow ONLY the selected repertoire move.
 * At opponent-move nodes: follow all children above probability threshold.
 * This produces lines that represent actual repertoire coverage.
 */
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

        bool is_our_move;
        if (config->play_as_white) {
            is_our_move = node->is_white_to_move;
        } else {
            is_our_move = !node->is_white_to_move;
        }

        bool pushed_any = false;

        if (is_our_move) {
            /* Only follow the selected repertoire move */
            TreeNode *selected = find_repertoire_child(node, moves, num_moves);
            if (selected && stack_top < 10000) {
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
            /* Opponent node: follow all likely responses */
            for (size_t i = 0; i < node->children_count; i++) {
                TreeNode *child = node->children[i];
                if (child->cumulative_probability < config->min_probability) continue;
                if (child->move_probability < config->candidate_min_prob) continue;

                if (stack_top < 10000) {
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

        if (!pushed_any && current.depth > 0) {
            goto record_line;
        }
        continue;

    record_line:
        {
            int depth = current.depth;

            /* Lines should end with our move, not the opponent's.
               Trim trailing opponent move if present. */
            if (depth > 0 && current.node) {
                bool last_is_our_move;
                if (config->play_as_white)
                    last_is_our_move = !current.node->is_white_to_move;
                else
                    last_is_our_move = current.node->is_white_to_move;
                if (!last_is_our_move)
                    depth--;
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
    if (rdb_get_eval(d, node->fen, &eval_cp, &depth)) {
        node_set_eval(node, eval_cp);
    }
}

RepertoireResult* generate_repertoire(Tree *tree, RepertoireDB *db,
                                       EnginePool *engine_pool,
                                       const RepertoireConfig *config_in,
                                       void (*progress)(const char *stage, 
                                                         int current, int total)) {
    if (!tree || !tree->root || !db || !config_in) return NULL;
    
    /* Mutable copy so we can resolve --relative thresholds after eval */
    RepertoireConfig cfg_local = *config_in;
    const RepertoireConfig *config = &cfg_local;

    RepertoireResult *result = (RepertoireResult *)calloc(1, sizeof(RepertoireResult));
    if (!result) return NULL;
    
    /* Allocate arrays */
    int max_moves = (int)tree->total_nodes;
    result->moves = (RepertoireMove *)calloc(max_moves, sizeof(RepertoireMove));
    result->lines = (RepertoireLine *)calloc(10000, sizeof(RepertoireLine));
    
    if (!result->moves || !result->lines) {
        free(result->moves);
        free(result->lines);
        free(result);
        return NULL;
    }
    
    /* === Stage 1: Batch evaluate all positions with Stockfish === */
    if (progress) progress("Stage 1: Engine evaluation", 0, (int)tree->total_nodes);
    
    if (engine_pool) {
        result->positions_evaluated = batch_evaluate_tree(tree, db, engine_pool,
                                                           config->eval_depth, progress);
        printf("  Evaluated %d new positions\n", result->positions_evaluated);
    }
    
    tree_traverse_bfs(tree, load_evals_callback, db);

    /* Resolve --relative: offset min/max_eval_cp by the root position's eval */
    if (cfg_local.relative_eval) {
        int root_eval = get_eval_for_us(tree->root, db, cfg_local.play_as_white);
        printf("  Root eval (our perspective): %+dcp\n", root_eval);
        printf("  Relative thresholds: min=%+d, max=%+d → ",
               cfg_local.min_eval_cp, cfg_local.max_eval_cp);
        cfg_local.min_eval_cp += root_eval;
        cfg_local.max_eval_cp += root_eval;
        printf("absolute min=%+d, max=%+d\n",
               cfg_local.min_eval_cp, cfg_local.max_eval_cp);
    }
    
    /* === Stage 2: Calculate ease scores === */
    if (progress) progress("Stage 2: Ease calculation", 0, (int)tree->total_nodes);
    
    int ease_count = calculate_all_ease(tree, db, progress);
    printf("  Calculated %d ease scores\n", ease_count);
    
    /* === Stage 3: Calculate ECA (Expected Centipawn Advantage) === */
    if (progress) progress("Stage 3: ECA calculation", 0, (int)tree->total_nodes);
    
    size_t eca_count = tree_calculate_eca(tree, config->play_as_white,
                                           config->depth_discount);
    printf("  Computed ECA for %zu nodes (depth-decay=%.2f)\n", eca_count, config->depth_discount);
    if (tree->root && tree->root->has_eca) {
        printf("  Root accumulated ECA: %.1f cp (Q: %.4f)\n",
               tree->root->accumulated_eca, tree->root->accumulated_q_eca);
    }
    
    /* === Stage 4: Select repertoire moves === */
    if (progress) progress("Stage 4: Move selection", 0, (int)tree->total_nodes);
    
    result->num_moves = 0;
    build_repertoire_recursive(tree->root, tree, db, engine_pool, config,
                                result->moves, &result->num_moves, max_moves,
                                progress);
    
    printf("  Selected %d repertoire moves\n", result->num_moves);
    
    /* === Stage 5: Extract complete lines === */
    if (progress) progress("Stage 5: Line extraction", 0, 0);
    
    result->num_lines = extract_lines(tree, result->moves, result->num_moves,
                                       config, result->lines, 10000);
    
    printf("  Extracted %d complete lines\n", result->num_lines);
    
    /* === Calculate summary statistics === */
    result->total_positions_analyzed = (int)tree->total_nodes;
    
    double total_eval = 0;
    double total_ease = 0;
    int eval_count = 0;
    int ease_count2 = 0;
    
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

static int trap_score_cmp_desc(const void *a, const void *b) {
    double sa = ((const TrapCandidate *)a)->trap_score;
    double sb = ((const TrapCandidate *)b)->trap_score;
    return (sa < sb) - (sa > sb);
}

static void find_traps_callback(TreeNode *node, void *user_data) {
    TrapCtx *ctx = (TrapCtx *)user_data;

    bool is_opponent_move = ctx->as_white ? !node->is_white_to_move : node->is_white_to_move;
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
    TrapCandidate *candidates = (TrapCandidate *)calloc(max_candidates, sizeof(TrapCandidate));
    if (!candidates) return 0;

    int num_candidates = 0;
    TrapCtx ctx = { candidates, &num_candidates, max_candidates, db, play_as_white };
    tree_traverse_dfs(tree, find_traps_callback, &ctx);
    
    qsort(candidates, num_candidates, sizeof(TrapCandidate), trap_score_cmp_desc);
    
    /* Extract lines for top trap positions */
    int num_lines = 0;
    for (int i = 0; i < num_candidates && num_lines < max_lines; i++) {
        TreeNode *node = candidates[i].node;
        RepertoireLine *line = &out_lines[num_lines];
        
        /* Get move path to this node */
        char moves[128][16];
        size_t path_len = tree_get_line_to_node(node, moves, 128);
        
        for (size_t j = 0; j < path_len && j < 128; j++) {
            strncpy(line->moves_san[j], moves[j], 15);
        }
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
    
    /* Determine side to move from the starting FEN */
    bool root_white_to_move = true;
    if (config && config->start_fen[0]) {
        const char *sp = strchr(config->start_fen, ' ');
        if (sp && *(sp + 1) == 'b') root_white_to_move = false;
    }

    bool has_name = config && config->name[0];

    /* Write each line as a separate game */
    for (int i = 0; i < result->num_lines; i++) {
        const RepertoireLine *line = &result->lines[i];

        if (has_name)
            fprintf(f, "[Event \"%s Line #%d\"]\n", config->name, i + 1);
        else
            fprintf(f, "[Event \"Repertoire Line #%d\"]\n", i + 1);
        fprintf(f, "[Site \"tree_builder\"]\n");
        fprintf(f, "[Date \"????.??.??\"]\n");
        fprintf(f, "[Round \"-\"]\n");
        fprintf(f, "[White \"%s\"]\n", config->play_as_white ? "Repertoire" : "Opponent");
        fprintf(f, "[Black \"%s\"]\n", config->play_as_white ? "Opponent" : "Repertoire");
        if (config && config->start_fen[0] &&
            strcmp(config->start_fen, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") != 0) {
            fprintf(f, "[FEN \"%s\"]\n", config->start_fen);
            fprintf(f, "[SetUp \"1\"]\n");
        }
        fprintf(f, "[Result \"*\"]\n\n");
        
        for (int j = 0; j < line->num_moves; j++) {
            int ply = j + (root_white_to_move ? 0 : 1);
            if (ply % 2 == 0) {
                fprintf(f, "%d. ", (ply / 2) + 1);
            } else if (j == 0 && !root_white_to_move) {
                fprintf(f, "%d... ", (ply / 2) + 1);
            }
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
    cJSON_AddNumberToObject(root, "positions_analyzed", result->total_positions_analyzed);
    cJSON_AddNumberToObject(root, "avg_eval", result->avg_eval);
    cJSON_AddNumberToObject(root, "avg_ease", result->avg_ease);
    
    /* Moves array */
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
    
    /* Lines array */
    cJSON *lines = cJSON_CreateArray();
    for (int i = 0; i < result->num_lines; i++) {
        const RepertoireLine *rl = &result->lines[i];
        cJSON *line = cJSON_CreateObject();
        
        cJSON *line_moves = cJSON_CreateArray();
        for (int j = 0; j < rl->num_moves; j++) {
            cJSON_AddItemToArray(line_moves, cJSON_CreateString(rl->moves_san[j]));
        }
        cJSON_AddItemToObject(line, "moves", line_moves);
        cJSON_AddNumberToObject(line, "score", rl->line_score);
        cJSON_AddNumberToObject(line, "probability", rl->probability);
        cJSON_AddNumberToObject(line, "mistake_potential", rl->mistake_potential);
        
        if (rl->opening_name[0]) {
            cJSON_AddStringToObject(line, "opening", rl->opening_name);
        }
        
        cJSON_AddItemToArray(lines, line);
    }
    cJSON_AddItemToObject(root, "lines", lines);
    
    /* Write to file */
    char *json_str = cJSON_Print(root);
    cJSON_Delete(root);
    
    if (!json_str) return false;
    
    FILE *f = fopen(filename, "w");
    if (!f) {
        free(json_str);
        return false;
    }
    
    fputs(json_str, f);
    fclose(f);
    free(json_str);
    
    return true;
}


void repertoire_print_summary(const RepertoireResult *result) {
    if (!result) return;
    
    printf("\n");
    printf("╔══════════════════════════════════════════╗\n");
    printf("║      REPERTOIRE GENERATION SUMMARY       ║\n");
    printf("╠══════════════════════════════════════════╣\n");
    printf("║  Positions analyzed: %-10d           ║\n", result->total_positions_analyzed);
    printf("║  Positions evaluated: %-10d          ║\n", result->positions_evaluated);
    printf("║  Repertoire moves: %-10d             ║\n", result->num_moves);
    printf("║  Complete lines: %-10d               ║\n", result->num_lines);
    printf("║  Average eval: %+.0f cp                    ║\n", result->avg_eval);
    printf("║  Average ease: %.3f                     ║\n", result->avg_ease);
    printf("╚══════════════════════════════════════════╝\n");
    
    /* Print top lines */
    if (result->num_lines > 0) {
        printf("\nTop lines:\n");
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
            if (line->mistake_potential > 0) {
                printf(", trap=%.1f%%", line->mistake_potential * 100);
            }
            printf(")\n");
        }
    }
    
    printf("\n");
}
