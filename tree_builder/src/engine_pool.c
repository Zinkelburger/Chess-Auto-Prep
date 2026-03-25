/**
 * engine_pool.c - Multithreaded Stockfish Engine Pool
 * 
 * Spawns multiple Stockfish processes using pipe/fork/exec.
 * Each engine is managed by its own thread for parallel evaluation.
 * Uses a mutex-protected job queue for work distribution.
 */

#include "engine_pool.h"
#include "thread_pool.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <pthread.h>
#include <time.h>

/* Maximum line length from Stockfish output */
#define MAX_ENGINE_LINE 4096

/* Timeout for engine response (seconds) */
#define ENGINE_TIMEOUT_SEC 120


/**
 * Single Stockfish engine instance
 */
typedef struct {
    pid_t pid;              /* Stockfish process ID */
    int stdin_fd;           /* Pipe to write commands */
    int stdout_fd;          /* Pipe to read responses */
    FILE *stdin_fp;         /* FILE wrapper for stdin pipe */
    FILE *stdout_fp;        /* FILE wrapper for stdout pipe */
    bool is_ready;          /* Engine has responded to 'isready' */
    bool is_alive;          /* Process is running */
    int id;                 /* Engine index */
    pthread_mutex_t lock;   /* Per-engine lock */
} StockfishEngine;


/**
 * Engine pool
 */
struct EnginePool {
    StockfishEngine *engines;
    int num_engines;
    int default_depth;
    int hash_mb;
    char stockfish_path[512];
    
    /* Thread pool for batch jobs */
    ThreadPool *thread_pool;
    
    /* Statistics */
    int total_evaluations;
    int failed_evaluations;
    double total_eval_time_ms;
    pthread_mutex_t stats_lock;
    
    /* Engine allocation */
    pthread_mutex_t alloc_lock;
    pthread_cond_t engine_available;
    bool *engine_in_use;        /* Which engines are currently in use */
};


/* ========== Engine Process Management ========== */

/**
 * Spawn a Stockfish process with bidirectional pipes
 */
static bool spawn_engine(StockfishEngine *eng, const char *path) {
    int stdin_pipe[2];   /* Parent writes to [1], child reads from [0] */
    int stdout_pipe[2];  /* Child writes to [1], parent reads from [0] */
    
    if (pipe(stdin_pipe) == -1 || pipe(stdout_pipe) == -1) {
        perror("pipe");
        return false;
    }
    
    pid_t pid = fork();
    if (pid == -1) {
        perror("fork");
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        return false;
    }
    
    if (pid == 0) {
        /* Child process */
        close(stdin_pipe[1]);   /* Close write end of stdin pipe */
        close(stdout_pipe[0]);  /* Close read end of stdout pipe */
        
        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stdout_pipe[1], STDERR_FILENO);
        
        close(stdin_pipe[0]);
        close(stdout_pipe[1]);
        
        execl(path, path, NULL);
        
        /* If exec fails */
        perror("execl");
        _exit(1);
    }
    
    /* Parent process */
    close(stdin_pipe[0]);   /* Close read end of stdin pipe */
    close(stdout_pipe[1]);  /* Close write end of stdout pipe */
    
    eng->pid = pid;
    eng->stdin_fd = stdin_pipe[1];
    eng->stdout_fd = stdout_pipe[0];
    eng->stdin_fp = fdopen(eng->stdin_fd, "w");
    eng->stdout_fp = fdopen(eng->stdout_fd, "r");
    eng->is_alive = true;
    eng->is_ready = false;
    
    if (!eng->stdin_fp || !eng->stdout_fp) {
        fprintf(stderr, "Failed to fdopen engine pipes\n");
        kill(pid, SIGTERM);
        return false;
    }
    
    /* Disable buffering for immediate command delivery and correct select() behavior.
       stdout must also be unbuffered so fgets() doesn't cache data that select() can't see. */
    setvbuf(eng->stdin_fp, NULL, _IONBF, 0);
    setvbuf(eng->stdout_fp, NULL, _IONBF, 0);
    
    return true;
}


