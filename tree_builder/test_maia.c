/*
 * test_maia.c — Quick smoke test for the Maia C integration.
 *
 * Build:
 *   gcc -std=gnu11 -O2 -g -DHAVE_ONNXRUNTIME \
 *       -Iinclude -Isrc -Ilocal_includes \
 *       test_maia.c src/maia.c \
 *       third_party/chesslib/chess.c \
 *       third_party/chesslib/move.c \
 *       third_party/chesslib/unmove.c \
 *       third_party/chesslib/position.c \
 *       third_party/chesslib/fen.c \
 *       third_party/chesslib/generate.c \
 *       third_party/chesslib/carray.c \
 *       third_party/chesslib/calloc.c \
 *       -Llocal_lib -lonnxruntime -lm \
 *       -o test_maia
 *
 * Run:
 *   LD_LIBRARY_PATH=local_lib ./test_maia
 */

#include <stdio.h>
#include <stdlib.h>
#include "maia.h"

static const char *TEST_POSITIONS[] = {
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
    "rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
    "r1bqkbnr/pppppppp/2n5/8/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 2 2",
    "rnbqkb1r/pppppppp/5n2/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2",
    NULL
};

static const char *TEST_NAMES[] = {
    "Starting position",
    "After 1.e4 (black to move)",
    "French Defence (1.e4 e6)",
    "Two Knights (1.e4 Nc6 2.Nf3, black to move)",
    "Alekhine Defence (1.e4 Nf6)",
};

int main(void) {
    const char *model_path = "../assets/maia_rapid.onnx";

    printf("═══════════════════════════════════════════════════\n");
    printf("  Maia C Integration Test\n");
    printf("═══════════════════════════════════════════════════\n\n");

    printf("maia_is_available() = %s\n\n", maia_is_available() ? "true" : "false");

    MaiaContext *ctx = maia_create(model_path);
    if (!ctx) {
        fprintf(stderr, "ERROR: Failed to create Maia context with model: %s\n", model_path);
        return 1;
    }

    int elo = 2000;
    printf("Using Elo = %d\n\n", elo);

    for (int t = 0; TEST_POSITIONS[t]; t++) {
        printf("──────────────────────────────────────────────\n");
        printf("Position: %s\n", TEST_NAMES[t]);
        printf("FEN:      %s\n", TEST_POSITIONS[t]);

        MaiaResponse resp;
        if (!maia_evaluate(ctx, TEST_POSITIONS[t], elo, &resp)) {
            printf("  ERROR: maia_evaluate failed!\n\n");
            continue;
        }

        printf("  Success: %s, Moves: %d\n", resp.success ? "yes" : "no", resp.move_count);

        int show = resp.move_count < 10 ? resp.move_count : 10;
        for (int i = 0; i < show; i++) {
            printf("    %2d. %-6s  %.4f (%.1f%%)\n",
                   i + 1,
                   resp.moves[i].uci,
                   resp.moves[i].probability,
                   resp.moves[i].probability * 100.0);
        }
        if (resp.move_count > 10)
            printf("    ... and %d more moves\n", resp.move_count - 10);
        printf("\n");
    }

    maia_destroy(ctx);
    printf("═══════════════════════════════════════════════════\n");
    printf("  All tests passed!\n");
    printf("═══════════════════════════════════════════════════\n");
    return 0;
}
