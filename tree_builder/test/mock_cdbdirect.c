/**
 * mock_cdbdirect.c - In-memory stub for cdbdirect (unit tests without TerarkDB).
 *
 * Implements the 4-function C API expected by cdbdirect_eval.c.
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_ENTRIES 32
#define RESP_LEN 512

typedef struct MockEntry {
    char fen[128];
    char response[RESP_LEN];
} MockEntry;

typedef struct MockHandle {
    MockEntry entries[MAX_ENTRIES];
    size_t count;
} MockHandle;

static void canonicalize_fen(char *fen) {
    if (!fen) return;
    int spaces = 0;
    for (char *p = fen; *p; p++) {
        if (*p == ' ' && ++spaces == 4) {
            *p = '\0';
            return;
        }
    }
}

static MockHandle *seed_handle(void) {
    MockHandle *h = calloc(1, sizeof(*h));
    if (!h) return NULL;

    static const struct {
        const char *fen;
        const char *resp;
    } seed[] = {
        {"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
         "move:e2e4,score:30,rank:0,note:,winrate:0.515|move:d2d4,score:25,rank:1,note:,winrate:0.512"},
        {"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
         "e2e4:25|d2d4:20"},
        {"rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1",
         "move:d2d4,score:18,rank:0,note:,winrate:0.51"},
        {"rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 1",
         "move:c2c3,score:30,rank:0,note:,winrate:0.52|move:g1f3,score:28,rank:1"},
        {"rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
         "move:d2d4,score:-10,rank:0,note:,winrate:0.48"},
        {"rnbqkb1r/pppppppp/5n2/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2",
         "move:b1c3,score:12,rank:0,note:,winrate:0.505"},
        {"r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4",
         "eval:9996"},
        {"rnbqkbnr/pppppppp/8/8/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 0 2",
         "move:e7e5,score:5,rank:0,note:,winrate:0.50"},
        {"rnbqkbnr/pppppppp/8/8/8/4N3/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
         "move:d7d5,score:8,rank:0,note:,winrate:0.51"},
        {"rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq - 0 1",
         "move:c7c5,score:22,rank:0,note:,winrate:0.515"},
    };

    for (size_t i = 0; i < sizeof(seed) / sizeof(seed[0]) && i < MAX_ENTRIES; i++) {
        snprintf(h->entries[i].fen, sizeof(h->entries[i].fen), "%s", seed[i].fen);
        canonicalize_fen(h->entries[i].fen);
        snprintf(h->entries[i].response, sizeof(h->entries[i].response),
                 "%s", seed[i].resp);
        h->count++;
    }
    return h;
}

void *cdbdirect_initialize(const char *path) {
    if (!path || !path[0]) return NULL;
    (void)path;
    return seed_handle();
}

const char *cdbdirect_get(void *handle, const char *fen) {
    MockHandle *h = (MockHandle *)handle;
    if (!h || !fen) return NULL;

    char key[128];
    snprintf(key, sizeof(key), "%s", fen);
    canonicalize_fen(key);

    for (size_t i = 0; i < h->count; i++) {
        if (strcmp(h->entries[i].fen, key) == 0)
            return h->entries[i].response;
    }
    return NULL;
}

size_t cdbdirect_size(void *handle) {
    MockHandle *h = (MockHandle *)handle;
    return h ? h->count : 0;
}

void cdbdirect_finalize(void *handle) {
    free(handle);
}
