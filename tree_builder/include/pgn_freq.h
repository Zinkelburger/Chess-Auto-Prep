/**
 * pgn_freq.h - PGN frequency map for DB-seeded repertoire building
 *
 * Parses standard PGN files and accumulates per-position move frequencies
 * keyed by 4-field canonical FEN.
 */

#ifndef PGN_FREQ_H
#define PGN_FREQ_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct PgnFreqMove {
    char uci[8];
    char san[16];
    uint64_t count;
} PgnFreqMove;

typedef struct PgnFreqPosition {
    char fen_key[128];
    uint64_t reach_count;
    PgnFreqMove *moves;
    int move_count;
    int move_capacity;
} PgnFreqPosition;

typedef struct PgnFreqMap PgnFreqMap;

typedef struct PgnFreqConfig {
    const char *start_fen;    /* NULL = standard startpos */
    const char *start_moves;  /* SAN prefix before tracking (NULL = from start) */
    int max_ply;              /* 0 = unlimited ply from tracking root */
    int min_elo;              /* skip game if both players below this (0 = off) */
} PgnFreqConfig;

PgnFreqMap *pgn_freq_map_create(void);
void pgn_freq_map_destroy(PgnFreqMap *map);

/** Parse PGN files, merge into map. Returns number of games successfully parsed. */
int pgn_freq_load_file(PgnFreqMap *map, const PgnFreqConfig *cfg, const char *path);

/** Lookup a position by FEN (canonicalized internally). */
const PgnFreqPosition *pgn_freq_get(const PgnFreqMap *map, const char *fen);

void pgn_freq_stats(const PgnFreqMap *map, size_t *out_positions,
                    uint64_t *out_total_games);

/** Filter moves by min_games AND min_prob; return count written to out_moves. */
int pgn_freq_filtered_moves(const PgnFreqPosition *pos, int min_games,
                            double min_prob, PgnFreqMove *out_moves,
                            int max_out);

/** Merge src into dst (sum reach_count and move counts). Returns false on OOM. */
bool pgn_freq_map_merge(PgnFreqMap *dst, const PgnFreqMap *src);

/** Binary cache format version (manifest JSON field format_version). */
#define PGN_FREQ_CACHE_FORMAT_VERSION 1

/**
 * Save map to path. manifest_json is stored in the file header for reload checks.
 * Returns false on I/O or allocation failure.
 */
bool pgn_freq_map_save(const PgnFreqMap *map, const char *path,
                       const char *manifest_json);

/**
 * Load map from path if manifest_json matches the file header.
 * Returns NULL if missing, manifest mismatch, or corrupt data.
 */
PgnFreqMap *pgn_freq_map_load(const char *path, const char *expected_manifest_json);

#endif /* PGN_FREQ_H */