/**
 * Send a command to the engine
 */
static void engine_send(StockfishEngine *eng, const char *cmd) {
    if (!eng || !eng->is_alive || !eng->stdin_fp) return;
    fprintf(eng->stdin_fp, "%s\n", cmd);
    fflush(eng->stdin_fp);
}


/**
 * Read a line from the engine (blocking, with timeout)
 * Returns NULL on timeout or error.
 */
static char* engine_readline(StockfishEngine *eng, char *buf, size_t buf_size) {
    if (!eng || !eng->is_alive || !eng->stdout_fp) return NULL;
    
    /* Use select() for timeout */
    fd_set fds;
    struct timeval tv;
    
    FD_ZERO(&fds);
    FD_SET(eng->stdout_fd, &fds);
    tv.tv_sec = ENGINE_TIMEOUT_SEC;
    tv.tv_usec = 0;
    
    int ret = select(eng->stdout_fd + 1, &fds, NULL, NULL, &tv);
    if (ret <= 0) {
        return NULL; /* Timeout or error */
    }
    
    if (fgets(buf, buf_size, eng->stdout_fp)) {
        /* Strip trailing newline */
        size_t len = strlen(buf);
        while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r')) {
            buf[--len] = '\0';
        }
        return buf;
    }
    
    return NULL;
}


/**
 * Initialize UCI protocol and wait for readyok
 */
static bool engine_init_uci(StockfishEngine *eng, int hash_mb) {
    char buf[MAX_ENGINE_LINE];
    
    /* Send UCI init */
    engine_send(eng, "uci");
    
    /* Wait for 'uciok' */
    while (engine_readline(eng, buf, sizeof(buf))) {
        if (strstr(buf, "uciok")) break;
    }
    
    /* Configure engine */
    char cmd[256];
    
    if (hash_mb > 0) {
        snprintf(cmd, sizeof(cmd), "setoption name Hash value %d", hash_mb);
        engine_send(eng, cmd);
    }
    
    /* Set single thread per engine (pool handles parallelism) */
    engine_send(eng, "setoption name Threads value 1");
    
    /* Enable UCI_ShowWDL for win/draw/loss info */
    engine_send(eng, "setoption name UCI_ShowWDL value true");
    
    /* Send isready and wait */
    engine_send(eng, "isready");
    
    while (engine_readline(eng, buf, sizeof(buf))) {
        if (strstr(buf, "readyok")) {
            eng->is_ready = true;
            return true;
        }
    }
    
    return false;
}


/**
 * Kill an engine process
 */
static void engine_kill(StockfishEngine *eng) {
    if (!eng || !eng->is_alive) return;
    
    engine_send(eng, "quit");
    
    /* Give it a moment to quit gracefully */
    usleep(100000); /* 100ms */
    
    if (eng->stdin_fp) fclose(eng->stdin_fp);
    if (eng->stdout_fp) fclose(eng->stdout_fp);
    eng->stdin_fp = NULL;
    eng->stdout_fp = NULL;
    
    /* Force kill if still running */
    int status;
    pid_t result = waitpid(eng->pid, &status, WNOHANG);
    if (result == 0) {
        kill(eng->pid, SIGKILL);
        waitpid(eng->pid, &status, 0);
    }
    
    eng->is_alive = false;
}


/* ========== Engine Pool ========== */

