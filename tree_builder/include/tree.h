/**
 * tree.h - Opening Tree Builder
 * 
 * Builds and manages the complete opening tree structure.
 * Handles tree traversal, building from Lichess data, and statistics.
 */

#ifndef TREE_H
#define TREE_H

#include "node.h"
#include <stdbool.h>

/* Forward declarations */
struct LichessExplorer;

/**
 * TreeConfig - Configuration for tree building
 */
typedef struct TreeConfig {
    /* Side to play */
    bool play_as_white;             /* Which side is our repertoire? */

    /* Traversal limits */
    double min_probability;         /* Stop exploring below this cumul. probability */
    int max_depth;                  /* Maximum depth in ply */
    int max_nodes;                  /* Maximum total nodes (0 = unlimited) */
    int max_children;               /* Max moves to explore per position (0 = unlimited) */
    double opponent_mass_target;    /* Stop adding opponent moves after this fraction of prob mass (0 = unlimited) */

    /* Lichess API settings */
    const char *rating_range;       /* Rating range, e.g., "1600,1800,2000,2200" */
    const char *speeds;             /* Time controls, e.g., "rapid,classical" */
    int min_games;                  /* Minimum games to consider a move */
    bool use_masters;               /* Use masters database instead of Lichess */

    /* Progress callback */
    void (*progress_callback)(int nodes_built, int current_depth, const char *current_fen);

} TreeConfig;

/**
 * Tree - The complete opening tree
 */
typedef struct Tree {
    TreeNode *root;                 /* Root node */
    TreeConfig config;              /* Configuration used to build */
    
    /* Statistics */
    size_t total_nodes;             /* Total nodes in tree */
    int max_depth_reached;          /* Deepest node depth */
    
    /* Building state */
    bool is_building;               /* Currently building? */
    bool build_complete;            /* Did the build finish without interruption? */
    uint64_t next_node_id;          /* Counter for node IDs */
    
} Tree;


/**
 * Create default tree configuration
 * 
 * @return TreeConfig with sensible defaults
 */
TreeConfig tree_config_default(void);

/**
 * Create a new empty tree
 * 
 * @return Newly allocated Tree, or NULL on failure
 */
Tree* tree_create(void);

/**
 * Free tree and all its nodes
 * 
 * @param tree The tree to free
 */
void tree_destroy(Tree *tree);

/**
 * Build the tree from a starting FEN
 * 
 * Uses the Lichess explorer API to traverse all positions
 * until probability drops below threshold.
 * 
 * @param tree The tree to build into
 * @param start_fen Starting FEN position
 * @param config Build configuration
 * @param explorer Lichess explorer instance
 * @return true on success, false on failure
 */
bool tree_build(Tree *tree, const char *start_fen, 
                const TreeConfig *config, struct LichessExplorer *explorer);

/**
 * Stop an in-progress build
 * 
 * @param tree The tree being built
 */
void tree_stop_build(Tree *tree);

/**
 * Find a node by FEN
 * 
 * @param tree The tree to search
 * @param fen The FEN to find
 * @return Pointer to node, or NULL if not found
 */
TreeNode* tree_find_by_fen(const Tree *tree, const char *fen);

/**
 * Find a node by following a move sequence from root
 * 
 * @param tree The tree to search
 * @param moves Array of SAN moves
 * @param num_moves Number of moves
 * @return Pointer to node, or NULL if path doesn't exist
 */
TreeNode* tree_find_by_moves(const Tree *tree, const char **moves, size_t num_moves);

/**
 * Get all leaf nodes (nodes with no children)
 * 
 * @param tree The tree to search
 * @param out_leaves Output array (caller allocates)
 * @param max_leaves Maximum number of leaves to return
 * @return Number of leaves found
 */
size_t tree_get_leaves(const Tree *tree, TreeNode **out_leaves, size_t max_leaves);

/**
 * Get nodes at a specific depth
 * 
 * @param tree The tree to search
 * @param depth Target depth
 * @param out_nodes Output array (caller allocates)
 * @param max_nodes Maximum number of nodes to return
 * @return Number of nodes found
 */
size_t tree_get_nodes_at_depth(const Tree *tree, int depth, 
                                TreeNode **out_nodes, size_t max_nodes);

/**
 * Calculate and populate ease scores for all nodes
 * 
 * Requires engine evaluations to be set on nodes.
 * 
 * @param tree The tree to update
 * @return Number of nodes updated
 */
size_t tree_calculate_ease(Tree *tree);

/**
 * Compute ECA (Expected Centipawn Advantage) for the entire tree.
 *
 * Two passes in one post-order DFS:
 *   1. local_cpl / local_q_loss at each node (from children's evals)
 *   2. accumulated_eca / accumulated_q_eca (depth-discounted sum)
 *
 * At opponent nodes:
 *   accumulated = γ^depth × local_cpl + Σ(prob_i × child_accumulated)
 * At our-move nodes:
 *   accumulated = max(child_accumulated)   [we pick the best line]
 *
 * @param tree The tree to annotate
 * @param play_as_white Whether the repertoire is for White
 * @param depth_discount Depth discount factor γ (e.g. 0.90)
 * @return Number of nodes annotated
 */
size_t tree_calculate_eca(Tree *tree, bool play_as_white, double depth_discount);

/**
 * Recalculate cumulative probabilities from root
 * 
 * @param tree The tree to update
 */
void tree_recalculate_probabilities(Tree *tree);

/**
 * Get the move sequence (line) from root to a node
 * 
 * @param node The target node
 * @param out_moves Output array for moves (caller allocates)
 * @param max_moves Maximum moves to return
 * @return Number of moves in path
 */
size_t tree_get_line_to_node(const TreeNode *node, char (*out_moves)[MAX_MOVE_LENGTH], 
                              size_t max_moves);

/**
 * Print tree statistics
 * 
 * @param tree The tree to summarize
 */
void tree_print_stats(const Tree *tree);

/**
 * Print tree structure (for debugging)
 * 
 * @param tree The tree to print
 * @param max_depth Maximum depth to print (-1 for all)
 */
void tree_print(const Tree *tree, int max_depth);

/**
 * Traverse tree depth-first, calling callback for each node
 * 
 * @param tree The tree to traverse
 * @param callback Function to call for each node
 * @param user_data User data passed to callback
 */
void tree_traverse_dfs(const Tree *tree, 
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data);

/**
 * Traverse tree breadth-first, calling callback for each node
 * 
 * @param tree The tree to traverse
 * @param callback Function to call for each node
 * @param user_data User data passed to callback
 */
void tree_traverse_bfs(const Tree *tree,
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data);

#endif /* TREE_H */

