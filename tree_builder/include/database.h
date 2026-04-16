/**
 * database.h - SQLite3 Persistent Storage for Repertoire Builder
 * 
 * Caches Lichess API responses, engine evaluations, ease scores,
 * and repertoire selections. Makes the build process resumable
 * and dramatically faster on subsequent runs.
 * 
 * SQLite3 is ideal here because:
 * - Single file, portable (share the .db with Flutter app)
 * - Supports concurrent reads (WAL mode)
 * - No server required
 * - Millions of positions with indexed FEN lookups
 * - Cross-language (C, Dart, Python all have SQLite bindings)
 */

#ifndef DATABASE_H
#define DATABASE_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/* Forward declarations */
typedef struct RepertoireDB RepertoireDB;

/**
 * Cached position data from the database
 */
typedef struct {
    char fen[128];
    
    /* Engine evaluation */
    int eval_cp;
    int eval_depth;
    bool has_eval;
    
    /* Ease score */
    double ease;
    bool has_ease;
    
    /* Lichess statistics */
    uint64_t white_wins;
    uint64_t black_wins;
    uint64_t draws;
    uint64_t total_games;
    
    /* Opening info */
    char opening_eco[8];
    char opening_name[128];
    
} CachedPosition;


/**
 * Cached Lichess explorer move
 */
typedef struct {
    char uci[16];
    char san[16];
    uint64_t white_wins;
    uint64_t black_wins;
    uint64_t draws;
    double probability;
} CachedExplorerMove;

/**
 * Cached Lichess explorer response
 */
typedef struct {
    CachedExplorerMove moves[64];
    size_t move_count;
    uint64_t total_games;
    char opening_eco[8];
    char opening_name[128];
    bool found;  /* Was this FEN in the cache? */
} CachedExplorerResponse;


/**
 * Open or create the repertoire database
 * 
 * @param path Path to the SQLite database file
 * @return Database handle, or NULL on failure
 */
RepertoireDB* rdb_open(const char *path);

/**
 * Close the database
 * 
 * @param db Database handle
 */
void rdb_close(RepertoireDB *db);

/**
 * Begin a transaction (for batch inserts)
 */
void rdb_begin_transaction(RepertoireDB *db);

/**
 * Commit a transaction
 */
void rdb_commit_transaction(RepertoireDB *db);


/* ========== Lichess Explorer Cache ========== */

/**
 * Get cached Lichess explorer response
 * 
 * @param db Database handle
 * @param fen Position FEN
 * @param out Output response
 * @return true if found in cache
 */
bool rdb_get_explorer_cache(RepertoireDB *db, const char *fen, 
                             CachedExplorerResponse *out);

/**
 * Store Lichess explorer response in cache
 * 
 * @param db Database handle
 * @param fen Position FEN
 * @param moves Array of moves
 * @param move_count Number of moves
 * @param total_games Total games in position
 * @param opening_eco ECO code (can be NULL)
 * @param opening_name Opening name (can be NULL)
 */
void rdb_put_explorer_cache(RepertoireDB *db, const char *fen,
                             const CachedExplorerMove *moves, size_t move_count,
                             uint64_t total_games,
                             const char *opening_eco, const char *opening_name);


/* ========== Engine Evaluations ========== */

/**
 * Get cached engine evaluation
 * 
 * @param db Database handle
 * @param fen Position FEN
 * @param eval_cp Output: evaluation in centipawns
 * @param depth Output: search depth
 * @return true if found
 */
bool rdb_get_eval(RepertoireDB *db, const char *fen, int *eval_cp, int *depth);

/**
 * Store engine evaluation
 * 
 * @param db Database handle
 * @param fen Position FEN
 * @param eval_cp Evaluation in centipawns
 * @param depth Search depth
 */
void rdb_put_eval(RepertoireDB *db, const char *fen, int eval_cp, int depth);


/* ========== MultiPV Cache ========== */

#include "engine_pool.h"

/**
 * Get cached MultiPV result.
 * Returns true if a cached result with depth >= requested depth
 * and num_pvs >= requested count exists.
 */
bool rdb_get_multipv(RepertoireDB *db, const char *fen, int depth,
                     int num_pvs, MultiPVJob *out);

/**
 * Store a MultiPV result in the cache.
 */
void rdb_put_multipv(RepertoireDB *db, const char *fen, int depth,
                     int num_pvs, const MultiPVJob *job);


/* ========== Maia Policy Cache ==========
 *
 * Maia inference is deterministic for a fixed (fen, elo, model), so its
 * output can be cached exactly like a Stockfish eval.  Without this the
 * policy head is re-run on every opponent node on every resume, which
 * is a large fraction of total build time for long runs.
 *
 * The cache does NOT include a model-version key — deleting the DB is
 * the supported way to force regeneration after swapping Maia weights.
 */

/** One cached Maia move prediction (matches MaiaMove layout). */
typedef struct {
    char uci[8];
    double probability;
} CachedMaiaMove;

/**
 * Look up a cached Maia response for (fen, elo).
 *
 * @param db            Database handle
 * @param fen           Position FEN
 * @param elo           Elo the prediction was taken at
 * @param out_moves     Output buffer
 * @param max_moves     Capacity of out_moves
 * @param out_count     Output: number of moves written
 * @return true if found; false on miss (out_count set to 0)
 */
bool rdb_get_maia(RepertoireDB *db, const char *fen, int elo,
                  CachedMaiaMove *out_moves, int max_moves, int *out_count);

/**
 * Store a Maia response under (fen, elo).
 */
void rdb_put_maia(RepertoireDB *db, const char *fen, int elo,
                  const CachedMaiaMove *moves, int move_count);


/* ========== Ease Scores ========== */

/**
 * Get cached ease score
 * 
 * @param db Database handle
 * @param fen Position FEN
 * @param ease Output: ease score
 * @return true if found
 */
bool rdb_get_ease(RepertoireDB *db, const char *fen, double *ease);

/**
 * Store ease score
 */
void rdb_put_ease(RepertoireDB *db, const char *fen, double ease);


/* ========== Repertoire Selections ========== */

/**
 * Save a repertoire move selection
 * 
 * @param db Database handle
 * @param fen Position FEN
 * @param move_san SAN of the selected move
 * @param move_uci UCI of the selected move
 * @param score Composite repertoire score
 */
void rdb_save_repertoire_move(RepertoireDB *db, const char *fen,
                               const char *move_san, const char *move_uci,
                               double score);

/**
 * Get all repertoire selections
 * 
 * @param db Database handle
 * @param callback Called for each selection
 * @param user_data Passed to callback
 */
void rdb_get_repertoire_moves(RepertoireDB *db,
                               void (*callback)(const char *fen, const char *move_san,
                                                const char *move_uci, double score,
                                                void *user_data),
                               void *user_data);


/* ========== Statistics ========== */

/**
 * Get database statistics
 * 
 * @param db Database handle
 * @param explorer_cached Output: number of cached explorer responses
 * @param evals_cached Output: number of cached evaluations
 * @param ease_cached Output: number of cached ease scores
 */
void rdb_get_stats(RepertoireDB *db, int *explorer_cached, 
                    int *evals_cached, int *ease_cached);

#endif /* DATABASE_H */