EnginePool* engine_pool_create(const char *stockfish_path, int num_engines, 
                                int default_depth) {
    if (!stockfish_path || num_engines <= 0) return NULL;
    
    /* Verify Stockfish binary exists */
    if (access(stockfish_path, X_OK) != 0) {
        fprintf(stderr, "Error: Stockfish not found or not executable: %s\n", stockfish_path);
        return NULL;
    }
    
    EnginePool *pool = (EnginePool *)calloc(1, sizeof(EnginePool));
    if (!pool) return NULL;
    
    strncpy(pool->stockfish_path, stockfish_path, sizeof(pool->stockfish_path) - 1);
    pool->num_engines = num_engines;
    pool->default_depth = default_depth;
    pool->hash_mb = 64; /* Default 64MB hash per engine */
    
    pthread_mutex_init(&pool->stats_lock, NULL);
    pthread_mutex_init(&pool->alloc_lock, NULL);
    pthread_cond_init(&pool->engine_available, NULL);
    
    /* Allocate engine tracking arrays */
    pool->engines = (StockfishEngine *)calloc(num_engines, sizeof(StockfishEngine));
    pool->engine_in_use = (bool *)calloc(num_engines, sizeof(bool));
    
    if (!pool->engines || !pool->engine_in_use) {
        free(pool->engines);
        free(pool->engine_in_use);
        free(pool);
        return NULL;
    }
    
    /* Spawn and initialize each engine */
    int engines_started = 0;
    for (int i = 0; i < num_engines; i++) {
        pool->engines[i].id = i;
        pthread_mutex_init(&pool->engines[i].lock, NULL);
        
        printf("  Starting Stockfish engine %d/%d...\n", i + 1, num_engines);
        
        if (!spawn_engine(&pool->engines[i], stockfish_path)) {
            fprintf(stderr, "  Warning: Failed to start engine %d\n", i);
            continue;
        }
        
        if (!engine_init_uci(&pool->engines[i], pool->hash_mb)) {
            fprintf(stderr, "  Warning: Engine %d failed UCI init\n", i);
            engine_kill(&pool->engines[i]);
            continue;
        }
        
        engines_started++;
    }
    
    if (engines_started == 0) {
        fprintf(stderr, "Error: No engines started successfully\n");
        free(pool->engines);
        free(pool->engine_in_use);
        free(pool);
        return NULL;
    }
    
    printf("  %d/%d Stockfish engines ready (depth %d)\n", 
           engines_started, num_engines, default_depth);
    
    /* Create thread pool for batch evaluation */
    pool->thread_pool = thread_pool_create(num_engines);
    
    return pool;
}


void engine_pool_destroy(EnginePool *pool) {
    if (!pool) return;
    
    /* Destroy thread pool first */
    if (pool->thread_pool) {
        thread_pool_destroy(pool->thread_pool);
    }
    
    /* Kill all engines */
    for (int i = 0; i < pool->num_engines; i++) {
        engine_kill(&pool->engines[i]);
        pthread_mutex_destroy(&pool->engines[i].lock);
    }
    
    pthread_mutex_destroy(&pool->stats_lock);
    pthread_mutex_destroy(&pool->alloc_lock);
    pthread_cond_destroy(&pool->engine_available);
    
    free(pool->engines);
    free(pool->engine_in_use);
    free(pool);
}


/**
 * Acquire an idle engine (blocks until one is available)
 */
static int acquire_engine(EnginePool *pool) {
    pthread_mutex_lock(&pool->alloc_lock);
    
    while (1) {
        for (int i = 0; i < pool->num_engines; i++) {
            if (!pool->engine_in_use[i] && pool->engines[i].is_alive && pool->engines[i].is_ready) {
                pool->engine_in_use[i] = true;
                pthread_mutex_unlock(&pool->alloc_lock);
                return i;
            }
        }
        /* All engines busy, wait */
        pthread_cond_wait(&pool->engine_available, &pool->alloc_lock);
    }
}


/**
 * Release an engine back to the pool
 */
static void release_engine(EnginePool *pool, int idx) {
    pthread_mutex_lock(&pool->alloc_lock);
    pool->engine_in_use[idx] = false;
    pthread_cond_signal(&pool->engine_available);
    pthread_mutex_unlock(&pool->alloc_lock);
}


/**
 * Parse a UCI 'info' line for score and PV
 */
