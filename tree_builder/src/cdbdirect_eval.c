/**
 * cdbdirect_eval.c - see cdbdirect_eval.h
 */

#include "cdbdirect_eval.h"

#include <ctype.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef HAS_CDBDIRECT
extern void *cdbdirect_initialize(const char *path);
extern const char *cdbdirect_get(void *handle, const char *fen);
extern size_t cdbdirect_size(void *handle);
extern void cdbdirect_finalize(void *handle);
#endif

#define FEN_KEY_LEN 128
#define CACHE_BUCKETS 256
#define MAX_PREFETCH 64

typedef struct CacheEntry {
    char fen[FEN_KEY_LEN];
    int  eval_cp;
    int  depth;
    bool valid;
    struct CacheEntry *next;
} CacheEntry;

struct CdbDirectEval {
#ifdef HAS_CDBDIRECT
    void *handle;
#endif
    bool read_ahead_hint;
    CacheEntry *cache[CACHE_BUCKETS];
};

/* ---- Response parsing (always available) ---- */

static bool is_error_token(const char *s) {
    if (!s || !s[0]) return true;
    if (strcmp(s, "unknown") == 0) return true;
    if (strncmp(s, "error", 5) == 0) return true;
    if (strncmp(s, "invalid", 7) == 0) return true;
    return false;
}

static bool parse_score_token(const char *tok, int *out_cp) {
    if (!tok || !out_cp) return false;
    const char *p = tok;
    if (strncmp(p, "score:", 6) == 0) p += 6;
    else if (strncmp(p, "eval:", 5) == 0) p += 5;
    char *end = NULL;
    long v = strtol(p, &end, 10);
    if (end == p) return false;
    *out_cp = (int)v;
    return true;
}

static bool parse_simple_pair(const char *seg, int *out_cp, char *move_out,
                              size_t move_cap) {
    const char *colon = strchr(seg, ':');
    if (!colon) return false;
    if ((size_t)(colon - seg) >= move_cap) return false;
    memcpy(move_out, seg, (size_t)(colon - seg));
    move_out[colon - seg] = '\0';
    if (move_out[0] == '\0') return false;
    return parse_score_token(colon + 1, out_cp);
}

static bool parse_verbose_pair(const char *seg, int *out_cp, int *out_rank,
                               char *move_out, size_t move_cap) {
    *out_rank = 9999;
    bool have_score = false;
    bool have_move = false;

    char buf[512];
    snprintf(buf, sizeof(buf), "%s", seg);

    char *save = NULL;
    for (char *field = strtok_r(buf, ",", &save); field;
         field = strtok_r(NULL, ",", &save)) {
        if (strncmp(field, "move:", 5) == 0) {
            snprintf(move_out, move_cap, "%s", field + 5);
            have_move = move_out[0] != '\0';
        } else if (strncmp(field, "score:", 6) == 0) {
            have_score = parse_score_token(field, out_cp);
        } else if (strncmp(field, "rank:", 5) == 0) {
            *out_rank = atoi(field + 5);
        }
    }
    return have_move && have_score;
}

bool cdbdirect_parse_response(const char *response, int *out_eval_cp,
                              int *out_depth, char *out_best_move,
                              size_t best_move_cap) {
    if (out_eval_cp) *out_eval_cp = 0;
    if (out_depth) *out_depth = 0;
    if (out_best_move && best_move_cap > 0) out_best_move[0] = '\0';

    if (!response || !response[0]) return false;
    if (is_error_token(response)) return false;

    /* Single eval: eval:42 */
    if (strncmp(response, "eval:", 5) == 0 && strchr(response, '|') == NULL) {
        int cp = 0;
        if (!parse_score_token(response, &cp)) return false;
        if (out_eval_cp) *out_eval_cp = cp;
        if (out_depth) *out_depth = 20;
        return true;
    }

    char work[4096];
    snprintf(work, sizeof(work), "%s", response);

    int best_cp = 0;
    int best_rank = 9999;
    char best_move[8] = {0};
    bool found = false;

    char *save = NULL;
    for (char *seg = strtok_r(work, "|", &save); seg; seg = strtok_r(NULL, "|", &save)) {
        while (*seg == ' ') seg++;
        if (!seg[0] || is_error_token(seg)) continue;

        int cp = 0, rank = 0;
        char move[8] = {0};
        bool ok = false;

        if (strstr(seg, "move:") != NULL || strstr(seg, "score:") != NULL) {
            ok = parse_verbose_pair(seg, &cp, &rank, move, sizeof(move));
        } else {
            ok = parse_simple_pair(seg, &cp, move, sizeof(move));
            rank = found ? best_rank + 1 : 0;
        }

        if (!ok) continue;

        if (!found || rank < best_rank || (rank == best_rank && !found)) {
            best_cp = cp;
            best_rank = rank;
            snprintf(best_move, sizeof(best_move), "%s", move);
            found = true;
        } else if (!found) {
            best_cp = cp;
            snprintf(best_move, sizeof(best_move), "%s", move);
            found = true;
        } else if (rank == best_rank) {
            /* keep first at same rank */
        }
    }

    if (!found) return false;
    if (out_eval_cp) *out_eval_cp = best_cp;
    if (out_depth) *out_depth = 20;
    if (out_best_move && best_move_cap > 0)
        snprintf(out_best_move, best_move_cap, "%s", best_move);
    return true;
}

