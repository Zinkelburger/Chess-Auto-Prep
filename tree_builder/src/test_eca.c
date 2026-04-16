/**
 * test_eca.c — Minimal test for expectimax value propagation on a synthetic tree.
 *
 * Build:  gcc -Wall -std=gnu11 -O2 -g -Iinclude -Isrc src/test_eca.c \
 *             src/node.c src/tree.c src/repertoire.c src/database.c \
 *             src/cJSON.c src/serialization.c src/chess_logic.c \
 *             src/sqlite3_amalg.c -lm -lpthread -ldl -o bin/test_eca
 * Run:    ./bin/test_eca
 */

#include "tree.h"
#include "repertoire.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

static TreeNode *make_node(const char *fen, const char *san,
                           TreeNode *parent, double prob,
                           int eval_cp) {
    TreeNode *n = node_create(fen, san, NULL, parent);
    node_set_move_probability(n, prob);
    node_set_eval(n, eval_cp);
    return n;
}

int main(void) {
    printf("=== Expectimax Dry-Run on Synthetic Tree ===\n\n");

    /*
     * We're building for White.  Tree layout (depth / side-to-move):
     *
     *  root (d=0, white to move -> OUR move)
     *   +- A: sharp line
     *   |   (d=1, black to move -> OPPONENT decides)
     *   |    +- A1 popular (55%): eval = -40  STM eval (white +40 in real terms)
     *   |    +- A2 (25%):         eval = +30  STM eval (white -30)
     *   |    +- A3 (20%):         eval = -80  STM eval (white +80)
     *   +- B: solid line
     *       (d=1, black to move -> OPPONENT decides)
     *        +- B1 popular (45%): eval = -25  STM eval (white +25)
     *        +- B2 (35%):         eval = -30  STM eval (white +30)
     *        +- B3 (20%):         eval = -35  STM eval (white +35)
     *
     *  engine_eval_cp is from the node's side-to-move perspective (STM).
     *  Children at d=2 are white-to-move, so their eval IS White's eval.
     */

    Tree *tree = tree_create();
    tree->root = node_create(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        NULL, NULL, NULL);
    tree->root->cumulative_probability = 1.0;
    tree->total_nodes = 1;

    /* LINE A: sharp -- opponent node at d=1 (black to move) */
    TreeNode *a_opp = make_node(
        "r1bqkbnr/pppppppp/2n5/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
        "A-sharp", tree->root, 1.0, 0);
    node_add_child(tree->root, a_opp);
    tree->total_nodes++;

    /* A's children (d=2, white to move). Evals are STM (white) perspective. */
    TreeNode *a1 = make_node("a1_fen w", "A1-pop",  a_opp, 0.55,  40);
    TreeNode *a2 = make_node("a2_fen w", "A2-ok",   a_opp, 0.25, -30);
    TreeNode *a3 = make_node("a3_fen w", "A3-blun", a_opp, 0.20,  80);
    node_add_child(a_opp, a1); tree->total_nodes++;
    node_add_child(a_opp, a2); tree->total_nodes++;
    node_add_child(a_opp, a3); tree->total_nodes++;

    /* LINE B: solid -- opponent node at d=1 (black to move) */
    TreeNode *b_opp = make_node(
        "r1bqkbnr/pppppppp/2n5/8/2B1P3/8/PPPP1PPP/RNBQK1NR b KQkq - 0 1",
        "B-solid", tree->root, 1.0, 0);
    node_add_child(tree->root, b_opp);
    tree->total_nodes++;

    /* B's children: all near-equal evals */
    TreeNode *b1 = make_node("b1_fen w", "B1-pop",  b_opp, 0.45,  25);
    TreeNode *b2 = make_node("b2_fen w", "B2",      b_opp, 0.35,  30);
    TreeNode *b3 = make_node("b3_fen w", "B3",      b_opp, 0.20,  35);
    node_add_child(b_opp, b1); tree->total_nodes++;
    node_add_child(b_opp, b2); tree->total_nodes++;
    node_add_child(b_opp, b3); tree->total_nodes++;

    RepertoireConfig config = repertoire_config_default();
    config.play_as_white = true;
    config.leaf_confidence = 1.0;

    printf("Computing expectimax (play_as_white=true, pure expectimax)...\n\n");
    size_t annotated = tree_calculate_expectimax(tree, &config);
    printf("Annotated %zu nodes.\n\n", annotated);

    /* Print results */
    printf("-- Leaf values (V = wp(eval_for_us)) --\n");
    printf("  A1 (eval +40 for us): V = %.4f\n", a1->expectimax_value);
    printf("  A2 (eval -30 for us): V = %.4f  (opp best = low V for us)\n",
           a2->expectimax_value);
    printf("  A3 (eval +80 for us): V = %.4f\n", a3->expectimax_value);
    printf("  B1 (eval +25 for us): V = %.4f\n", b1->expectimax_value);
    printf("  B2 (eval +30 for us): V = %.4f\n", b2->expectimax_value);
    printf("  B3 (eval +35 for us): V = %.4f\n", b3->expectimax_value);

    printf("\n-- Opponent nodes (V = Σ prob_i × V_child_i) --\n");
    printf("  A (sharp, d=%d):\n", a_opp->depth);
    printf("    local_cpl = %.4f\n", a_opp->local_cpl);
    printf("    V = %.4f\n", a_opp->expectimax_value);

    printf("  B (solid, d=%d):\n", b_opp->depth);
    printf("    local_cpl = %.4f\n", b_opp->local_cpl);
    printf("    V = %.4f\n", b_opp->expectimax_value);

    printf("\n-- Root (our move: max V among children) --\n");
    printf("    V = %.4f\n", tree->root->expectimax_value);

    const char *pick = (a_opp->expectimax_value > b_opp->expectimax_value)
        ? "A (sharp)" : "B (solid)";
    printf("    -> Picks: %s\n", pick);

    /* Manual verification */
    printf("\n-- Manual verification --\n");
    printf("  wp(x) = 1/(1+exp(-0.00368208*x))\n");

    /* Leaf V values (all are wp(eval), eval_for_us = eval since white to move) */
    double v_a1 = win_probability(40);  /* +40 for white */
    double v_a2 = win_probability(-30); /* -30 for white */
    double v_a3 = win_probability(80);  /* +80 for white */
    printf("  Expected leaves: A1=%.4f A2=%.4f A3=%.4f\n", v_a1, v_a2, v_a3);

    /* Opponent node A: pure expectimax
       V = 0.55*V(A1) + 0.25*V(A2) + 0.20*V(A3) */
    double v_opp_a = 0.55*v_a1 + 0.25*v_a2 + 0.20*v_a3;
    double v_a = v_opp_a;
    printf("\n  Line A:\n");
    printf("    V = 0.55*%.4f + 0.25*%.4f + 0.20*%.4f = %.4f\n",
           v_a1, v_a2, v_a3, v_opp_a);
    printf("    Expected V = %.4f  (got %.4f)\n", v_a, a_opp->expectimax_value);

    double v_b1 = win_probability(25);
    double v_b2 = win_probability(30);
    double v_b3 = win_probability(35);
    double v_opp_b = 0.45*v_b1 + 0.35*v_b2 + 0.20*v_b3;
    double v_b = v_opp_b;
    printf("\n  Line B:\n");
    printf("    V = 0.45*%.4f + 0.35*%.4f + 0.20*%.4f = %.4f\n",
           v_b1, v_b2, v_b3, v_opp_b);
    printf("    Expected V = %.4f  (got %.4f)\n", v_b, b_opp->expectimax_value);

    /* Root: our move, V = max(V_A, V_B) */
    double v_root = v_a > v_b ? v_a : v_b;
    printf("\n  Root: max(%.4f, %.4f) = %.4f  (got %.4f)\n",
           v_a, v_b, v_root, tree->root->expectimax_value);

    tree_destroy(tree);
    printf("\nDone.\n");
    return 0;
}