static void parse_info_line(const char *line, EvalJob *job) {
    const char *p;
    
    /* Parse depth */
    p = strstr(line, "depth ");
    if (p) {
        job->depth_reached = atoi(p + 6);
    }
    
    /* Parse score */
    p = strstr(line, "score ");
    if (p) {
        p += 6;
        if (strncmp(p, "cp ", 3) == 0) {
            job->eval_cp = atoi(p + 3);
            job->is_mate = false;
        } else if (strncmp(p, "mate ", 5) == 0) {
            job->mate_in = atoi(p + 5);
            job->is_mate = true;
            /* Convert mate to large cp value for sorting */
            job->eval_cp = job->mate_in > 0 ? (10000 - job->mate_in) : (-10000 - job->mate_in);
        }
    }
    
    /* Parse PV */
    p = strstr(line, " pv ");
    if (p) {
        p += 4;
        strncpy(job->pv, p, sizeof(job->pv) - 1);
    }
}


/**
 * Evaluate a position on a specific engine
 */
static bool evaluate_on_engine(StockfishEngine *eng, const char *fen, 
                                int depth, EvalJob *job) {
    char buf[MAX_ENGINE_LINE];
    char cmd[512];
    
    pthread_mutex_lock(&eng->lock);
    
    /* Clear previous state */
    engine_send(eng, "ucinewgame");
    engine_send(eng, "isready");
    
    /* Wait for readyok */
    while (engine_readline(eng, buf, sizeof(buf))) {
        if (strstr(buf, "readyok")) break;
    }
    
    /* Set position and start search */
    snprintf(cmd, sizeof(cmd), "position fen %s", fen);
    engine_send(eng, cmd);
    
    snprintf(cmd, sizeof(cmd), "go depth %d", depth);
    engine_send(eng, cmd);
    
    /* Read output until bestmove */
    job->success = false;
    memset(job->bestmove, 0, sizeof(job->bestmove));
    memset(job->pv, 0, sizeof(job->pv));
    
    while (engine_readline(eng, buf, sizeof(buf))) {
        if (strncmp(buf, "info ", 5) == 0) {
            /* Only parse info lines with score (skip early low-depth lines) */
            if (strstr(buf, "score ")) {
                /* Check it's not a secondary PV line (multipv) */
                const char *mpv = strstr(buf, "multipv ");
                if (!mpv || atoi(mpv + 8) == 1) {
                    parse_info_line(buf, job);
                }
            }
        } else if (strncmp(buf, "bestmove ", 9) == 0) {
            /* Extract bestmove */
            const char *bm = buf + 9;
            const char *space = strchr(bm, ' ');
            size_t len = space ? (size_t)(space - bm) : strlen(bm);
            if (len < sizeof(job->bestmove)) {
                strncpy(job->bestmove, bm, len);
                job->bestmove[len] = '\0';
            }
            job->success = true;
            break;
        }
    }
    
    pthread_mutex_unlock(&eng->lock);
    
    return job->success;
}


/**
 * Evaluate a position with MultiPV on a specific engine.
 * Sets MultiPV before the search and resets it to 1 afterward.
 */