bool cdbdirect_validate_data_dir(const char *path) {
    if (!path || !path[0]) return false;
    if (access(path, R_OK) != 0) return false;

    /* TerarkDB directories contain CURRENT, LOCK, or *.sst files */
    static const char *markers[] = {"CURRENT", "LOCK", NULL};
    for (int i = 0; markers[i]; i++) {
        char probe[PATH_MAX];
        snprintf(probe, sizeof(probe), "%s/%s", path, markers[i]);
        if (access(probe, F_OK) == 0) return true;
    }

    /* Fallback: any non-empty directory (dump may use nested layout) */
    char nested[PATH_MAX];
    snprintf(nested, sizeof(nested), "%s/data", path);
    if (access(nested, R_OK) == 0) {
        for (int i = 0; markers[i]; i++) {
            char probe[PATH_MAX];
            snprintf(probe, sizeof(probe), "%s/%s", nested, markers[i]);
            if (access(probe, F_OK) == 0) return true;
        }
    }
    return false;
}

#ifndef HAS_CDBDIRECT

CdbDirectEval *cdbdirect_eval_open(const char *path, bool read_ahead_hint) {
    (void)path;
    (void)read_ahead_hint;
    return NULL;
}

void cdbdirect_eval_close(CdbDirectEval *h) { free(h); }

long cdbdirect_eval_count(CdbDirectEval *h) {
    (void)h;
    return -1;
}

void cdbdirect_eval_lookup_result(CdbDirectEval *h, const char *fen,
                                  int min_depth, EvalLookupResult *out) {
    (void)h;
    (void)fen;
    (void)min_depth;
    eval_lookup_result_clear(out);
    out->hard_miss = true;
}

EvalSource *cdbdirect_eval_as_source(CdbDirectEval *h) {
    (void)h;
    return NULL;
}

void cdbdirect_eval_prefetch(CdbDirectEval *h, const char **fens, size_t count) {
    (void)h;
    (void)fens;
    (void)count;
}

#else /* HAS_CDBDIRECT */

static unsigned cache_hash(const char *fen) {
    unsigned h = 2166136261u;
    for (const char *p = fen; *p; p++) {
        h ^= (unsigned char)*p;
        h *= 16777619u;
    }
    return h % CACHE_BUCKETS;
}

static CacheEntry *cache_find(CdbDirectEval *h, const char *fen) {
    unsigned idx = cache_hash(fen);
    for (CacheEntry *e = h->cache[idx]; e; e = e->next) {
        if (strcmp(e->fen, fen) == 0) return e;
    }
    return NULL;
}

static void cache_put(CdbDirectEval *h, const char *fen, int cp, int depth,
                      bool valid) {
    unsigned idx = cache_hash(fen);
    CacheEntry *e = cache_find(h, fen);
    if (!e) {
        e = calloc(1, sizeof(*e));
        if (!e) return;
        snprintf(e->fen, sizeof(e->fen), "%s", fen);
        e->next = h->cache[idx];
        h->cache[idx] = e;
    }
    e->eval_cp = cp;
    e->depth = depth;
    e->valid = valid;
}

