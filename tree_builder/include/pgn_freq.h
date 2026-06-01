/**
 * pgn_freq.h - PGN frequency map for DB-seeded repertoire building
 *
 * Parses standard PGN files and accumulates per-position move frequencies
 * keyed by 4-field canonical FEN.
 */

#ifndef PGN_FREQ_H
#define PGN_FREQ_H

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

#endif /* PGN_FREQ_H */
