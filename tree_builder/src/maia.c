/**
 * maia.c - Maia-3 Neural Network Integration
 *
 * Ported from the maia-platform-frontend TypeScript implementation.
 * Uses the ONNX Runtime C API to run the maia3_simplified.onnx model, and
 * alexmdc/chesslib (BSD-2-Clause) for legal move generation.
 *
 * Build with -DHAVE_ONNXRUNTIME and link -lonnxruntime to enable.
 * Without ONNX Runtime, maia_create() returns NULL gracefully.
 */

#include "maia.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <ctype.h>

/* chesslib (third_party) — legal move generation + FEN parsing */
#include "../third_party/chesslib/chess.h"
#include "../third_party/chesslib/move.h"
#include "../third_party/chesslib/position.h"
#include "../third_party/chesslib/fen.h"
#include "../third_party/chesslib/generate.h"
#include "../third_party/chesslib/carray.h"

#ifdef HAVE_ONNXRUNTIME
#include <onnxruntime_c_api.h>
#endif

/* ═══════════════════════════════════════════════════════════════════════
 *  Move vocabulary — 4352 UCI strings matching the Maia-3 policy head.
 *  Generated from assets/data/all_moves_maia3_reversed.json.
 * ═══════════════════════════════════════════════════════════════════════ */

#define MAIA_VOCAB_SIZE 4352

#include "maia_vocab.inc"

/* ═══════════════════════════════════════════════════════════════════════
 *  UCI → vocab-index hash table (built once at init)
 * ═══════════════════════════════════════════════════════════════════════ */

#define HASH_BUCKETS 8192

typedef struct HashEntry {
    char uci[6];
    int  index;
    struct HashEntry *next;
} HashEntry;

static HashEntry *vocab_table[HASH_BUCKETS];
static bool vocab_ready = false;

static unsigned hash_uci(const char *s) {
    unsigned h = 5381;
    while (*s)
        h = ((h << 5) + h) ^ (unsigned char)*s++;
    return h & (HASH_BUCKETS - 1);
}

static void vocab_init(void) {
    if (vocab_ready) return;
    memset(vocab_table, 0, sizeof(vocab_table));
    for (int i = 0; i < MAIA_VOCAB_SIZE; i++) {
        unsigned bucket = hash_uci(MAIA_VOCAB[i]);
        HashEntry *e = malloc(sizeof(HashEntry));
        memcpy(e->uci, MAIA_VOCAB[i], 6);
        e->index = i;
        e->next = vocab_table[bucket];
        vocab_table[bucket] = e;
    }
    vocab_ready = true;
}

#ifdef HAVE_ONNXRUNTIME

static int vocab_lookup(const char *uci) {
    unsigned bucket = hash_uci(uci);
    for (HashEntry *e = vocab_table[bucket]; e; e = e->next)
        if (strcmp(e->uci, uci) == 0) return e->index;
    return -1;
}

/* ═══════════════════════════════════════════════════════════════════════
 *  FEN mirroring  (matches TypeScript mirrorFEN)
 *  Flips the board vertically and swaps piece colors so the model
 *  always sees the position from White's perspective.
 * ═══════════════════════════════════════════════════════════════════════ */

static void swap_case(char *s, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (isupper((unsigned char)s[i]))
            s[i] = tolower((unsigned char)s[i]);
        else if (islower((unsigned char)s[i]))
            s[i] = toupper((unsigned char)s[i]);
    }
}

