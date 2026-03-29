/**
 * maia.h - Maia-3 Neural Network Integration
 *
 * Provides human-like move probabilities via the Maia-3 ONNX model.
 * Used as a fallback when the Lichess opening explorer is exhausted
 * but the line is still likely enough to warrant expansion.
 *
 * Maia-3 uses:
 *   - (64, 12) board encoding (per-square one-hot pieces)
 *   - Continuous Elo floats (600-2400)
 *   - 4352-move vocabulary (64x64 grid + 256 promotions)
 *   - Win/Draw/Loss value head
 *
 * Requires: ONNX Runtime (link with -lonnxruntime, compile with -DHAVE_ONNXRUNTIME)
 * Without ONNX Runtime the API is still available but maia_create() returns NULL.
 */

#ifndef MAIA_H
#define MAIA_H

#include <stdbool.h>
#include <stddef.h>

#define MAIA_MAX_MOVES 128

typedef struct MaiaContext MaiaContext;

typedef struct {
    char uci[8];
    double probability;
} MaiaMove;

typedef struct {
    MaiaMove moves[MAIA_MAX_MOVES];
    int move_count;
    bool success;
    double win_prob;
} MaiaResponse;

/**
 * Create a Maia context by loading the ONNX model.
 *
 * @param model_path  Path to the maia3_simplified.onnx file
 * @return Opaque context, or NULL if ONNX Runtime is unavailable / load fails
 */
MaiaContext *maia_create(const char *model_path);

/**
 * Run Maia-3 inference on a position.
 *
 * Produces a probability distribution over legal moves, sorted descending.
 * Handles black-to-move positions internally (mirrors to white perspective).
 *
 * @param ctx       Maia context from maia_create()
 * @param fen       FEN string of the position to evaluate
 * @param elo       Elo rating for the player (600-2400, used for both sides)
 * @param response  Output: filled with moves, probabilities, and win_prob
 * @return true on success
 */
bool maia_evaluate(MaiaContext *ctx, const char *fen, int elo,
                   MaiaResponse *response);

/**
 * Release all resources.
 */
void maia_destroy(MaiaContext *ctx);

/**
 * Check whether Maia support was compiled in (HAVE_ONNXRUNTIME).
 */
bool maia_is_available(void);

#endif /* MAIA_H */
