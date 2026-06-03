/**
 * fen_map.h - Hash map from 4-field FEN key to TreeNode*
 *
 * Used for transposition detection during tree builds.  Keys strip the
 * halfmove/fullmove counters so positions differing only by move counters
 * still collide.
 */

#ifndef FEN_MAP_H
#define FEN_MAP_H

#include "node.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define FEN_KEY_MAX_LENGTH MAX_FEN_LENGTH

typedef struct FenMapEntry {
    char *fen;
    TreeNode *node;
    struct FenMapEntry *next;
} FenMapEntry;

typedef struct FenMap {
    FenMapEntry **buckets;
    size_t num_buckets;
    size_t count;
} FenMap;

/** Strip move counters from FEN — keep board, side, castling, EP only. */
void fen_map_canonicalize_key(const char *fen, char *out, size_t out_len);

FenMap *fen_map_create(void);
void fen_map_destroy(FenMap *map);

/** Look up the canonical node for a FEN.  Returns NULL if not present. */
TreeNode *fen_map_get(const FenMap *map, const char *fen);

/** Insert a FEN → node mapping.  No-op if the FEN is already present. */
bool fen_map_put(FenMap *map, const char *fen, TreeNode *node);

#endif /* FEN_MAP_H */