static void mirror_fen(const char *fen, char *out, size_t out_len) {
    char buf[256];
    strncpy(buf, fen, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    /* Tokenise: placement, color, castling, ep, halfmove, fullmove */
    char *tokens[6] = {NULL};
    int t = 0;
    char *p = strtok(buf, " ");
    while (p && t < 6) { tokens[t++] = p; p = strtok(NULL, " "); }

    /* Reverse ranks and swap piece colors */
    char ranks[8][16];
    int nr = 0;
    char placement[128];
    strncpy(placement, tokens[0], sizeof(placement) - 1);
    placement[sizeof(placement) - 1] = '\0';

    char *rp = strtok(placement, "/");
    while (rp && nr < 8) {
        strncpy(ranks[nr], rp, 15);
        ranks[nr][15] = '\0';
        nr++;
        rp = strtok(NULL, "/");
    }

    char mirrored_placement[128];
    int mi = 0;
    for (int i = nr - 1; i >= 0; i--) {
        swap_case(ranks[i], strlen(ranks[i]));
        size_t rlen = strlen(ranks[i]);
        memcpy(mirrored_placement + mi, ranks[i], rlen);
        mi += (int)rlen;
        if (i > 0) mirrored_placement[mi++] = '/';
    }
    mirrored_placement[mi] = '\0';

    /* Swap active color */
    char color = 'w';
    if (t > 1) color = (tokens[1][0] == 'w') ? 'b' : 'w';

    /* Swap castling rights */
    char castling[8] = "-";
    if (t > 2 && tokens[2][0] != '-') {
        int ci = 0;
        for (const char *c = tokens[2]; *c; c++) {
            switch (*c) {
                case 'K': castling[ci++] = 'k'; break;
                case 'Q': castling[ci++] = 'q'; break;
                case 'k': castling[ci++] = 'K'; break;
                case 'q': castling[ci++] = 'Q'; break;
            }
        }
        if (ci == 0) castling[0] = '-';
        castling[ci] = '\0';
        /* Reorder to canonical KQkq */
        char ordered[8];
        int oi = 0;
        for (const char *want = "KQkq"; *want; want++)
            for (int j = 0; castling[j]; j++)
                if (castling[j] == *want) { ordered[oi++] = *want; break; }
        if (oi == 0) ordered[oi++] = '-';
        ordered[oi] = '\0';
        strcpy(castling, ordered);
    }

    /* Mirror en-passant square */
    char ep[4] = "-";
    if (t > 3 && tokens[3][0] != '-') {
        ep[0] = tokens[3][0];
        int rank_num = tokens[3][1] - '0';
        ep[1] = '0' + (9 - rank_num);
        ep[2] = '\0';
    }

    const char *halfmove = (t > 4) ? tokens[4] : "0";
    const char *fullmove = (t > 5) ? tokens[5] : "1";

    snprintf(out, out_len, "%s %c %s %s %s %s",
             mirrored_placement, color, castling, ep, halfmove, fullmove);
}

/* Mirror a UCI move string (e.g. "e2e4" → "e7e5") */
static void mirror_uci_move(const char *uci, char *out) {
    out[0] = uci[0];
    out[1] = '0' + (9 - (uci[1] - '0'));
    out[2] = uci[2];
    out[3] = '0' + (9 - (uci[3] - '0'));
    if (uci[4]) { out[4] = uci[4]; out[5] = '\0'; }
    else out[4] = '\0';
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Board → tensor  (Maia-3 format)
 *  64 squares × 12 piece channels = 768 floats
 *  Layout: for each square (rank-major, a1=0), 12-element one-hot
 *  Piece order: P,N,B,R,Q,K,p,n,b,r,q,k
 * ═══════════════════════════════════════════════════════════════════════ */

#define MAIA3_TENSOR_SIZE (64 * 12)

static const char PIECE_CHARS[] = "PNBRQKpnbrqk";

static void board_to_maia3_tokens(const char *fen, float *tensor) {
    memset(tensor, 0, MAIA3_TENSOR_SIZE * sizeof(float));

    const char *p = fen;
    for (int fen_rank = 0; fen_rank < 8; fen_rank++) {
        int row = 7 - fen_rank;
        int file = 0;
        while (*p && *p != '/' && *p != ' ') {
            if (*p >= '1' && *p <= '8') {
                file += *p - '0';
            } else {
                const char *idx = strchr(PIECE_CHARS, *p);
                if (idx) {
                    int piece_idx = (int)(idx - PIECE_CHARS);
                    int square = row * 8 + file;
                    tensor[square * 12 + piece_idx] = 1.0f;
                }
                file++;
            }
            p++;
        }
        if (*p == '/') p++;
    }
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Legal-move mask using chesslib
 *  Generates all legal moves, converts each to UCI, looks up in vocab.
 * ═══════════════════════════════════════════════════════════════════════ */

static void chessmove_to_uci(ChessMove m, char *out) {
    ChessSquare from = chess_move_from(m);
    ChessSquare to   = chess_move_to(m);
    ChessMovePromote promo = chess_move_promotes(m);

    out[0] = chess_file_to_char(chess_square_file(from));
    out[1] = chess_rank_to_char(chess_square_rank(from));
    out[2] = chess_file_to_char(chess_square_file(to));
    out[3] = chess_rank_to_char(chess_square_rank(to));

    if (promo != CHESS_MOVE_PROMOTE_NONE) {
        out[4] = chess_move_promote_to_char(promo);
        out[5] = '\0';
    } else {
        out[4] = '\0';
    }
}

static void build_legal_mask(const char *fen, float *mask) {
    memset(mask, 0, MAIA_VOCAB_SIZE * sizeof(float));

    ChessPosition pos;
    if (!chess_fen_load(fen, &pos))
        return;

    ChessArray moves;
    chess_array_init(&moves, sizeof(ChessMove));
    chess_generate_moves(&pos, &moves);

    for (size_t i = 0; i < chess_array_size(&moves); i++) {
        ChessMove m = *(const ChessMove *)chess_array_elem(&moves, i);
        char uci[8];
        chessmove_to_uci(m, uci);
        int idx = vocab_lookup(uci);
        if (idx >= 0)
            mask[idx] = 1.0f;
    }

    chess_array_cleanup(&moves);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Softmax over masked logits
 * ═══════════════════════════════════════════════════════════════════════ */

typedef struct { int index; double prob; } IndexProb;

static int cmp_prob_desc(const void *a, const void *b) {
    double da = ((const IndexProb *)a)->prob;
    double db = ((const IndexProb *)b)->prob;
    return (db > da) - (db < da);
}

static int masked_softmax(const float *logits, const float *mask, int n,
                          IndexProb *out, int max_out) {
    int count = 0;
    double max_logit = -1e30;
    int legal_indices[256];
    double legal_logits[256];

    for (int i = 0; i < n && count < 256; i++) {
        if (mask[i] > 0.0f) {
            legal_indices[count] = i;
            legal_logits[count] = (double)logits[i];
            if (legal_logits[count] > max_logit)
                max_logit = legal_logits[count];
            count++;
        }
    }
    if (count == 0) return 0;

    double sum = 0.0;
    double probs[256];
    for (int i = 0; i < count; i++) {
        probs[i] = exp(legal_logits[i] - max_logit);
        sum += probs[i];
    }
    for (int i = 0; i < count; i++)
        probs[i] /= sum;

    int out_count = count < max_out ? count : max_out;
    IndexProb temp[256];
    for (int i = 0; i < count; i++) {
        temp[i].index = legal_indices[i];
        temp[i].prob = probs[i];
    }
    qsort(temp, count, sizeof(IndexProb), cmp_prob_desc);

    memcpy(out, temp, out_count * sizeof(IndexProb));
    return out_count;
}

/* WDL logits → win probability (white perspective) */
static double process_wdl(const float *wdl, bool is_black) {
    double max_w = wdl[0];
    if (wdl[1] > max_w) max_w = wdl[1];
    if (wdl[2] > max_w) max_w = wdl[2];

    double exp_l = exp(wdl[0] - max_w);
    double exp_d = exp(wdl[1] - max_w);
    double exp_w = exp(wdl[2] - max_w);
    double sum = exp_l + exp_d + exp_w;

    double win_prob = (exp_w + 0.5 * exp_d) / sum;
    if (is_black) win_prob = 1.0 - win_prob;

    return win_prob;
}

#endif /* HAVE_ONNXRUNTIME — end of inference helpers */

/* ═══════════════════════════════════════════════════════════════════════
 *  ONNX Runtime context
 * ═══════════════════════════════════════════════════════════════════════ */

struct MaiaContext {
#ifdef HAVE_ONNXRUNTIME
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtSessionOptions *session_options;
    OrtMemoryInfo *memory_info;
#endif
    bool ready;
};

bool maia_is_available(void) {
#ifdef HAVE_ONNXRUNTIME
    return true;
#else
    return false;
#endif
}

MaiaContext *maia_create(const char *model_path) {
    if (!model_path) return NULL;

    vocab_init();
    chess_generate_init();

#ifdef HAVE_ONNXRUNTIME
    MaiaContext *ctx = calloc(1, sizeof(MaiaContext));
    if (!ctx) return NULL;

    ctx->api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!ctx->api) { free(ctx); return NULL; }

    OrtStatus *status;

    status = ctx->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "maia", &ctx->env);
    if (status) {
        fprintf(stderr, "Maia: CreateEnv failed: %s\n",
                ctx->api->GetErrorMessage(status));
        ctx->api->ReleaseStatus(status);
        free(ctx);
        return NULL;
    }

    status = ctx->api->CreateSessionOptions(&ctx->session_options);
    if (status) {
        fprintf(stderr, "Maia: CreateSessionOptions failed\n");
        ctx->api->ReleaseStatus(status);
        ctx->api->ReleaseEnv(ctx->env);
        free(ctx);
        return NULL;
    }

    status = ctx->api->CreateSession(ctx->env, model_path,
                                     ctx->session_options, &ctx->session);
    if (status) {
        fprintf(stderr, "Maia: Failed to load model '%s': %s\n",
                model_path, ctx->api->GetErrorMessage(status));
        ctx->api->ReleaseStatus(status);
        ctx->api->ReleaseSessionOptions(ctx->session_options);
        ctx->api->ReleaseEnv(ctx->env);
        free(ctx);
        return NULL;
    }

    status = ctx->api->CreateCpuMemoryInfo(OrtArenaAllocator,
                                           OrtMemTypeDefault,
                                           &ctx->memory_info);
    if (status) {
        fprintf(stderr, "Maia: CreateCpuMemoryInfo failed\n");
        ctx->api->ReleaseStatus(status);
        ctx->api->ReleaseSession(ctx->session);
        ctx->api->ReleaseSessionOptions(ctx->session_options);
        ctx->api->ReleaseEnv(ctx->env);
        free(ctx);
        return NULL;
    }

    ctx->ready = true;
    fprintf(stderr, "Maia-3 model loaded: %s\n", model_path);
    return ctx;

#else
    (void)model_path;
    fprintf(stderr, "Maia: not compiled with ONNX Runtime support "
                    "(rebuild with MAIA=1)\n");
    return NULL;
#endif
}

void maia_destroy(MaiaContext *ctx) {
    if (!ctx) return;
#ifdef HAVE_ONNXRUNTIME
    if (ctx->memory_info)     ctx->api->ReleaseMemoryInfo(ctx->memory_info);
    if (ctx->session)         ctx->api->ReleaseSession(ctx->session);
    if (ctx->session_options) ctx->api->ReleaseSessionOptions(ctx->session_options);
    if (ctx->env)             ctx->api->ReleaseEnv(ctx->env);
#endif
    free(ctx);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  maia_evaluate — run inference on a single FEN
 * ═══════════════════════════════════════════════════════════════════════ */

bool maia_evaluate(MaiaContext *ctx, const char *fen, int elo,
                   MaiaResponse *response) {
    if (!ctx || !response) return false;
    memset(response, 0, sizeof(MaiaResponse));

#ifndef HAVE_ONNXRUNTIME
    (void)fen; (void)elo;
    return false;
#else
    if (!ctx->ready) return false;

    /* Determine if black to move → mirror to white perspective */
    const char *space = strchr(fen, ' ');
    bool is_black = (space && space[1] == 'b');

    char processed_fen[256];
    if (is_black)
        mirror_fen(fen, processed_fen, sizeof(processed_fen));
    else
        strncpy(processed_fen, fen, sizeof(processed_fen) - 1);
    processed_fen[sizeof(processed_fen) - 1] = '\0';

    /* 1. Board tensor [1, 64, 12] */
    float board_tensor[MAIA3_TENSOR_SIZE];
    board_to_maia3_tokens(processed_fen, board_tensor);

    /* 2. Elo as continuous floats */
    float elo_self_f = (float)elo;
    float elo_oppo_f = (float)elo;

    /* 3. Legal-move mask (on the processed/mirrored FEN) */
    float legal_mask[MAIA_VOCAB_SIZE];
    build_legal_mask(processed_fen, legal_mask);

    /* Create ONNX input tensors */
    const OrtApi *api = ctx->api;
    OrtStatus *status;

    int64_t board_shape[] = {1, 64, 12};
    int64_t elo_shape[]   = {1};

    OrtValue *board_val = NULL, *elo_self_val = NULL, *elo_oppo_val = NULL;

    status = api->CreateTensorWithDataAsOrtValue(
        ctx->memory_info, board_tensor, sizeof(board_tensor),
        board_shape, 3, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &board_val);
    if (status) { api->ReleaseStatus(status); return false; }

    status = api->CreateTensorWithDataAsOrtValue(
        ctx->memory_info, &elo_self_f, sizeof(float),
        elo_shape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &elo_self_val);
    if (status) {
        api->ReleaseStatus(status);
        api->ReleaseValue(board_val);
        return false;
    }

    status = api->CreateTensorWithDataAsOrtValue(
        ctx->memory_info, &elo_oppo_f, sizeof(float),
        elo_shape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &elo_oppo_val);
    if (status) {
        api->ReleaseStatus(status);
        api->ReleaseValue(board_val);
        api->ReleaseValue(elo_self_val);
        return false;
    }

    /* Run inference — 2 outputs: logits_move + logits_value */
    const char *input_names[]  = {"tokens", "elo_self", "elo_oppo"};
    const char *output_names[] = {"logits_move", "logits_value"};
    const OrtValue *inputs[]   = {board_val, elo_self_val, elo_oppo_val};
    OrtValue *outputs[2] = {NULL, NULL};

    status = api->Run(ctx->session, NULL,
                      input_names, inputs, 3,
                      output_names, 2, outputs);

    api->ReleaseValue(board_val);
    api->ReleaseValue(elo_self_val);
    api->ReleaseValue(elo_oppo_val);

    if (status) {
        fprintf(stderr, "Maia: Run failed: %s\n", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return false;
    }

    /* Extract policy logits */
    float *logits = NULL;
    status = api->GetTensorMutableData(outputs[0], (void **)&logits);
    if (status || !logits) {
        if (status) api->ReleaseStatus(status);
        api->ReleaseValue(outputs[0]);
        if (outputs[1]) api->ReleaseValue(outputs[1]);
        return false;
    }

    /* Extract WDL value logits */
    float *wdl = NULL;
    if (outputs[1]) {
        status = api->GetTensorMutableData(outputs[1], (void **)&wdl);
        if (status) {
            api->ReleaseStatus(status);
            wdl = NULL;
        }
    }

    /* Softmax over legal moves */
    IndexProb ranked[MAIA_MAX_MOVES];
    int n = masked_softmax(logits, legal_mask, MAIA_VOCAB_SIZE,
                           ranked, MAIA_MAX_MOVES);

    /* Process WDL */
    if (wdl) {
        response->win_prob = process_wdl(wdl, is_black);
    } else {
        response->win_prob = 0.5;
    }

    api->ReleaseValue(outputs[0]);
    if (outputs[1]) api->ReleaseValue(outputs[1]);

    /* Build response, un-mirroring if needed */
    for (int i = 0; i < n; i++) {
        const char *uci = MAIA_VOCAB[ranked[i].index];
        if (is_black) {
            mirror_uci_move(uci, response->moves[i].uci);
        } else {
            strncpy(response->moves[i].uci, uci, 7);
            response->moves[i].uci[7] = '\0';
        }
        response->moves[i].probability = ranked[i].prob;
    }
    response->move_count = n;
    response->success = true;
    return true;
#endif /* HAVE_ONNXRUNTIME */
}
