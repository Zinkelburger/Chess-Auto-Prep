/**
 * engine_pool.h - Multithreaded Stockfish Engine Pool
 * 
 * Manages a pool of Stockfish processes for parallel position evaluation.
 * Each engine runs in its own thread with pipe-based IPC.
 * 
 * Typical usage:
 *   EnginePool *pool = engine_pool_create("./stockfish", 4, 25);
 *   
 *   // Single evaluation
 *   int eval;
 *   engine_pool_evaluate(pool, fen, &eval);
 *   
 *   // Batch evaluation (parallel)
 *   EvalJob jobs[100];
 *   // ... fill in jobs[i].fen ...
 *   engine_pool_evaluate_batch(pool, jobs, 100);
 *   // Results in jobs[i].eval_cp, jobs[i].success
 *   
 *   engine_pool_destroy(pool);
 */

#ifndef ENGINE_POOL_H
#define ENGINE_POOL_H

#include <stdbool.h>
#include <stddef.h>

/* Maximum FEN length for eval jobs */
#define MAX_EVAL_FEN_LENGTH 128

/* Forward declaration */
typedef struct EnginePool EnginePool;

/**
 * Evaluation job for batch processing
 */
typedef struct EvalJob {
    char fen[MAX_EVAL_FEN_LENGTH];  /* Input: position to evaluate */
    int eval_cp;                     /* Output: centipawn evaluation */
    int depth_reached;               /* Output: actual depth reached */
    char bestmove[16];               /* Output: best move in UCI */
    char pv[256];                    /* Output: principal variation */
    bool is_mate;                    /* Output: score is mate, not cp */
    int mate_in;                     /* Output: mate in N moves */
    bool success;                    /* Output: evaluation succeeded */
} EvalJob;

/**
 * MultiPV evaluation results
 */
#define MAX_MULTIPV 16

typedef struct {
    char move_uci[16];              /* Move in UCI notation */
    int eval_cp;                     /* Centipawn evaluation (from root STM) */
    bool is_mate;
    int mate_in;
    int depth_reached;
} MultiPVLine;

typedef struct {
    char fen[MAX_EVAL_FEN_LENGTH];   /* Input: position evaluated */
    MultiPVLine lines[MAX_MULTIPV];  /* Output: top N lines */
    int num_lines;                   /* Output: actual lines returned */
    bool success;
} MultiPVJob;

/**
 * Engine pool statistics
 */
typedef struct {
    int total_evaluations;
    int failed_evaluations;
    double total_eval_time_ms;
    double avg_eval_time_ms;
    int num_engines;
} EnginePoolStats;


/**
 * Create an engine pool
 * 
 * Spawns num_engines Stockfish processes, each ready for UCI.
 * 
 * @param stockfish_path Path to the Stockfish binary
 * @param num_engines Number of parallel engines (recommend: CPU cores - 1)
 * @param default_depth Default search depth (e.g., 25)
 * @param sf_threads Stockfish threads per engine (0 or 1 = single-threaded)
 * @return Engine pool, or NULL on failure
 */
EnginePool* engine_pool_create(const char *stockfish_path, int num_engines, 
                                int default_depth, int sf_threads);

/**
 * Destroy the engine pool
 * Terminates all Stockfish processes.
 * 
 * @param pool The pool to destroy
 */
void engine_pool_destroy(EnginePool *pool);

/**
 * Evaluate a single position
 * 
 * Blocks until evaluation is complete.
 * 
 * @param pool The engine pool
 * @param fen Position FEN
 * @param eval_cp Output: centipawn evaluation (positive = white advantage)
 * @return true on success
 */
bool engine_pool_evaluate(EnginePool *pool, const char *fen, int *eval_cp);

/**
 * Evaluate a single position with full results
 * 
 * @param pool The engine pool
 * @param fen Position FEN
 * @param job Output: full evaluation results
 * @return true on success
 */
bool engine_pool_evaluate_full(EnginePool *pool, const char *fen, EvalJob *job);

/**
 * Evaluate a position with MultiPV (multiple best moves)
 * 
 * Returns the top num_pvs moves with their evaluations.
 * Evals are from the side-to-move's perspective.
 * 
 * @param pool The engine pool
 * @param fen Position FEN
 * @param depth Search depth
 * @param num_pvs Number of principal variations (1-16)
 * @param job Output: MultiPV results
 * @return true on success
 */
bool engine_pool_evaluate_multipv(EnginePool *pool, const char *fen,
                                   int depth, int num_pvs, MultiPVJob *job);

/**
 * Evaluate a batch of positions in parallel
 * 
 * Distributes work across all engines. Blocks until all complete.
 * 
 * @param pool The engine pool
 * @param jobs Array of evaluation jobs (fen must be filled in)
 * @param num_jobs Number of jobs
 * @param progress_callback Optional callback for progress (can be NULL)
 * @param user_data User data for callback
 * @return Number of successful evaluations
 */
int engine_pool_evaluate_batch(EnginePool *pool, EvalJob *jobs, int num_jobs,
                                void (*progress_callback)(int completed, int total, void *ud),
                                void *user_data);

/**
 * Set the search depth for subsequent evaluations
 * 
 * @param pool The engine pool
 * @param depth New depth
 */
void engine_pool_set_depth(EnginePool *pool, int depth);

/**
 * Set hash table size for all engines (in MB)
 * 
 * @param pool The engine pool
 * @param hash_mb Hash size in megabytes
 */
void engine_pool_set_hash(EnginePool *pool, int hash_mb);

/**
 * Get pool statistics
 * 
 * @param pool The engine pool
 * @param stats Output statistics
 */
void engine_pool_get_stats(const EnginePool *pool, EnginePoolStats *stats);

#endif /* ENGINE_POOL_H */
