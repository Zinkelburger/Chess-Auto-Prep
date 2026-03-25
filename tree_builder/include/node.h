/**
 * node.h - Chess Opening Tree Node Structure
 * 
 * Defines the TreeNode structure for building opening repertoire trees.
 * Each node represents a position with associated statistics from Lichess.
 */

#ifndef TREE_NODE_H
#define TREE_NODE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* Maximum FEN string length (standard chess FEN) */
#define MAX_FEN_LENGTH 128

/* Maximum move string length (e.g., "Qxd7+") */
#define MAX_MOVE_LENGTH 16

/* Maximum number of children per node */
#define MAX_CHILDREN 64

/* Initial children array capacity */
#define INITIAL_CHILDREN_CAPACITY 8


/**
 * TreeNode - A node in the opening tree
 * 
 * Contains position data, statistics, and tree structure pointers.
 */
typedef struct TreeNode {
    /* Position identification */
    char fen[MAX_FEN_LENGTH];           /* FEN string for this position */
    char move_san[MAX_MOVE_LENGTH];     /* Move (in SAN) that led to this position */
    char move_uci[MAX_MOVE_LENGTH];     /* Move (in UCI) that led to this position */
    
    /* Tree structure */
    struct TreeNode *parent;            /* Parent node (NULL for root) */
    struct TreeNode **children;         /* Dynamic array of child nodes */
    size_t children_count;              /* Number of children */
    size_t children_capacity;           /* Allocated capacity for children array */
    
    /* Engine evaluation */
    int engine_eval_cp;                 /* Engine evaluation in centipawns */
    bool has_engine_eval;               /* Whether engine eval is available */
    
    /* Ease metric (calculated from move probabilities + eval) */
    double ease;                        /* Ease score [0.0, 1.0] */
    bool has_ease;                      /* Whether ease is calculated */
    
    /* Move probability from Lichess */
    double move_probability;            /* Probability of this move [0.0, 1.0] */
    double cumulative_probability;      /* Path probability from root */
    
    /* Lichess statistics */
    uint64_t white_wins;                /* Number of white wins from this position */
    uint64_t black_wins;                /* Number of black wins from this position */
    uint64_t draws;                     /* Number of draws from this position */
    uint64_t total_games;               /* Total games in Lichess database */
    bool explored;                      /* This FEN was queried via the explorer API */
    
    /* Metadata */
    int depth;                          /* Depth in tree (root = 0) */
    bool is_white_to_move;              /* Whose turn it is */
    
    /* Node ID for serialization */
    uint64_t node_id;                   /* Unique identifier for this node */
    
    /* Opening info (populated from Lichess API) */
    char opening_name[128];             /* Opening name, e.g., "Sicilian Defense" */
    char opening_eco[8];                /* ECO code, e.g., "B20" */
    
    /* Repertoire generation data */
    double repertoire_score;            /* Composite repertoire quality score */
    bool is_repertoire_move;            /* Selected as part of the repertoire */
    double opponent_ease;               /* Ease score from opponent's perspective */
    double trap_score;                  /* How often opponents play suboptimal here */
    
    /* ECA (Expected Centipawn Advantage) — per-node and accumulated.
     *
     * local_cpl:  expected centipawn loss by the side to move at THIS node,
     *             = Σ(prob_i × max(0, best_cp - cp_i)) over children.
     *             Only meaningful when children_count > 0 and evals exist.
     *
     * local_q_loss:  same idea but in Q-value space [-1,1] instead of raw cp.
     *                Captures diminishing returns of large blunders.
     *
     * accumulated_eca:  total depth-discounted CPL in the subtree rooted here.
     *                   = γ^depth × local_cpl + Σ(prob_i × child_accumulated_eca)
     *                   at opponent nodes, and max(child_accumulated_eca) at our
     *                   nodes (we pick the best line).
     *
     * accumulated_q_eca:  same but using Q-loss instead of raw cp.
     */
    double local_cpl;
    double local_q_loss;
    double accumulated_eca;
    double accumulated_q_eca;
    bool   has_eca;                     /* Whether ECA values have been computed */
    
} TreeNode;


/**
 * Create a new TreeNode
 * 
 * @param fen The FEN string for this position
 * @param move_san The SAN notation of the move that led here (NULL for root)
 * @param move_uci The UCI notation of the move that led here (NULL for root)
 * @param parent Pointer to parent node (NULL for root)
 * @return Newly allocated TreeNode, or NULL on failure
 */
TreeNode* node_create(const char *fen, const char *move_san, 
                      const char *move_uci, TreeNode *parent);

/**
 * Free a TreeNode and all its descendants (recursive)
 * 
 * @param node The node to free
 */
void node_destroy(TreeNode *node);

/**
 * Free only this node (not its children)
 * 
 * @param node The node to free
 */
void node_destroy_single(TreeNode *node);

/**
 * Add a child node
 * 
 * @param parent The parent node
 * @param child The child to add
 * @return true on success, false on failure (memory allocation)
 */
bool node_add_child(TreeNode *parent, TreeNode *child);

/**
 * Set engine evaluation
 * 
 * @param node The node to update
 * @param eval_cp Evaluation in centipawns (positive = white advantage)
 */
void node_set_eval(TreeNode *node, int eval_cp);

/**
 * Set ease score
 * 
 * @param node The node to update
 * @param ease Ease value [0.0, 1.0]
 */
void node_set_ease(TreeNode *node, double ease);

/**
 * Set move probability
 * 
 * @param node The node to update
 * @param prob Local probability [0.0, 1.0]
 */
void node_set_move_probability(TreeNode *node, double prob);

/**
 * Set Lichess statistics
 * 
 * @param node The node to update
 * @param white_wins Number of white wins
 * @param black_wins Number of black wins
 * @param draws Number of draws
 */
void node_set_lichess_stats(TreeNode *node, uint64_t white_wins, 
                            uint64_t black_wins, uint64_t draws);

/**
 * Calculate win rate for the side to move
 * 
 * @param node The node to query
 * @return Win rate [0.0, 1.0], or -1.0 if no games
 */
double node_win_rate(const TreeNode *node);

/**
 * Calculate draw rate
 * 
 * @param node The node to query
 * @return Draw rate [0.0, 1.0], or -1.0 if no games
 */
double node_draw_rate(const TreeNode *node);

/**
 * Get total number of nodes in subtree (including this node)
 * 
 * @param node The root of the subtree
 * @return Total node count
 */
size_t node_count_subtree(const TreeNode *node);

/**
 * Set ECA (Expected Centipawn Advantage) values
 *
 * @param node The node to update
 * @param local_cpl Local expected centipawn loss
 * @param local_q_loss Local expected Q-value loss
 * @param accumulated_eca Subtree accumulated ECA (raw cp)
 * @param accumulated_q_eca Subtree accumulated ECA (Q-values)
 */
void node_set_eca(TreeNode *node, double local_cpl, double local_q_loss,
                  double accumulated_eca, double accumulated_q_eca);

/**
 * Print node info to stdout (for debugging)
 * 
 * @param node The node to print
 * @param indent Indentation level
 */
void node_print(const TreeNode *node, int indent);

#endif /* TREE_NODE_H */