static int fen_cmp(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void cdbdirect_source_lookup(void *ctx, const char *fen, int min_depth,
                                    EvalLookupResult *out);

static void cdbdirect_source_close(void *ctx) { (void)ctx; }

CdbDirectEval *cdbdirect_eval_open(const char *path, bool read_ahead_hint) {
    if (!path || !path[0]) return NULL;
    if (!cdbdirect_validate_data_dir(path)) {
        fprintf(stderr, "cdbdirect_eval: data directory not found or invalid: %s\n",
                path);
        return NULL;
    }

    void *handle = cdbdirect_initialize(path);
    if (!handle) {
        fprintf(stderr, "cdbdirect_eval: cdbdirect_initialize failed for %s\n",
                path);
        return NULL;
    }

    CdbDirectEval *h = calloc(1, sizeof(*h));
    if (!h) {
        cdbdirect_finalize(handle);
        return NULL;
    }
    h->handle = handle;
    h->read_ahead_hint = read_ahead_hint;
    if (read_ahead_hint) {
        fprintf(stderr,
                "cdbdirect_eval: read-ahead hint enabled (HDD: prefer batch lookups)\n");
    }

    size_t n = cdbdirect_size(handle);
    fprintf(stderr, "cdbdirect_eval: opened %s (%zu positions)\n", path, n);
    return h;
}

void cdbdirect_eval_close(CdbDirectEval *h) {
    if (!h) return;
    for (size_t i = 0; i < CACHE_BUCKETS; i++) {
        CacheEntry *e = h->cache[i];
        while (e) {
            CacheEntry *next = e->next;
            free(e);
            e = next;
        }
    }
    if (h->handle) cdbdirect_finalize(h->handle);
    free(h);
}

long cdbdirect_eval_count(CdbDirectEval *h) {
    if (!h || !h->handle) return -1;
    return (long)cdbdirect_size(h->handle);
}

static void lookup_impl(CdbDirectEval *h, const char *fen, int min_depth,
                        EvalLookupResult *out) {
    eval_lookup_result_clear(out);
    if (!h || !h->handle || !fen) {
        out->hard_miss = true;
        return;
    }

    char key[FEN_KEY_LEN];
    snprintf(key, sizeof(key), "%s", fen);
    eval_canonicalize_fen(key);

    CacheEntry *cached = cache_find(h, key);
    if (cached) {
        if (!cached->valid) {
            out->hard_miss = true;
            return;
        }
        out->found = true;
        out->eval_cp = cached->eval_cp;
        out->depth = cached->depth;
        if (cached->depth < min_depth) out->shallow = true;
        return;
    }

    const char *resp = cdbdirect_get(h->handle, key);
    if (!resp || !resp[0] || is_error_token(resp)) {
        cache_put(h, key, 0, 0, false);
        out->hard_miss = true;
        return;
    }

    int cp = 0, depth = 0;
    char move[8];
    if (!cdbdirect_parse_response(resp, &cp, &depth, move, sizeof(move))) {
        cache_put(h, key, 0, 0, false);
        out->hard_miss = true;
        return;
    }

    cache_put(h, key, cp, depth, true);
    out->found = true;
    out->eval_cp = cp;
    out->depth = depth;
    if (depth < min_depth) out->shallow = true;
}

void cdbdirect_eval_lookup_result(CdbDirectEval *h, const char *fen,
                                  int min_depth, EvalLookupResult *out) {
    lookup_impl(h, fen, min_depth, out);
}

static void cdbdirect_source_lookup(void *ctx, const char *fen, int min_depth,
                                    EvalLookupResult *out) {
    lookup_impl((CdbDirectEval *)ctx, fen, min_depth, out);
}

EvalSource *cdbdirect_eval_as_source(CdbDirectEval *h) {
    if (!h) return NULL;
    EvalSource *src = calloc(1, sizeof(*src));
    if (!src) return NULL;
    src->ctx = h;
    src->lookup = cdbdirect_source_lookup;
    src->close_fn = cdbdirect_source_close;
    return src;
}

void cdbdirect_eval_prefetch(CdbDirectEval *h, const char **fens, size_t count) {
    if (!h || !h->handle || !fens || count == 0) return;
    if (count > MAX_PREFETCH) count = MAX_PREFETCH;

    const char *sorted[MAX_PREFETCH];
    char keys[MAX_PREFETCH][FEN_KEY_LEN];
    size_t n = 0;

    for (size_t i = 0; i < count; i++) {
        if (!fens[i]) continue;
        snprintf(keys[n], FEN_KEY_LEN, "%s", fens[i]);
        eval_canonicalize_fen(keys[n]);
        if (cache_find(h, keys[n])) continue;
        sorted[n] = keys[n];
        n++;
    }
    if (n <= 1) {
        if (n == 1) {
            EvalLookupResult r;
            lookup_impl(h, sorted[0], 0, &r);
        }
        return;
    }

    qsort(sorted, n, sizeof(sorted[0]), fen_cmp);
    for (size_t i = 0; i < n; i++) {
        EvalLookupResult r;
        lookup_impl(h, sorted[i], 0, &r);
    }
}

#endif /* HAS_CDBDIRECT */
