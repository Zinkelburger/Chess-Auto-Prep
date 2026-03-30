/**
 * node.c - TreeNode Implementation
 */

#include "node.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>


/* Global node ID counter */
static uint64_t g_next_node_id = 1;


TreeNode* node_create(const char *fen, const char *move_san, 
                      const char *move_uci, TreeNode *parent) {
    TreeNode *node = (TreeNode *)calloc(1, sizeof(TreeNode));
    if (!node) {
        return NULL;
    }
    
    /* Copy FEN */
    if (fen) {
        strncpy(node->fen, fen, MAX_FEN_LENGTH - 1);
        node->fen[MAX_FEN_LENGTH - 1] = '\0';
    }
    
    /* Copy move (if provided) */
    if (move_san) {
        strncpy(node->move_san, move_san, MAX_MOVE_LENGTH - 1);
        node->move_san[MAX_MOVE_LENGTH - 1] = '\0';
    }
    if (move_uci) {
        strncpy(node->move_uci, move_uci, MAX_MOVE_LENGTH - 1);
        node->move_uci[MAX_MOVE_LENGTH - 1] = '\0';
    }
    
    /* Set parent and depth */
    node->parent = parent;
    node->depth = parent ? parent->depth + 1 : 0;
    
    /* Initialize children array */
    node->children = (TreeNode **)malloc(INITIAL_CHILDREN_CAPACITY * sizeof(TreeNode *));
    if (!node->children) {
        free(node);
        return NULL;
    }
    node->children_count = 0;
    node->children_capacity = INITIAL_CHILDREN_CAPACITY;
    
    /* Initialize probabilities */
    node->move_probability = 1.0;
    node->cumulative_probability = parent ? parent->cumulative_probability : 1.0;
    
    /* Initialize stats to zero */
    node->white_wins = 0;
    node->black_wins = 0;
    node->draws = 0;
    node->total_games = 0;
    
    /* No evaluations yet */
    node->has_engine_eval = false;
    node->has_ease = false;
    
    /* Determine whose turn from FEN */
    if (fen) {
        const char *turn = strchr(fen, ' ');
        if (turn && *(turn + 1) == 'w') {
            node->is_white_to_move = true;
        } else if (turn && *(turn + 1) == 'b') {
            node->is_white_to_move = false;
        }
    }
    
    /* Assign unique ID */
    node->node_id = g_next_node_id++;

    /* Not inside an engine-injected subtree by default */
    node->inj_origin_depth = -1;

    return node;
}


void node_reset_id_counter(uint64_t next_id) {
    if (next_id > g_next_node_id)
        g_next_node_id = next_id;
}


void node_destroy(TreeNode *node) {
    if (!node) return;
    
    /* N.B. We do NOT unlink this node from the next_equivalent ring.
       This is safe when destroying the entire tree (all ring members
       are freed), and when pruning PRUNE_EVAL_TOO_LOW nodes (those
       are never added to a ring — they're pruned before FenMap
       insertion).  If future code removes arbitrary nodes while
       rings are live, it must unlink them first. */

    for (size_t i = 0; i < node->children_count; i++) {
        node_destroy(node->children[i]);
    }
    
    free(node->children);
    free(node);
}


void node_destroy_single(TreeNode *node) {
    if (!node) return;
    
    /* Just free the node itself */
    free(node->children);
    free(node);
}


bool node_add_child(TreeNode *parent, TreeNode *child) {
    if (!parent || !child) return false;
    
    /* Grow array if needed */
    if (parent->children_count >= parent->children_capacity) {
        size_t new_capacity = parent->children_capacity * 2;
        TreeNode **new_children = (TreeNode **)realloc(
            parent->children, 
            new_capacity * sizeof(TreeNode *)
        );
        if (!new_children) {
            return false;
        }
        parent->children = new_children;
        parent->children_capacity = new_capacity;
    }
    
    /* Add child */
    parent->children[parent->children_count++] = child;
    child->parent = parent;
    child->depth = parent->depth + 1;
    
    return true;
}


void node_set_eval(TreeNode *node, int eval_cp) {
    if (!node) return;
    node->engine_eval_cp = eval_cp;
    node->has_engine_eval = true;
}


void node_set_ease(TreeNode *node, double ease) {
    if (!node) return;
    /* Clamp to [0, 1] */
    if (ease < 0.0) ease = 0.0;
    if (ease > 1.0) ease = 1.0;
    node->ease = ease;
    node->has_ease = true;
}


void node_set_move_probability(TreeNode *node, double prob) {
    if (!node) return;
    node->move_probability = prob;
    
    /* Update cumulative probability */
    if (node->parent) {
        node->cumulative_probability = node->parent->cumulative_probability * prob;
    } else {
        node->cumulative_probability = prob;
    }
}


void node_set_lichess_stats(TreeNode *node, uint64_t white_wins, 
                            uint64_t black_wins, uint64_t draws) {
    if (!node) return;
    node->white_wins = white_wins;
    node->black_wins = black_wins;
    node->draws = draws;
    node->total_games = white_wins + black_wins + draws;
}


void node_set_eca(TreeNode *node, double local_cpl, double accumulated_eca) {
    if (!node) return;
    node->local_cpl = local_cpl;
    node->accumulated_eca = accumulated_eca;
    node->has_eca = true;
}


double node_win_rate(const TreeNode *node) {
    if (!node || node->total_games == 0) return -1.0;
    
    if (node->is_white_to_move) {
        return (double)node->white_wins / (double)node->total_games;
    } else {
        return (double)node->black_wins / (double)node->total_games;
    }
}


double node_draw_rate(const TreeNode *node) {
    if (!node || node->total_games == 0) return -1.0;
    return (double)node->draws / (double)node->total_games;
}


size_t node_count_subtree(const TreeNode *node) {
    if (!node) return 0;
    
    size_t count = 1;  /* This node */
    for (size_t i = 0; i < node->children_count; i++) {
        count += node_count_subtree(node->children[i]);
    }
    return count;
}


void node_print(const TreeNode *node, int indent) {
    if (!node) return;
    
    /* Print indentation */
    for (int i = 0; i < indent; i++) {
        printf("  ");
    }
    
    /* Print node info */
    if (node->move_san[0]) {
        printf("%s", node->move_san);
    } else {
        printf("(root)");
    }
    
    printf(" [prob=%.2f%%, cumul=%.4f%%]", 
           node->move_probability * 100.0,
           node->cumulative_probability * 100.0);
    
    if (node->total_games > 0) {
        printf(" [games=%lu, W:%.1f%% D:%.1f%% B:%.1f%%]",
               (unsigned long)node->total_games,
               (double)node->white_wins / node->total_games * 100.0,
               (double)node->draws / node->total_games * 100.0,
               (double)node->black_wins / node->total_games * 100.0);
    }
    
    if (node->has_engine_eval) {
        printf(" [eval=%+d]", node->engine_eval_cp);
    }
    
    if (node->has_ease) {
        printf(" [ease=%.3f]", node->ease);
    }
    
    if (node->has_eca) {
        printf(" [local_wp=%.4f acc_wp=%.4f]",
               node->local_cpl, node->accumulated_eca);
    }
    
    printf("\n");
}

