/**
 * maia.c - Maia Neural Network Integration
 *
 * Ported from the Flutter MaiaService / MaiaTensor implementation.
 * Uses the ONNX Runtime C API to run the maia_rapid.onnx model, and
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
 *  Move vocabulary — 1880 UCI strings matching the Maia policy head.
 *  Generated from assets/data/all_moves_reversed.json.
 * ═══════════════════════════════════════════════════════════════════════ */

#define MAIA_VOCAB_SIZE 1880

#include "maia_vocab.inc"

/* ═══════════════════════════════════════════════════════════════════════
 *  UCI → vocab-index hash table (built once at init)
 * ═══════════════════════════════════════════════════════════════════════ */

#define HASH_BUCKETS 4096

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
 *  Elo → category mapping  (matches Flutter MaiaTensor._mapToCategory)
 *  Bins: <1100=0, 1100-1199=1, … , 1900-1999=9, >=2000=10
 * ═══════════════════════════════════════════════════════════════════════ */

static int elo_to_category(int elo) {
    if (elo < 1100) return 0;
    if (elo >= 2000) return 10;
    return 1 + (elo - 1100) / 100;
}

/* ═══════════════════════════════════════════════════════════════════════
 *  FEN mirroring  (matches Flutter MaiaTensor.mirrorFEN)
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
 *  Board → tensor  (matches Flutter MaiaTensor.boardToTensor)
 *  18 channels × 8 × 8 = 1152 floats
 *    ch  0-11: piece planes (P,N,B,R,Q,K,p,n,b,r,q,k)
 *    ch 12:    turn (all 1s if white)
 *    ch 13-16: castling rights (K,Q,k,q)
 *    ch 17:    en-passant target
 * ═══════════════════════════════════════════════════════════════════════ */

#define TENSOR_SIZE (18 * 64)

static const char PIECE_CHARS[] = "PNBRQKpnbrqk";

static void board_to_tensor(const char *fen, float *tensor) {
    memset(tensor, 0, TENSOR_SIZE * sizeof(float));

    const char *p = fen;
    /* Parse piece placement */
    for (int fen_rank = 0; fen_rank < 8; fen_rank++) {
        int row = 7 - fen_rank;
        int file = 0;
        while (*p && *p != '/' && *p != ' ') {
            if (*p >= '1' && *p <= '8') {
                file += *p - '0';
            } else {
                const char *idx = strchr(PIECE_CHARS, *p);
                if (idx) {
                    int ch = (int)(idx - PIECE_CHARS);
                    tensor[ch * 64 + row * 8 + file] = 1.0f;
                }
                file++;
            }
            p++;
        }
        if (*p == '/') p++;
    }

    /* Skip to active color field */
    while (*p == ' ') p++;
    char active = *p++;

    /* Channel 12: turn */
    float turn_val = (active == 'w') ? 1.0f : 0.0f;
    for (int i = 0; i < 64; i++)
        tensor[12 * 64 + i] = turn_val;

    /* Skip to castling field */
    while (*p == ' ') p++;
    const char *castling_start = p;
    while (*p && *p != ' ') p++;

    /* Channels 13-16: castling rights */
    const char rights[] = "KQkq";
    for (int i = 0; i < 4; i++) {
        if (memchr(castling_start, rights[i], p - castling_start)) {
            int ch_start = (13 + i) * 64;
            for (int j = 0; j < 64; j++)
                tensor[ch_start + j] = 1.0f;
        }
    }

    /* Skip to en-passant field */
    while (*p == ' ') p++;

    /* Channel 17: en-passant */
    if (*p != '-' && *p >= 'a' && *p <= 'h') {
        int ep_file = *p - 'a'; p++;
        if (*p >= '1' && *p <= '8') {
            int ep_rank = *p - '1';
            int row = 7 - ep_rank;
            tensor[17 * 64 + row * 8 + ep_file] = 1.0f;
        }
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
 *  Softmax over masked logits (matches Flutter _processLogits)
 * ═══════════════════════════════════════════════════════════════════════ */

typedef struct { int index; double prob; } IndexProb;

static int cmp_prob_desc(const void *a, const void *b) {
    double da = ((const IndexProb *)a)->prob;
    double db = ((const IndexProb *)b)->prob;
    return (db > da) - (db < da);
}

static int masked_softmax(const float *logits, const float *mask, int n,
                          IndexProb *out, int max_out) {
    /* Collect legal logits */
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

    /* Softmax */
    double sum = 0.0;
    double probs[256];
    for (int i = 0; i < count; i++) {
        probs[i] = exp(legal_logits[i] - max_logit);
        sum += probs[i];
    }
    for (int i = 0; i < count; i++)
        probs[i] /= sum;

    /* Build output array */
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
    fprintf(stderr, "Maia model loaded: %s\n", model_path);
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

    /* 1. Board tensor [1, 18, 8, 8] */
    float board_tensor[TENSOR_SIZE];
    board_to_tensor(processed_fen, board_tensor);

    /* 2. Elo categories */
    int64_t elo_self_cat = elo_to_category(elo);
    int64_t elo_oppo_cat = elo_self_cat;

    /* 3. Legal-move mask (on the processed/mirrored FEN) */
    float legal_mask[MAIA_VOCAB_SIZE];
    build_legal_mask(processed_fen, legal_mask);

    /* Create ONNX input tensors */
    const OrtApi *api = ctx->api;
    OrtStatus *status;

    int64_t board_shape[] = {1, 18, 8, 8};
    int64_t elo_shape[]   = {1};

    OrtValue *board_val = NULL, *elo_self_val = NULL, *elo_oppo_val = NULL;

    status = api->CreateTensorWithDataAsOrtValue(
        ctx->memory_info, board_tensor, sizeof(board_tensor),
        board_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &board_val);
    if (status) { api->ReleaseStatus(status); return false; }

    status = api->CreateTensorWithDataAsOrtValue(
        ctx->memory_info, &elo_self_cat, sizeof(int64_t),
        elo_shape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &elo_self_val);
    if (status) {
        api->ReleaseStatus(status);
        api->ReleaseValue(board_val);
        return false;
    }

    status = api->CreateTensorWithDataAsOrtValue(
        ctx->memory_info, &elo_oppo_cat, sizeof(int64_t),
        elo_shape, 1, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &elo_oppo_val);
    if (status) {
        api->ReleaseStatus(status);
        api->ReleaseValue(board_val);
        api->ReleaseValue(elo_self_val);
        return false;
    }

    /* Run inference */
    const char *input_names[]  = {"boards", "elo_self", "elo_oppo"};
    const char *output_names[] = {"logits_maia"};
    const OrtValue *inputs[]   = {board_val, elo_self_val, elo_oppo_val};
    OrtValue *output = NULL;

    status = api->Run(ctx->session, NULL,
                      input_names, inputs, 3,
                      output_names, 1, &output);

    api->ReleaseValue(board_val);
    api->ReleaseValue(elo_self_val);
    api->ReleaseValue(elo_oppo_val);

    if (status) {
        fprintf(stderr, "Maia: Run failed: %s\n", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return false;
    }

    /* Extract logits */
    float *logits = NULL;
    status = api->GetTensorMutableData(output, (void **)&logits);
    if (status || !logits) {
        if (status) api->ReleaseStatus(status);
        api->ReleaseValue(output);
        return false;
    }

    /* Softmax over legal moves */
    IndexProb ranked[MAIA_MAX_MOVES];
    int n = masked_softmax(logits, legal_mask, MAIA_VOCAB_SIZE,
                           ranked, MAIA_MAX_MOVES);

    api->ReleaseValue(output);

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
