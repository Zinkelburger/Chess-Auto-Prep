/**
 * tree.h - Opening Tree Builder
 *
 * Builds and manages the complete opening tree structure in a single
 * interleaved DFS so branches can be pruned immediately by eval window.
 *
 * At OUR-move nodes:     Stockfish MultiPV → eval-loss filter → recurse
 * At OPPONENT nodes:     single source — pure Maia (default) or pure
 *                        Lichess (`maia_only = false`) → recurse
 */

#ifndef TREE_H
#define TREE_H

#include "node.h"
#include <stdbool.h>
#include <stdio.h>
#include <time.h>

/* Forward declarations */
struct LichessExplorer;
struct EnginePool;
struct MaiaContext;
struct RepertoireDB;
struct RepertoireConfig;

/**
 * BuildStats - Accumulated timing and counters from a tree build.
 * Populated by tree_build(); caller owns the struct.
 */
typedef struct BuildStats {
    /* Lichess API */
    int    lichess_queries;
    int    lichess_cache_hits;
    double lichess_total_ms;

    /* Maia */
    int    maia_evals;
    double maia_total_ms;

    /* Stockfish (broken down by call type) */
    int    sf_multipv_calls;
    double sf_multipv_ms;
    int    sf_single_calls;
    double sf_single_ms;
    int    sf_batch_calls;
    double sf_batch_ms;

    /* DB cache */
    int    db_eval_hits;
    int    db_eval_misses;
    int    db_explorer_hits;
    int    db_explorer_misses;
    int    db_multipv_hits;
    int    db_multipv_misses;
} BuildStats;

/**
 * TreeConfig - Configuration for tree building
 *
 * The build is a single DFS pass that queries Lichess and Stockfish
 * together, creating nodes with evaluations inline and pruning
 * immediately when positions leave the eval window.
 */
typedef struct TreeConfig {
    /* Side to play */
    bool play_as_white;

    /* Traversal limits */
    double min_probability;         /* Stop exploring below this cumul. probability */
    int max_depth;                  /* Maximum depth in ply */
    int max_nodes;                  /* Maximum total nodes (0 = unlimited) */

    /* Engine (required for build) */
    struct EnginePool *engine_pool; /* Stockfish pool — must be non-NULL */
    struct RepertoireDB *db;        /* SQLite cache for evals (optional but recommended) */
    int eval_depth;                 /* Stockfish search depth */

    /* Our-move candidate selection (engine-driven)
     *
     * MultiPV is constant at every depth — Stockfish returns the top
     * `our_multipv` lines, and all of them within `max_eval_loss_cp`
     * of the best are kept.  Natural pruning comes from `min_probability`,
     * `max_depth`, and the eval window.  No depth-based tapering. */
    int our_multipv;                /* MultiPV count at every depth */
    int max_eval_loss_cp;           /* Candidates must be within this of best */

    /* Opponent-move selection
     *
     * Mass target is constant at every depth.  We walk moves in probability
     * order (Maia or Lichess) until we hit either the mass target or the
     * children cap.  The expectimax pass accounts for uncovered mass via a
     * tail term, so `opp_mass_target` trades runtime for tighter V, not
     * correctness. */
    int opp_max_children;           /* Hard cap on opponent responses (0 = unlimited) */
    double opp_mass_target;         /* Covered-mass target at every depth */

    /* Eval window pruning — stop exploring outside this range */
    int min_eval_cp;                /* Prune if our eval drops below this */
    int max_eval_cp;                /* Prune if our eval exceeds this (already won) */
    bool relative_eval;             /* Make eval window relative to root eval */

    /* Lichess API settings */
    const char *rating_range;       /* e.g. "2000,2200,2500" */
    const char *speeds;             /* e.g. "blitz,rapid,classical" */
    int min_games;                  /* Minimum games to consider a move */
    bool use_masters;               /* Use masters database instead of Lichess */

    /* Maia neural network
     *
     * `maia_only` selects the opponent move source: true = Maia, false =
     * Lichess explorer.  `populate_maia_frequency` controls whether Maia
     * is *also* run at our-move nodes to fill in `child->maia_frequency`
     * for novelty scoring during selection.  If you know you won't use
     * novelty (`novelty_weight == 0`), setting this to false saves one
     * Maia inference per our-move node. */
    struct MaiaContext *maia;       /* NULL = disabled */
    int    maia_elo;                /* Elo for Maia predictions (600-2400) */
    double maia_min_prob;           /* Skip Maia moves below this probability */
    bool   maia_only;               /* Pure Maia for opponent moves (else pure Lichess) */
    bool   populate_maia_frequency; /* Run Maia at our-move nodes for novelty */

    /* Progress callback */
    void (*progress_callback)(int nodes_built, int current_depth, const char *current_fen);

    /* Build instrumentation (optional, caller-owned) */
    BuildStats *stats;

    /* Structured event log (optional).
     * When non-NULL, tree_build() writes one TSV line per event:
     *   T_ms \t event \t depth \t node_type \t detail
     * T_ms is monotonic milliseconds since build start.
     * Set event_log_epoch via clock_gettime(CLOCK_MONOTONIC, ...) before
     * calling tree_build() — or leave zeroed and tree_build() will set it. */
    FILE *event_log;
    struct timespec event_log_epoch;

} TreeConfig;