static bool evaluate_multipv_on_engine(StockfishEngine *eng, const char *fen,
                                        int depth, int num_pvs, MultiPVJob *job) {
    char buf[MAX_ENGINE_LINE];
    char cmd[512];

    if (num_pvs < 1) num_pvs = 1;
    if (num_pvs > MAX_MULTIPV) num_pvs = MAX_MULTIPV;

    pthread_mutex_lock(&eng->lock);

    snprintf(cmd, sizeof(cmd), "setoption name MultiPV value %d", num_pvs);
    engine_send(eng, cmd);

    engine_send(eng, "ucinewgame");
    engine_send(eng, "isready");
    while (engine_readline(eng, buf, sizeof(buf))) {
        if (strstr(buf, "readyok")) break;
    }

    snprintf(cmd, sizeof(cmd), "position fen %s", fen);
    engine_send(eng, cmd);

    snprintf(cmd, sizeof(cmd), "go depth %d", depth);
    engine_send(eng, cmd);

    memset(job->lines, 0, sizeof(job->lines));
    job->num_lines = 0;
    job->success = false;

    while (engine_readline(eng, buf, sizeof(buf))) {
        if (strncmp(buf, "info ", 5) == 0 && strstr(buf, "score ")) {
            int pv_idx = 0;
            const char *mpv = strstr(buf, "multipv ");
            if (mpv) pv_idx = atoi(mpv + 8) - 1;

            if (pv_idx >= 0 && pv_idx < num_pvs) {
                MultiPVLine *line = &job->lines[pv_idx];
                const char *p;

                p = strstr(buf, "depth ");
                if (p) line->depth_reached = atoi(p + 6);

                p = strstr(buf, "score ");
                if (p) {
                    p += 6;
                    if (strncmp(p, "cp ", 3) == 0) {
                        line->eval_cp = atoi(p + 3);
                        line->is_mate = false;
                    } else if (strncmp(p, "mate ", 5) == 0) {
                        line->mate_in = atoi(p + 5);
                        line->is_mate = true;
                        line->eval_cp = line->mate_in > 0
                            ? (10000 - line->mate_in)
                            : (-10000 - line->mate_in);
                    }
                }

                p = strstr(buf, " pv ");
                if (p) {
                    p += 4;
                    const char *space = strchr(p, ' ');
                    size_t len = space ? (size_t)(space - p) : strlen(p);
                    if (len < sizeof(line->move_uci)) {
                        memcpy(line->move_uci, p, len);
                        line->move_uci[len] = '\0';
                    }
                }

                if (pv_idx >= job->num_lines)
                    job->num_lines = pv_idx + 1;
            }
        } else if (strncmp(buf, "bestmove ", 9) == 0) {
            job->success = true;
            break;
        }
    }

    /* Reset MultiPV to 1 */
    engine_send(eng, "setoption name MultiPV value 1");
    engine_send(eng, "isready");
    while (engine_readline(eng, buf, sizeof(buf))) {
        if (strstr(buf, "readyok")) break;
    }

    pthread_mutex_unlock(&eng->lock);
    return job->success;
}


/* ========== Public API ========== */

bool engine_pool_evaluate(EnginePool *pool, const char *fen, int *eval_cp) {
    EvalJob job;
    bool result = engine_pool_evaluate_full(pool, fen, &job);
    if (result && eval_cp) {
        *eval_cp = job.eval_cp;
    }
    return result;
}


bool engine_pool_evaluate_full(EnginePool *pool, const char *fen, EvalJob *job) {
    if (!pool || !fen || !job) return false;
    
    memset(job, 0, sizeof(EvalJob));
    strncpy(job->fen, fen, MAX_EVAL_FEN_LENGTH - 1);
    
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    
    /* Acquire an engine */
    int eng_idx = acquire_engine(pool);
    
    /* Evaluate */
    bool success = evaluate_on_engine(&pool->engines[eng_idx], fen, 
                                       pool->default_depth, job);
    
    /* Release engine */
    release_engine(pool, eng_idx);
    
    /* Update stats */
    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed_ms = (end.tv_sec - start.tv_sec) * 1000.0 + 
                         (end.tv_nsec - start.tv_nsec) / 1000000.0;
    
    pthread_mutex_lock(&pool->stats_lock);
    pool->total_evaluations++;
    if (!success) pool->failed_evaluations++;
    pool->total_eval_time_ms += elapsed_ms;
    pthread_mutex_unlock(&pool->stats_lock);
    
    return success;
}


bool engine_pool_evaluate_multipv(EnginePool *pool, const char *fen,
                                   int depth, int num_pvs, MultiPVJob *job) {
    if (!pool || !fen || !job || num_pvs < 1) return false;
    if (num_pvs > MAX_MULTIPV) num_pvs = MAX_MULTIPV;

    memset(job, 0, sizeof(MultiPVJob));
    strncpy(job->fen, fen, MAX_EVAL_FEN_LENGTH - 1);

    int eng_idx = acquire_engine(pool);
    bool success = evaluate_multipv_on_engine(&pool->engines[eng_idx], fen,
                                               depth, num_pvs, job);
    release_engine(pool, eng_idx);

    pthread_mutex_lock(&pool->stats_lock);
    pool->total_evaluations++;
    if (!success) pool->failed_evaluations++;
    pthread_mutex_unlock(&pool->stats_lock);

    return success;
}


