/**
 * test_eca.c — Minimal test for ECA computation on a synthetic tree.
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
    printf("=== ECA Dry-Run on Synthetic Tree (wp-delta units) ===\n\n");

    /*
     * We're building for White.  Tree layout (depth / side-to-move):
     *
     *  root (d=0, white to move → OUR move)
     *   ├─ A: sharp line
     *   │   (d=1, black to move → OPPONENT decides)
     *   │    ├─ A1 popular (55%): eval = -40  STM eval (white +40 in real terms)
     *   │    ├─ A2 (25%):         eval = +30  STM eval (white -30)
     *   │    └─ A3 (20%):         eval = -80  STM eval (white +80)
     *   └─ B: solid line
     *       (d=1, black to move → OPPONENT decides)
     *        ├─ B1 popular (45%): eval = -25  STM eval (white +25)
     *        ├─ B2 (35%):         eval = -30  STM eval (white +30)
     *        └─ B3 (20%):         eval = -35  STM eval (white +35)
     *
     *  engine_eval_cp is from the node's side-to-move perspective (STM).
     *  Children at d=2 are white-to-move, so their eval is from White's
     *  perspective.  The new compute_local_eca uses:
     *    wp_for_mover = 1 - wp(child.engine_eval_cp)
     *  to compute the mover's (Black's) win probability from the child's
     *  STM eval (which is White's eval).
     */

    Tree *tree = tree_create();
    tree->root = node_create(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        NULL, NULL, NULL);
    tree->root->cumulative_probability = 1.0;
    tree->total_nodes = 1;

    /* LINE A: sharp — opponent node at d=1 (black to move) */
    TreeNode *a_opp = make_node(
        "r1bqkbnr/pppppppp/2n5/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
        "A-sharp", tree->root, 1.0, 0);
    node_add_child(tree->root, a_opp);
    tree->total_nodes++;

    /* A's children (d=2, white to move).
     * Evals are STM (white) perspective. */
    TreeNode *a1 = make_node("a1_fen w", "A1-pop",  a_opp, 0.55,  40);
    TreeNode *a2 = make_node("a2_fen w", "A2-ok",   a_opp, 0.25, -30);
    TreeNode *a3 = make_node("a3_fen w", "A3-blun", a_opp, 0.20,  80);
    node_add_child(a_opp, a1); tree->total_nodes++;
    node_add_child(a_opp, a2); tree->total_nodes++;
    node_add_child(a_opp, a3); tree->total_nodes++;

    /* LINE B: solid — opponent node at d=1 (black to move) */
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

    /* Build RepertoireConfig for the new API */
    RepertoireConfig config = repertoire_config_default();
    config.play_as_white = true;
    config.depth_discount = 0.90;
    config.eca_weight = 0.40;

    printf("Computing ECA (play_as_white=true, γ=0.90, α=0.40)...\n\n");
    size_t annotated = tree_calculate_eca(tree, &config);
    printf("Annotated %zu nodes.\n\n", annotated);

    /* Print results */
    printf("── Line A (sharp) ──\n");
    printf("  Opponent node (d=%d):\n", a_opp->depth);
    printf("    local_cpl (wp-delta) = %.4f\n", a_opp->local_cpl);
    printf("    accumulated (wp-delta) = %.4f\n", a_opp->accumulated_eca);

    printf("\n── Line B (solid) ──\n");
    printf("  Opponent node (d=%d):\n", b_opp->depth);
    printf("    local_cpl (wp-delta) = %.4f\n", b_opp->local_cpl);
    printf("    accumulated (wp-delta) = %.4f\n", b_opp->accumulated_eca);

    printf("\n── Root (our move, blended selection) ──\n");
    printf("    accumulated = %.4f wp-delta\n", tree->root->accumulated_eca);

    const char *pick = tree->root->accumulated_eca > 0
        ? (a_opp->accumulated_eca > b_opp->accumulated_eca ? "A (sharp)" : "B (solid)")
        : "(neither)";
    printf("    → Picks: %s\n", pick);

    /* Manual verification */
    printf("\n── Manual check (wp-delta) ──\n");
    printf("  wp(x) = 1/(1+exp(-0.00368208*x))\n\n");

    /* Line A: children evals (white STM) = +40, -30, +80
     * wp_for_mover(child) = 1 - wp(child_eval)
     * wp(40)=0.572, wp(-30)=0.445, wp(80)=0.644
     * wp_for_mover: 1-0.572=0.428, 1-0.445=0.555, 1-0.644=0.356
     * best_wp = 0.555 (A2, eval=-30, best for Black)
     * A1: delta = 0.555-0.428 = 0.127, prob=0.55 → 0.070
     * A2: delta = 0, prob=0.25 → 0
     * A3: delta = 0.555-0.356 = 0.199, prob=0.20 → 0.040
     * local_cpl ≈ 0.110 */
    double wp40 = win_probability(40);
    double wpn30 = win_probability(-30);
    double wp80 = win_probability(80);
    printf("  Line A children wp: wp(40)=%.3f  wp(-30)=%.3f  wp(80)=%.3f\n",
           wp40, wpn30, wp80);
    double best_wp_a = 1.0 - wpn30; /* best for mover (Black) */
    double da1 = best_wp_a - (1.0 - wp40);
    double da3 = best_wp_a - (1.0 - wp80);
    double local_a = 0.55 * da1 + 0.20 * da3;
    printf("  best_wp_for_mover = %.3f (from A2)\n", best_wp_a);
    printf("  A1 delta=%.3f×0.55=%.4f  A3 delta=%.3f×0.20=%.4f\n",
           da1, 0.55*da1, da3, 0.20*da3);
    printf("  Expected local_cpl = %.4f  (got %.4f)\n", local_a, a_opp->local_cpl);

    /* Line B: children evals = +25, +30, +35
     * wp(25)=0.546, wp(30)=0.555, wp(35)=0.564
     * wp_for_mover: 0.454, 0.445, 0.436
     * best_wp = 0.454 (B1)
     * B2: delta=0.009, prob=0.35 → 0.003
     * B3: delta=0.018, prob=0.20 → 0.004
     * local_cpl ≈ 0.007 */
    double wp25 = win_probability(25);
    double wp30 = win_probability(30);
    double wp35 = win_probability(35);
    printf("\n  Line B children wp: wp(25)=%.3f  wp(30)=%.3f  wp(35)=%.3f\n",
           wp25, wp30, wp35);
    double best_wp_b = 1.0 - wp25;
    double db2 = best_wp_b - (1.0 - wp30);
    double db3 = best_wp_b - (1.0 - wp35);
    double local_b = 0.35 * db2 + 0.20 * db3;
    printf("  best_wp_for_mover = %.3f (from B1)\n", best_wp_b);
    printf("  B2 delta=%.4f×0.35=%.4f  B3 delta=%.4f×0.20=%.4f\n",
           db2, 0.35*db2, db3, 0.20*db3);
    printf("  Expected local_cpl = %.4f  (got %.4f)\n", local_b, b_opp->local_cpl);

    /* Test sensitivity to α */
    printf("\n── Sensitivity to α (eca_weight) ──\n");
    for (double alpha = 0.0; alpha <= 1.01; alpha += 0.20) {
        config.eca_weight = alpha;
        tree_calculate_eca(tree, &config);
        printf("  α=%.2f  A=%.4f  B=%.4f  root=%.4f  → %s\n",
               alpha, a_opp->accumulated_eca, b_opp->accumulated_eca,
               tree->root->accumulated_eca,
               a_opp->accumulated_eca > b_opp->accumulated_eca ? "A" : "B");
    }

    tree_destroy(tree);
    printf("\nDone.\n");
    return 0;
}
