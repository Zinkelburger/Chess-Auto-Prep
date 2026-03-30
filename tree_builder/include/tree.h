/**
 * tree.h - Opening Tree Builder
 *
 * Builds and manages the complete opening tree structure.
 * Tree building interleaves Lichess explorer queries with Stockfish
 * evaluation so branches can be pruned immediately by eval window.
 *
 * At OUR-move nodes:   Stockfish MultiPV → filter by eval → recurse
 * At OPPONENT nodes:   Lichess DB + Maia supplement + engine top-1 → recurse
 */

#ifndef TREE_H
#define TREE_H

#include "node.h"
#include <stdbool.h>

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

    /* Injection */
    int    injections_attempted;
    int    injections_created;
    int    injections_skipped_depth;
    int    injections_skipped_prob;
    int    injections_skipped_exists;
    int    injections_skipped_transposition;
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
     * MultiPV tapers linearly from our_multipv_root (at the root) down to
     * our_multipv_floor (at taper_depth and beyond).  All lines within
     * max_eval_loss_cp of the best are added — no separate candidate cap. */
    int our_multipv_root;           /* MultiPV at depth 0 (explore broadly) */
    int our_multipv_floor;          /* MultiPV at depth >= taper_depth */
    int taper_depth;                /* Ply at which MultiPV bottoms out */
    int max_eval_loss_cp;           /* Candidates must be within this of best */

    /* Opponent-move selection (Lichess-driven)
     *
     * Mass target tapers linearly from opp_mass_root (at the root) down
     * to opp_mass_floor (at taper_depth and beyond).  Combined with
     * cumulative-probability pruning this focuses deep branches on the
     * most popular replies only. */
    int opp_max_children;           /* Max opponent responses per position (0 = unlimited) */
    double opp_mass_root;           /* Mass target at depth 0 (explore broadly) */
    double opp_mass_floor;          /* Mass target at depth >= taper_depth */

    /* Eval window pruning — stop exploring outside this range */
    int min_eval_cp;                /* Prune if our eval drops below this */
    int max_eval_cp;                /* Prune if our eval exceeds this (already won) */
    bool relative_eval;             /* Make eval window relative to root eval */

    /* Lichess API settings */
    const char *rating_range;       /* e.g. "2000,2200,2500" */
    const char *speeds;             /* e.g. "blitz,rapid,classical" */
    int min_games;                  /* Minimum games to consider a move */
    bool use_masters;               /* Use masters database instead of Lichess */

    /* Engine injection at opponent nodes.
     *
     * The engine's top-1 move is injected when both structural gates pass:
     *   1. node->depth <= inj_max_depth
     *   2. node->cumulative_probability >= inj_min_probability
     * and the resulting FEN is not already in the tree (transposition check).
     *
     * The injected PV is capped at inj_max_line_depth plies below the
     * injection point (instead of extending to max_depth). */
    int    inj_max_depth;           /* Don't inject deeper than this ply */
    double inj_min_probability;     /* Don't inject on low-probability lines */
    int    inj_max_line_depth;      /* Cap injected PV continuation (0 = unlimited) */

    /* Maia supplement: after Lichess moves are added, Maia fills in
       remaining mass with predicted human moves.  Positions can have a
       mix of Lichess and Maia children.  maia_only bypasses Lichess
       entirely. */
    struct MaiaContext *maia;       /* NULL = disabled */
    int    maia_elo;                /* Elo for Maia predictions (600-2400) */
    double maia_threshold;          /* Min cumProb to trigger Maia fallback */
    double maia_min_prob;           /* Skip Maia moves below this probability */
    bool   maia_only;              /* Use Maia exclusively (bypass Lichess API) */

    /* Progress callback */
    void (*progress_callback)(int nodes_built, int current_depth, const char *current_fen);

    /* Build instrumentation (optional, caller-owned) */
    BuildStats *stats;

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
 *   - Opponent moves:  Lichess DB + engine top-1 → batch eval → recurse
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

size_t tree_calculate_ease(Tree *tree);

/**
 * Compute ECA (Expected Centipawn Advantage) for the entire tree.
 *
 * All values in centipawn units.  Post-order DFS:
 *   - local_cpl at each node from children's evals (avg cp loss by opponent)
 *   - accumulated_eca bottom-up
 *
 * At opponent nodes:
 *   accumulated = γ^d × local_cpl + Σ(prob_i × child.accumulated_eca)
 * At our-move nodes:
 *   avg_cpl = child.accumulated_eca / subtree_opp_plies
 *   score   = eval_conf × eval_us_cp + eval_weight × avg_cpl
 *   Select the child with the highest blended score, propagate its eca.
 */
size_t tree_calculate_eca(Tree *tree, const struct RepertoireConfig *config);

typedef struct {
    TreeNode *child;
    double score;
    double accumulated_eca;
} ScoredChild;

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