/**
 * Tree - The complete opening tree
 */
typedef struct Tree {
    TreeNode *root;
    TreeConfig config;

    size_t total_nodes;
    int max_depth_reached;

    bool is_building;
    bool build_complete;
    uint64_t next_node_id;

    void *expanded_fens;    /* FenMap* — FEN → canonical TreeNode* for transposition detection */

    /* Build performance (set by caller after tree_build returns) */
    double build_time_seconds;
    double nodes_per_minute;
    double branching_factor;   /* total_nodes^(1/max_depth_reached) */
    int    build_threads;
    int    build_eval_depth;

} Tree;


/**
 * Create default tree configuration.
 * Caller must still set engine_pool before calling tree_build().
 */
TreeConfig tree_config_default(void);

/**
 * Apply color-specific eval-window defaults.
 * Must be called after setting config->play_as_white.
 *   White: min_eval=0, max_eval=200
 *   Black: min_eval=-200, max_eval=100
 */
void tree_config_set_color_defaults(TreeConfig *config);

Tree* tree_create(void);
void tree_destroy(Tree *tree);

/**
 * Build the opening tree from a starting FEN.
 *
 * Interleaves Lichess explorer queries with Stockfish evaluation:
 *   - Our moves:      Stockfish MultiPV → eval filter → recurse
 *   - Opponent moves:  Lichess DB + Maia → batch eval → recurse
 *
 * Requires config->engine_pool to be non-NULL.
 *
 * @return true on success, false on failure
 */
bool tree_build(Tree *tree, const char *start_fen,
                const TreeConfig *config, struct LichessExplorer *explorer);

void tree_stop_build(Tree *tree);

/**
 * Post-build cleanup: remove nodes marked PRUNE_EVAL_TOO_LOW.
 * These positions are too bad for us — no point keeping them in
 * the tree.  Call after tree_build() completes.
 *
 * @return Number of nodes removed.
 */
size_t tree_prune_eval_too_low(Tree *tree);

TreeNode* tree_find_by_fen(const Tree *tree, const char *fen);
TreeNode* tree_find_by_moves(const Tree *tree, const char **moves, size_t num_moves);
size_t tree_get_leaves(const Tree *tree, TreeNode **out_leaves, size_t max_leaves);
size_t tree_get_nodes_at_depth(const Tree *tree, int depth,
                                TreeNode **out_nodes, size_t max_nodes);

/**
 * Compute expectimax values for the entire tree.
 *
 * Two-pass post-order DFS assigning each node a practical win
 * probability V in [0, 1]:
 *   - Leaves:     V = leaf_conf · wp(eval_for_us) + (1 − leaf_conf) · 0.5
 *                 (blend of the engine's win-probability estimate with a
 *                 neutral 0.5 prior; leaf_conf = 1.0 ⇒ V = wp(eval))
 *   - Opp nodes:  V = Σ pᵢ · V(childᵢ) + (1 − Σ pᵢ) · leaf_value(this)
 *                 (raw — not renormalized — covered probabilities, with
 *                 a tail term for uncovered mass)
 *   - Our nodes:  V = max over candidates passing the eval-loss filter
 *                 (novelty-weighted when novelty_weight > 0); fallback to
 *                 all children if none pass.
 *
 * Two passes are used so transposition leaves can reliably borrow V from
 * their canonical equivalent even when DFS order would otherwise visit
 * the leaf first (e.g. after a load-from-JSON that reordered subtrees).
 *
 * Also computes local_cpl at opponent nodes (display only).
 */
size_t tree_calculate_expectimax(Tree *tree, const struct RepertoireConfig *config);

typedef struct {
    TreeNode *child;
    double expectimax_value;
} ScoredChild;

/**
 * At an our-move node, find the child with the highest expectimax value
 * among those passing the eval-loss filter.  Falls back to all children
 * if none pass.  Returns the number of children that passed the filter.
 */
int score_our_move_children(TreeNode *node,
                            const struct RepertoireConfig *config,
                            ScoredChild *best_out);

double win_probability(int cp);

void tree_recalculate_probabilities(Tree *tree);

size_t tree_get_line_to_node(const TreeNode *node, char (*out_moves)[MAX_MOVE_LENGTH],
                              size_t max_moves);

void tree_print_stats(const Tree *tree);
void tree_print(const Tree *tree, int max_depth);

void tree_traverse_dfs(const Tree *tree,
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data);
void tree_traverse_bfs(const Tree *tree,
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data);

#endif /* TREE_H */
