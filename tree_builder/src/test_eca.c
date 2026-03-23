/**
 * test_eca.c — Minimal test for ECA computation on a synthetic tree.
 *
 * Build:  gcc -Wall -std=gnu11 -O2 -g -Iinclude -Isrc src/test_eca.c \
 *             src/node.c src/tree.c -lm -o bin/test_eca
 * Run:    ./bin/test_eca
 */

#include "tree.h"
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
    printf("=== ECA Dry-Run on Synthetic Tree ===\n\n");

    /*
     * We're building for White.  Tree layout (depth / side-to-move):
     *
     *  root (d=0, white to move → OUR move)
     *   ├─ A: sharp line
     *   │   (d=1, black to move → OPPONENT decides)
     *   │    ├─ A1 popular (55%): eval = -40  (bad for opponent, good for us → white+40)
     *   │    ├─ A2 (25%):         eval = +30  (good for opponent)
     *   │    └─ A3 (20%):         eval = -80  (blunder → white+80)
     *   └─ B: solid line
     *       (d=1, black to move → OPPONENT decides)
     *        ├─ B1 popular (45%): eval = +25  (nearly optimal for them)
     *        ├─ B2 (35%):         eval = +30
     *        └─ B3 (20%):         eval = +35
     *
     *  Evals are from WHITE's perspective (standard Stockfish convention).
     *  At opponent nodes, CPL is from the MOVER's perspective (Black):
     *    child_eval_for_mover = engine_eval_cp   (since child stores white-perspective,
     *                                              and children are white-to-move positions)
     *
     *  Wait — let's be precise.  After White's move at root (d=0, white-to-move),
     *  the children are at d=1 and BLACK-to-move.
     *  The children of the d=1 node are at d=2 and WHITE-to-move.
     *  engine_eval_cp is always from White's perspective.
     *
     *  For CPL at the d=1 (black-to-move) node:
     *    The mover is Black.  For each child at d=2:
     *      eval_for_black = -engine_eval_cp_of_child   [negate for black]
     *    best = max(eval_for_black across children) = max(-engine_eval_cp)
     *    CPL  = Σ prob_i × max(0, best - eval_for_black_i)
     *
     *  BUT our tree.c compute_local_eca uses engine_eval_cp directly
     *  (not negated), treating children's eval as "side-to-move" perspective.
     *  This works IF the children's evals represent quality from the PARENT's
     *  mover perspective.  Let's set them that way for this test.
     *
     *  Actually, our compute_local_eca does:
     *    best_cp = max(child->engine_eval_cp)
     *    loss = best_cp - child->engine_eval_cp
     *  This treats higher engine_eval_cp as "better for the mover at this node."
     *
     *  So for a BLACK-to-move node (opponent node when we play White), we want
     *  children's engine_eval_cp to be FROM BLACK'S PERSPECTIVE for the CPL
     *  to make sense.  In real data, evals are from White's perspective and
     *  we'd need a negation.  For this test, let's set evals from the
     *  parent's mover perspective directly, to validate the arithmetic.
     */

    /* Use fake FENs — just need side-to-move marker */
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
     * engine_eval_cp set from BLACK's perspective for CPL calculation.
     * A1: popular but bad for black → eval_for_black = -40 (white gets +40)
     * A2: decent for black → eval_for_black = +30
     * A3: blunder by black → eval_for_black = -80 (white gets +80) */
    TreeNode *a1 = make_node("a1_fen w", "A1-pop",  a_opp, 0.55, -40);
    TreeNode *a2 = make_node("a2_fen w", "A2-ok",   a_opp, 0.25,  30);
    TreeNode *a3 = make_node("a3_fen w", "A3-blun", a_opp, 0.20, -80);
    node_add_child(a_opp, a1); tree->total_nodes++;
    node_add_child(a_opp, a2); tree->total_nodes++;
    node_add_child(a_opp, a3); tree->total_nodes++;

    /* LINE B: solid — opponent node at d=1 (black to move) */
    TreeNode *b_opp = make_node(
        "r1bqkbnr/pppppppp/2n5/8/2B1P3/8/PPPP1PPP/RNBQK1NR b KQkq - 0 1",
        "B-solid", tree->root, 1.0, 0);
    node_add_child(tree->root, b_opp);
    tree->total_nodes++;

    /* B's children: all near-optimal for black */
    TreeNode *b1 = make_node("b1_fen w", "B1-pop",  b_opp, 0.45, -25);
    TreeNode *b2 = make_node("b2_fen w", "B2",      b_opp, 0.35, -30);
    TreeNode *b3 = make_node("b3_fen w", "B3",      b_opp, 0.20, -35);
    node_add_child(b_opp, b1); tree->total_nodes++;
    node_add_child(b_opp, b2); tree->total_nodes++;
    node_add_child(b_opp, b3); tree->total_nodes++;

    /* Compute ECA (playing as White, γ=0.90) */
    printf("Computing ECA (play_as_white=true, γ=0.90)...\n\n");
    size_t annotated = tree_calculate_eca(tree, true, 0.90);
    printf("Annotated %zu nodes.\n\n", annotated);

    /* Print results */
    printf("── Line A (sharp) ──\n");
    printf("  Opponent node (d=%d):\n", a_opp->depth);
    printf("    local_cpl     = %.1f cp\n", a_opp->local_cpl);
    printf("    local_q_loss  = %.4f\n", a_opp->local_q_loss);
    printf("    accumulated   = %.1f cp (Q: %.4f)\n",
           a_opp->accumulated_eca, a_opp->accumulated_q_eca);

    printf("\n── Line B (solid) ──\n");
    printf("  Opponent node (d=%d):\n", b_opp->depth);
    printf("    local_cpl     = %.1f cp\n", b_opp->local_cpl);
    printf("    local_q_loss  = %.4f\n", b_opp->local_q_loss);
    printf("    accumulated   = %.1f cp (Q: %.4f)\n",
           b_opp->accumulated_eca, b_opp->accumulated_q_eca);

    printf("\n── Root (our move, picks max) ──\n");
    printf("    accumulated   = %.1f cp (Q: %.4f)\n",
           tree->root->accumulated_eca, tree->root->accumulated_q_eca);

    const char *pick = tree->root->accumulated_eca > 0
        ? (a_opp->accumulated_eca > b_opp->accumulated_eca ? "A (sharp)" : "B (solid)")
        : "(neither)";
    printf("    → Picks: %s\n", pick);

    /* Manual verification */
    printf("\n── Manual check ──\n");
    /* Line A: best_cp among children = 30 (A2).
     * A1: loss = 30 - (-40) = 70,  prob=0.55 → 0.55 × 70 = 38.5
     * A2: loss = 0,                prob=0.25 → 0
     * A3: loss = 30 - (-80) = 110, prob=0.20 → 0.20 × 110 = 22.0
     * local_cpl = 60.5 */
    printf("  Line A expected local_cpl = 0.55×70 + 0.25×0 + 0.20×110 = %.1f\n",
           0.55*70 + 0.25*0 + 0.20*110);
    /* Line B: best_cp among children = -25 (B1).
     * B1: loss = 0,                prob=0.45 → 0
     * B2: loss = -25 - (-30) = 5,  prob=0.35 → 1.75
     * B3: loss = -25 - (-35) = 10, prob=0.20 → 2.0
     * local_cpl = 3.75 */
    printf("  Line B expected local_cpl = 0.45×0 + 0.35×5 + 0.20×10 = %.1f\n",
           0.45*0 + 0.35*5 + 0.20*10);

    printf("\n  γ^1 = 0.90\n");
    printf("  Line A accumulated = 0.90 × %.1f = %.1f\n",
           0.55*70 + 0.20*110, 0.90 * (0.55*70 + 0.20*110));
    printf("  Line B accumulated = 0.90 × %.1f = %.1f\n",
           0.35*5 + 0.20*10, 0.90 * (0.35*5 + 0.20*10));

    /* Test with different γ */
    printf("\n── Sensitivity to γ ──\n");
    for (double gamma = 0.70; gamma <= 1.01; gamma += 0.05) {
        tree_calculate_eca(tree, true, gamma);
        printf("  γ=%.2f  A=%.1fcp  B=%.1fcp  → %s\n",
               gamma, a_opp->accumulated_eca, b_opp->accumulated_eca,
               a_opp->accumulated_eca > b_opp->accumulated_eca ? "A" : "B");
    }

    tree_destroy(tree);
    printf("\nDone.\n");
    return 0;
}
