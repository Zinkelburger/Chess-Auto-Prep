/**
 * tree.h - Opening Tree Builder
 *
 * Builds and manages the complete opening tree structure.
 * Tree building interleaves Lichess explorer queries with Stockfish
 * evaluation so branches can be pruned immediately by eval window.
 *
 * At OUR-move nodes:   Stockfish MultiPV → filter by eval → recurse
 * At OPPONENT nodes:   Lichess DB (+ Maia fallback) + engine top-1 → recurse
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

    /* Our-move candidate selection (engine-driven) */
    int our_multipv;                /* MultiPV lines to evaluate per position */
    int our_max_candidates_early;   /* Max candidates at depth < taper_depth */
    int our_max_candidates_late;    /* Max candidates at depth >= taper_depth */
    int taper_depth;                /* Ply at which candidate cap shrinks */
    int max_eval_loss_cp;           /* Candidates must be within this of best */

    /* Opponent-move selection (Lichess-driven) */
    int opp_max_children;           /* Max opponent responses per position (0 = unlimited) */
    double opp_mass_target;         /* Stop adding after this fraction of prob mass (0 = disabled) */

    /* Eval window pruning — stop exploring outside this range */
    int min_eval_cp;                /* Prune if our eval drops below this */
    int max_eval_cp;                /* Prune if our eval exceeds this (already won) */

    /* Lichess API settings */
    const char *rating_range;       /* e.g. "2000,2200,2500" */
    const char *speeds;             /* e.g. "blitz,rapid,classical" */
    int min_games;                  /* Minimum games to consider a move */
    bool use_masters;               /* Use masters database instead of Lichess */

    /* Maia fallback: when the explorer is exhausted but cumulative
       probability is still above maia_threshold, use Maia to predict
       likely human moves and continue expanding. */
    struct MaiaContext *maia;       /* NULL = disabled */
    int    maia_elo;                /* Elo for Maia predictions (1100-2100) */
    double maia_threshold;          /* Min cumProb to trigger Maia fallback */
    double maia_min_prob;           /* Skip Maia moves below this probability */

    /* Progress callback */
    void (*progress_callback)(int nodes_built, int current_depth, const char *current_fen);

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

TreeNode* tree_find_by_fen(const Tree *tree, const char *fen);
TreeNode* tree_find_by_moves(const Tree *tree, const char **moves, size_t num_moves);
size_t tree_get_leaves(const Tree *tree, TreeNode **out_leaves, size_t max_leaves);
size_t tree_get_nodes_at_depth(const Tree *tree, int depth,
                                TreeNode **out_nodes, size_t max_nodes);

size_t tree_calculate_ease(Tree *tree);

/**
 * Compute ECA (Expected Centipawn Advantage) for the entire tree.
 *
 * Uses win-probability-delta units.  Post-order DFS:
 *   - local_cpl at each node from children's evals
 *   - accumulated_eca bottom-up
 *
 * At opponent nodes:
 *   accumulated = γ^d × local_cpl + Σ(prob_i × child.accumulated_eca)
 * At our-move nodes:
 *   Select the child using the blended score
 *   (α × wp_us + (1-α) × child.accumulated_eca), propagate its eca.
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
