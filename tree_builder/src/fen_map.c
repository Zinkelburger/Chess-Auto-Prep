/**
 * fen_map.c - Hash map from 4-field FEN key to TreeNode*
 */

#include "fen_map.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define FEN_MAP_INITIAL_BUCKETS 4096
#define FEN_MAP_LOAD_FACTOR     0.75

static uint32_t fen_hash(const char *fen, size_t num_buckets) {
    uint32_t hash = 2166136261u;
    for (const char *p = fen; *p; p++) {
        hash ^= (uint8_t)*p;
        hash *= 16777619u;
    }
    return hash % (uint32_t)num_buckets;
}

void fen_map_canonicalize_key(const char *fen, char *out, size_t out_len) {
    if (!out || out_len == 0) return;
    if (!fen) {
        out[0] = '\0';
        return;
    }

    snprintf(out, out_len, "%s", fen);
    int spaces = 0;
    for (char *p = out; *p; p++) {
        if (*p == ' ' && ++spaces == 4) {
            *p = '\0';
            return;
        }
    }
}

static void fen_map_resize(FenMap *map) {
    size_t new_buckets = map->num_buckets * 2;
    FenMapEntry **new_table =
        (FenMapEntry **)calloc(new_buckets, sizeof(FenMapEntry *));
    if (!new_table) return;
    for (size_t i = 0; i < map->num_buckets; i++) {
        FenMapEntry *e = map->buckets[i];
        while (e) {
            FenMapEntry *next = e->next;
            uint32_t idx = fen_hash(e->fen, new_buckets);
            e->next = new_table[idx];
            new_table[idx] = e;
            e = next;
        }
    }
    free(map->buckets);
    map->buckets = new_table;
    map->num_buckets = new_buckets;
}

FenMap *fen_map_create(void) {
    FenMap *map = (FenMap *)calloc(1, sizeof(FenMap));
    if (!map) return NULL;
    map->num_buckets = FEN_MAP_INITIAL_BUCKETS;
    map->buckets = (FenMapEntry **)calloc(map->num_buckets, sizeof(FenMapEntry *));
    if (!map->buckets) {
        free(map);
        return NULL;
    }
    return map;
}

void fen_map_destroy(FenMap *map) {
    if (!map) return;
    for (size_t i = 0; i < map->num_buckets; i++) {
        FenMapEntry *e = map->buckets[i];
        while (e) {
            FenMapEntry *next = e->next;
            free(e->fen);
            free(e);
            e = next;
        }
    }
    free(map->buckets);
    free(map);
}

TreeNode *fen_map_get(const FenMap *map, const char *fen) {
    if (!map) return NULL;
    char key[FEN_KEY_MAX_LENGTH];
    fen_map_canonicalize_key(fen, key, sizeof(key));
    uint32_t idx = fen_hash(key, map->num_buckets);
    for (FenMapEntry *e = map->buckets[idx]; e; e = e->next) {
        if (strcmp(e->fen, key) == 0) return e->node;
    }
    return NULL;
}

void fen_map_put(FenMap *map, const char *fen, TreeNode *node) {
    if (!map || !fen) return;

    char key[FEN_KEY_MAX_LENGTH];
    fen_map_canonicalize_key(fen, key, sizeof(key));
    if (!key[0]) return;
    if (fen_map_get(map, key)) return;
    if ((double)map->count / (double)map->num_buckets >= FEN_MAP_LOAD_FACTOR)
        fen_map_resize(map);
    uint32_t idx = fen_hash(key, map->num_buckets);
    FenMapEntry *e = (FenMapEntry *)malloc(sizeof(FenMapEntry));
    if (!e) return;
    e->fen = strdup(key);
    if (!e->fen) {
        free(e);
        return;
    }
    e->node = node;
    e->next = map->buckets[idx];
    map->buckets[idx] = e;
    map->count++;
}