/* Batch evaluation task argument */
typedef struct {
    EnginePool *pool;
    EvalJob *job;
    void (*progress_callback)(int completed, int total, void *ud);
    void *user_data;
    int *completed_count;
    int total_count;
    pthread_mutex_t *progress_lock;
} BatchTaskArg;


static void batch_eval_task(void *arg) {
    BatchTaskArg *bta = (BatchTaskArg *)arg;
    
    int eng_idx = acquire_engine(bta->pool);
    
    evaluate_on_engine(&bta->pool->engines[eng_idx], bta->job->fen,
                        bta->pool->default_depth, bta->job);
    
    release_engine(bta->pool, eng_idx);
    
    /* Update progress */
    if (bta->progress_callback && bta->progress_lock) {
        pthread_mutex_lock(bta->progress_lock);
        (*bta->completed_count)++;
        int completed = *bta->completed_count;
        pthread_mutex_unlock(bta->progress_lock);
        
        bta->progress_callback(completed, bta->total_count, bta->user_data);
    }
    
    /* Update pool stats */
    pthread_mutex_lock(&bta->pool->stats_lock);
    bta->pool->total_evaluations++;
    if (!bta->job->success) bta->pool->failed_evaluations++;
    pthread_mutex_unlock(&bta->pool->stats_lock);
    
    free(bta);
}


int engine_pool_evaluate_batch(EnginePool *pool, EvalJob *jobs, int num_jobs,
                                void (*progress_callback)(int completed, int total, void *ud),
                                void *user_data) {
    if (!pool || !jobs || num_jobs <= 0) return 0;
    
    int completed_count = 0;
    pthread_mutex_t progress_lock;
    pthread_mutex_init(&progress_lock, NULL);
    
    /* Submit all jobs to thread pool */
    for (int i = 0; i < num_jobs; i++) {
        BatchTaskArg *bta = (BatchTaskArg *)malloc(sizeof(BatchTaskArg));
        if (!bta) continue;
        
        bta->pool = pool;
        bta->job = &jobs[i];
        bta->progress_callback = progress_callback;
        bta->user_data = user_data;
        bta->completed_count = &completed_count;
        bta->total_count = num_jobs;
        bta->progress_lock = &progress_lock;
        
        thread_pool_submit(pool->thread_pool, batch_eval_task, bta);
    }
    
    /* Wait for all to complete */
    thread_pool_wait(pool->thread_pool);
    
    pthread_mutex_destroy(&progress_lock);
    
    /* Count successes */
    int successes = 0;
    for (int i = 0; i < num_jobs; i++) {
        if (jobs[i].success) successes++;
    }
    
    return successes;
}


void engine_pool_set_depth(EnginePool *pool, int depth) {
    if (pool && depth > 0) {
        pool->default_depth = depth;
    }
}


void engine_pool_set_hash(EnginePool *pool, int hash_mb) {
    if (!pool || hash_mb <= 0) return;
    
    pool->hash_mb = hash_mb;
    
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "setoption name Hash value %d", hash_mb);
    
    for (int i = 0; i < pool->num_engines; i++) {
        if (pool->engines[i].is_alive) {
            pthread_mutex_lock(&pool->engines[i].lock);
            engine_send(&pool->engines[i], cmd);
            pthread_mutex_unlock(&pool->engines[i].lock);
        }
    }
}


void engine_pool_get_stats(const EnginePool *pool, EnginePoolStats *stats) {
    if (!pool || !stats) return;
    
    /* Cast away const for mutex (stats are read-only conceptually) */
    pthread_mutex_lock((pthread_mutex_t *)&pool->stats_lock);
    
    stats->total_evaluations = pool->total_evaluations;
    stats->failed_evaluations = pool->failed_evaluations;
    stats->total_eval_time_ms = pool->total_eval_time_ms;
    stats->avg_eval_time_ms = pool->total_evaluations > 0 ? 
        pool->total_eval_time_ms / pool->total_evaluations : 0;
    stats->num_engines = pool->num_engines;
    
    pthread_mutex_unlock((pthread_mutex_t *)&pool->stats_lock);
}
