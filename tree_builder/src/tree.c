/**
 * tree.c - Opening Tree Implementation
 *
 * Single interleaved BFS (FIFO queue).  At our-move nodes Stockfish
 * MultiPV finds candidates and the eval-loss filter prunes immediately.
 * At opponent-move nodes we use exactly one distribution source — Maia's
 * policy head (default) or the Lichess explorer — with no blending,
 * no renormalization, and a tail term in the expectimax pass to
 * account for uncovered probability mass.  Branching budgets are
 * stable across the tree: non-root our-move nodes use the configured
 * `our_multipv`, the root widens to at least 10 lines so the opening
 * position can try more offbeat ideas, and opponent-side caps
 * (`opp_mass_target`, `opp_max_children`) stay constant at every depth.
 * A smaller action space at deeper plies would make MAX
 * monotonically under-estimate our achievable V (fewer candidates
 * can only lower the max), and would similarly truncate the CHANCE
 * sum toward the eval-based tail — both pushing V systematically
 * lower at depth.  Keeping the budgets constant sidesteps this;
 * natural depth termination comes from `min_probability`,
 * `max_depth`, and the eval window instead.
 *
 * Evaluation is split between the two node types so we never run
 * Stockfish twice on the same FEN:
 *   - Opponent-move nodes need an eval ONLY for the window-prune check
 *     (Maia/Lichess provide the policy, not a score).  That eval is
 *     the single-PV `ensure_eval` in `build_process_node`.
 *   - Our-move nodes run MultiPV for candidate generation anyway, so
 *     the node's own eval is taken from MultiPV line 0 and the window
 *     check is deferred into `build_our_move` (after MultiPV).  This
 *     avoids the previously-redundant pattern of "single-PV to gate
 *     MultiPV" on the same position.
 *
 * Maia policy outputs are cached in the DB keyed by (fen, elo) so
 * resumed builds don't re-run ONNX inference on positions that were
 * already expanded in an earlier session.
 */

#include "tree.h"
#include "repertoire.h"
#include "lichess_api.h"
#include "chess_logic.h"
#include "san_convert.h"
#include "engine_pool.h"
#include "database.h"
#include "maia.h"
#include "lichess_eval_db.h"
#include "chessdb_eval_db.h"
#include "chessdb_api.h"
#include "cdbdirect_eval.h"
#include "eval_chain.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <time.h>
#include <stdarg.h>
#include <limits.h>

#define BUILD_PROGRESS_MAX_DEPTH 128

static int g_nodes_created_at_depth[BUILD_PROGRESS_MAX_DEPTH];
static int g_nodes_processed_at_depth[BUILD_PROGRESS_MAX_DEPTH];


/* ========== Instrumentation helpers ========== */

static double elapsed_ms(const struct timespec *start) {
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &end);
    return (end.tv_sec - start->tv_sec) * 1000.0 +
           (end.tv_nsec - start->tv_nsec) / 1e6;
}

#define STATS_INC(cfg, field)  do { if ((cfg)->stats) (cfg)->stats->field++; } while(0)
#define STATS_ADD(cfg, field, v) do { if ((cfg)->stats) (cfg)->stats->field += (v); } while(0)

#define ROOT_MULTIPV_FLOOR 10

static int multipv_count_for_node(const TreeConfig *config, const TreeNode *node) {
    if (!config) return ROOT_MULTIPV_FLOOR;
    if (node && node->depth == 0 && config->our_multipv < ROOT_MULTIPV_FLOOR)
        return ROOT_MULTIPV_FLOOR;
    return config->our_multipv;
}


/* ========== Event log ========== */

static double event_T(const TreeConfig *cfg) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - cfg->event_log_epoch.tv_sec) * 1000.0
         + (now.tv_nsec - cfg->event_log_epoch.tv_nsec) / 1e6;
}

/**
 * Write one TSV line to the event log.
 *   T_ms  event  depth  node_type  detail...
 * node_type: "our", "opp", or "-" when unknown/irrelevant.
 */
__attribute__((format(printf, 5, 6)))
static void emit_event(const TreeConfig *cfg, const char *event,
                        int depth, const char *node_type,
                        const char *fmt, ...) {
    if (!cfg->event_log) return;
    fprintf(cfg->event_log, "%.1f\t%s\t%d\t%s\t", event_T(cfg),
            event, depth, node_type);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(cfg->event_log, fmt, ap);
    va_end(ap);
    fputc('\n', cfg->event_log);
}


/* ========== FEN Map (transposition table — canonical FEN → TreeNode*) ========== */

#define FEN_MAP_INITIAL_BUCKETS 4096
#define FEN_MAP_LOAD_FACTOR     0.75

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

/* Use a 4-field FEN key so move counters do not block transposition hits. */
static void canonicalize_fen_key(const char *fen, char *out, size_t out_len) {
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

static uint32_t fen_hash(const char *fen, size_t num_buckets) {
    uint32_t hash = 2166136261u;
    for (const char *p = fen; *p; p++) {
        hash ^= (uint8_t)*p;
        hash *= 16777619u;
    }
    return hash % (uint32_t)num_buckets;
}

static FenMap *fen_map_create(void) {
    FenMap *map = (FenMap *)calloc(1, sizeof(FenMap));
    if (!map) return NULL;
    map->num_buckets = FEN_MAP_INITIAL_BUCKETS;
    map->buckets = (FenMapEntry **)calloc(map->num_buckets, sizeof(FenMapEntry *));
    if (!map->buckets) { free(map); return NULL; }
    return map;
}

static void fen_map_destroy(FenMap *map) {
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

static void fen_map_resize(FenMap *map) {
    size_t new_buckets = map->num_buckets * 2;
    FenMapEntry **new_table = (FenMapEntry **)calloc(new_buckets, sizeof(FenMapEntry *));
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

/** Look up the canonical node for a FEN.  Returns NULL if not present. */
static TreeNode *fen_map_get(const FenMap *map, const char *fen) {
    if (!map) return NULL;
    char key[MAX_FEN_LENGTH];
    canonicalize_fen_key(fen, key, sizeof(key));
    uint32_t idx = fen_hash(key, map->num_buckets);
    for (FenMapEntry *e = map->buckets[idx]; e; e = e->next) {
        if (strcmp(e->fen, key) == 0) return e->node;
    }
    return NULL;
}

/** Insert a FEN → node mapping.  No-op if the FEN is already present. */
static void fen_map_put(FenMap *map, const char *fen, TreeNode *node) {
    if (!map) return;

    char key[MAX_FEN_LENGTH];
    canonicalize_fen_key(fen, key, sizeof(key));
    if (fen_map_get(map, key)) return;
    if ((double)map->count / (double)map->num_buckets >= FEN_MAP_LOAD_FACTOR)
        fen_map_resize(map);
    uint32_t idx = fen_hash(key, map->num_buckets);
    FenMapEntry *e = (FenMapEntry *)malloc(sizeof(FenMapEntry));
    if (!e) return;
    e->fen = strdup(key);
    e->node = node;
    e->next = map->buckets[idx];
    map->buckets[idx] = e;
    map->count++;
}




TreeConfig tree_config_default(void) {
    TreeConfig config = {
        .play_as_white = true,
        .build_mode = BUILD_MODE_STOCKFISH_EXPECTIMAX,
        .min_probability = 0.0001,
        .max_depth = 20,
        .max_nodes = 0,

        .engine_pool = NULL,
        .db = NULL,
        .eval_depth = 14,

        .our_multipv = 5,
        .max_eval_loss_cp = 50,

        .opp_max_children = 6,
        .opp_mass_target = 0.95,

        .min_eval_cp = 0,
        .max_eval_cp = 200,
        .relative_eval = true,

        .rating_range = "2000,2200,2500",
        .speeds = "blitz,rapid,classical",
        .min_games = 10,
        .use_masters = false,

        .maia = NULL,
        .maia_elo = 2200,
        .maia_min_prob = 0.05,
        .maia_only = true,  /* default matches main.c and docs; fall back
                               to Lichess only if caller explicitly opts in */
        .populate_maia_frequency = true,  /* default on for back-compat;
                                             main.c turns this off when
                                             novelty scoring isn't used */
        .progress_callback = NULL,
        .progress_baseline_nodes = 0,
        .stats = NULL,
        .event_log = NULL,
        .event_log_epoch = {0, 0},
        .ext_eval_subtree_skip = true,
    };
    return config;
}


void tree_config_set_color_defaults(TreeConfig *config) {
    if (config->play_as_white) {
        config->min_eval_cp = 0;
        config->max_eval_cp = 200;
    } else {
        config->min_eval_cp = -200;
        config->max_eval_cp = 100;
    }
}


Tree* tree_create(void) {
    Tree *tree = (Tree *)calloc(1, sizeof(Tree));
    if (!tree) return NULL;

    tree->root = NULL;
    tree->config = tree_config_default();
    tree->total_nodes = 0;
    tree->max_depth_reached = 0;
    tree->is_building = false;
    tree->next_node_id = 1;

    return tree;
}


void tree_destroy(Tree *tree) {
    if (!tree) return;
    if (tree->root) node_destroy(tree->root);
    free(tree);
}


/* ========== Build helpers ========== */

/** Create a child node from a FEN, add it to the tree.
 *  Returns NULL (without adding) if a sibling with the same FEN
 *  already exists — this catches any move-representation mismatch
 *  that the UCI-level dedup might miss. */
static TreeNode *make_child(TreeNode *parent, const char *fen,
                             const char *san, const char *uci,
                             Tree *tree) {
    for (size_t i = 0; i < parent->children_count; i++) {
        if (strcmp(parent->children[i]->fen, fen) == 0)
            return NULL;
    }

    TreeNode *child = node_create(fen, san, uci, parent);
    if (!child) return NULL;
    if (!node_add_child(parent, child)) {
        node_destroy_single(child);
        return NULL;
    }
    tree->total_nodes++;
    if (child->depth < BUILD_PROGRESS_MAX_DEPTH)
        g_nodes_created_at_depth[child->depth]++;
    if (child->depth > tree->max_depth_reached)
        tree->max_depth_reached = child->depth;
    child->skip_ext_eval = parent->skip_ext_eval;
    return child;
}

/** Apply a UCI move to a FEN, write the resulting FEN into out_fen. */
static bool apply_uci(const char *fen, const char *uci,
                       char *out_fen, size_t out_len) {
    ChessPosition pos;
    if (!position_from_fen(&pos, fen)) return false;
    if (!position_apply_uci(&pos, uci)) return false;
    position_to_fen(&pos, out_fen, out_len);
    return true;
}

/**
 * Ensure a node has an engine evaluation.
 *
 * Source precedence (cheapest first):
 *   1. Project DB cache (from a previous build of this repertoire)
 *   2. cdbdirect TerarkDB full dump (if !skip_ext_eval, HAS_CDBDIRECT)
 *   3. ChessDB local SQLite (if !skip_ext_eval)
 *   4. Lichess community eval DB (if !skip_ext_eval)
 *   5. ChessDB API (if !skip_ext_eval && quota remaining)
 *   6. Stockfish single-PV at config->eval_depth
 *
 * A hit from an external source is written back to the project cache.
 * Local DB hard misses may mark the subtree to skip external sources.
 */
static EvalChainContext eval_chain_from_config(const TreeConfig *config) {
    EvalChainContext ctx = {
        .cdbdirect = config->cdbdirect,
        .chessdb_eval_db = config->chessdb_eval_db,
        .lichess_eval_db = config->lichess_eval_db,
        .chessdb_api = config->chessdb_api,
        .eval_depth = config->eval_depth,
        .ext_eval_subtree_skip = config->ext_eval_subtree_skip,
        .stats = config->stats,
    };
    return ctx;
}

/** Prefetch cdbdirect evals for newly created children (HDD locality). */
static void maybe_batch_prefetch_cdbdirect(const TreeConfig *config,
                                           TreeNode *node) {
    if (!config->batch_eval_lookups || !config->cdbdirect ||
        !node || node->children_count == 0)
        return;

    const char *fens[64];
    size_t n = 0;
    for (size_t i = 0; i < node->children_count && n < 64; i++) {
        if (node->children[i])
            fens[n++] = node->children[i]->fen;
    }
    if (n > 0)
        cdbdirect_eval_prefetch(config->cdbdirect, fens, n);
}

static bool lookup_db_eval_white(const TreeConfig *config, const char *fen,
                                 int *out_cp, int *out_depth) {
    if (config->db) {
        int cp, depth;
        if (rdb_get_eval(config->db, fen, &cp, &depth)) {
            *out_cp = cp;
            *out_depth = depth;
            return true;
        }
    }

    TreeNode stub;
    memset(&stub, 0, sizeof(stub));
    strncpy(stub.fen, fen, MAX_FEN_LENGTH - 1);

    EvalChainContext chain = eval_chain_from_config(config);
    const char *src = NULL;
    return eval_chain_try_external(&stub, &chain, out_cp, out_depth, &src);
}

static void ensure_eval(TreeNode *node, const TreeConfig *config) {
    if (node->has_engine_eval) return;

    /* Try DB cache — always, including transpositions off-book paths */
    if (config->db) {
        int cp, depth;
        if (rdb_get_eval(config->db, node->fen, &cp, &depth)) {
            STATS_INC(config, db_eval_hits);
            emit_event(config, "eval", node->depth, "-",
                       "src=db cp=%d depth=%d", cp, depth);
            node_set_eval(node, cp);
            return;
        }
        STATS_INC(config, db_eval_misses);
    }

    EvalChainContext chain = eval_chain_from_config(config);
    int cp = 0, depth = 0;
    const char *src = NULL;
    if (eval_chain_try_external(node, &chain, &cp, &depth, &src)) {
        emit_event(config, "eval", node->depth, "-",
                   "src=%s cp=%d depth=%d", src ? src : "ext", cp, depth);
        node_set_eval(node, cp);
        if (config->db)
            rdb_put_eval(config->db, node->fen, cp, depth);
        return;
    }

    if (config->build_mode == BUILD_MODE_MAIA_DB_EXPLORE)
        return;

    /* Run engine */
    if (config->engine_pool) {
        struct timespec t0;
        clock_gettime(CLOCK_MONOTONIC, &t0);

        EvalJob job;
        snprintf(job.fen, MAX_EVAL_FEN_LENGTH, "%s", node->fen);
        if (engine_pool_evaluate_full(config->engine_pool, node->fen, &job) &&
            job.success) {
            node_set_eval(node, job.eval_cp);
            if (config->db)
                rdb_put_eval(config->db, node->fen, job.eval_cp, job.depth_reached);
        }

        double ms = elapsed_ms(&t0);
        node->sf_ms += ms;
        STATS_INC(config, sf_single_calls);
        STATS_ADD(config, sf_single_ms, ms);
        emit_event(config, "eval", node->depth, "-",
                   "src=sf ms=%.1f cp=%d depth=%d",
                   ms, job.success ? job.eval_cp : 0,
                   job.success ? job.depth_reached : 0);
    }
}

/* NOTE: The former `batch_eval_children` helper was removed when opponent
 * nodes stopped pre-evaluating their children.  Its only caller was
 * `build_opponent_move`, and every child of an opponent node is an
 * our-move node whose `build_our_move` pass runs MultiPV on the same
 * FEN at the same depth — a strictly cheaper source of that eval.
 * Stats counters `sf_batch_calls` / `sf_batch_ms` are kept in
 * BuildStats for ABI stability but will now stay at zero. */


/* ========== Lichess query with DB caching ========== */

static bool query_lichess_cached(RepertoireDB *db, LichessExplorer *explorer,
                                  const char *fen, bool use_masters,
                                  ExplorerResponse *response,
                                  const TreeConfig *config,
                                  double *out_ms) {
    if (out_ms) *out_ms = 0.0;
    memset(response, 0, sizeof(*response));

    if (db) {
        CachedExplorerResponse cached;
        if (rdb_get_explorer_cache(db, fen, &cached) && cached.found) {
            STATS_INC(config, db_explorer_hits);
            STATS_INC(config, lichess_cache_hits);
            emit_event(config, "lichess", -1, "-",
                       "src=db moves=%zu", cached.move_count);

            response->success = true;
            response->move_count = cached.move_count;
            response->total_games = cached.total_games;
            snprintf(response->opening_eco, sizeof(response->opening_eco),
                     "%s", cached.opening_eco);
            snprintf(response->opening_name, sizeof(response->opening_name),
                     "%s", cached.opening_name);
            response->has_opening = (cached.opening_eco[0] != '\0');

            uint64_t tw = 0, tb = 0, td = 0;
            for (size_t i = 0; i < cached.move_count; i++) {
                ExplorerMove *m = &response->moves[i];
                strncpy(m->uci, cached.moves[i].uci, sizeof(m->uci) - 1);
                strncpy(m->san, cached.moves[i].san, sizeof(m->san) - 1);
                m->white_wins = cached.moves[i].white_wins;
                m->black_wins = cached.moves[i].black_wins;
                m->draws      = cached.moves[i].draws;
                m->probability = cached.moves[i].probability;
                tw += m->white_wins;
                tb += m->black_wins;
                td += m->draws;
            }
            response->total_white_wins = tw;
            response->total_black_wins = tb;
            response->total_draws      = td;
            return true;
        }
        STATS_INC(config, db_explorer_misses);
    }

    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    bool ok = use_masters
        ? lichess_explorer_query_masters(explorer, fen, response)
        : lichess_explorer_query(explorer, fen, response);

    double lich_ms = elapsed_ms(&t0);
    if (out_ms) *out_ms = lich_ms;
    STATS_INC(config, lichess_queries);
    STATS_ADD(config, lichess_total_ms, lich_ms);
    emit_event(config, "lichess", -1, "-",
               "src=api ms=%.1f ok=%d moves=%zu",
               lich_ms, ok && response->success ? 1 : 0,
               ok ? response->move_count : (size_t)0);

    if (ok && response->success && db) {
        CachedExplorerMove cmoves[MAX_EXPLORER_MOVES];
        for (size_t i = 0; i < response->move_count; i++) {
            memset(&cmoves[i], 0, sizeof(cmoves[i]));
            strncpy(cmoves[i].uci, response->moves[i].uci, sizeof(cmoves[i].uci) - 1);
            strncpy(cmoves[i].san, response->moves[i].san, sizeof(cmoves[i].san) - 1);
            cmoves[i].white_wins  = response->moves[i].white_wins;
            cmoves[i].black_wins  = response->moves[i].black_wins;
            cmoves[i].draws       = response->moves[i].draws;
            cmoves[i].probability = response->moves[i].probability;
        }
        rdb_put_explorer_cache(db, fen, cmoves, response->move_count,
                               response->total_games,
                               response->has_opening ? response->opening_eco : NULL,
                               response->has_opening ? response->opening_name : NULL);
    }

    return ok;
}


/* ========== Maia query with DB caching ========== */

/**
 * Run (or look up) Maia's policy head at (fen, elo).
 *
 * Fills `response` with a MaiaResponse containing moves sorted by probability.
 * The DB cache is checked first; on miss the ONNX model is invoked and the
 * result is written back to the cache.  Maia's `win_prob` is NOT cached — it
 * isn't used anywhere in the build path and re-running the model just to
 * recover it on a hit would defeat the point of caching.
 */
static bool query_maia_cached(const TreeConfig *config, const char *fen,
                              MaiaResponse *response, double *out_ms) {
    memset(response, 0, sizeof(*response));
    if (out_ms) *out_ms = 0.0;
    if (!config->maia) return false;

    /* Cache hit → build the response directly from DB rows. */
    if (config->db) {
        CachedMaiaMove cmoves[MAIA_MAX_MOVES];
        int count = 0;
        if (rdb_get_maia(config->db, fen, config->maia_elo,
                         cmoves, MAIA_MAX_MOVES, &count) && count > 0) {
            int n = count < MAIA_MAX_MOVES ? count : MAIA_MAX_MOVES;
            emit_event(config, "maia", -1, "-",
                       "src=db moves=%d", n);
            response->success = true;
            response->move_count = n;
            response->win_prob = 0.0;  /* not cached; unused in build */
            /* CachedMaiaMove and MaiaMove both use a fixed 8-byte uci
             * buffer; memcpy sidesteps a strncpy truncation warning and
             * preserves the null terminator that rdb_get_maia wrote. */
            for (int i = 0; i < n; i++) {
                memcpy(response->moves[i].uci, cmoves[i].uci, 8);
                response->moves[i].uci[7] = '\0';
                response->moves[i].probability = cmoves[i].probability;
            }
            return true;
        }
    }

    /* Cache miss → run the model, instrument, and persist the result. */
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    bool ok = maia_evaluate(config->maia, fen, config->maia_elo, response);

    double maia_ms_val = elapsed_ms(&t0);
    if (out_ms) *out_ms = maia_ms_val;
    STATS_INC(config, maia_evals);
    STATS_ADD(config, maia_total_ms, maia_ms_val);
    emit_event(config, "maia", -1, "-",
               "src=onnx ms=%.1f ok=%d moves=%d",
               maia_ms_val, ok && response->success ? 1 : 0,
               ok ? response->move_count : 0);

    if (ok && response->success && response->move_count > 0 && config->db) {
        CachedMaiaMove cmoves[MAIA_MAX_MOVES];
        int n = response->move_count;
        if (n > MAIA_MAX_MOVES) n = MAIA_MAX_MOVES;
        for (int i = 0; i < n; i++) {
            memset(&cmoves[i], 0, sizeof(cmoves[i]));
            memcpy(cmoves[i].uci, response->moves[i].uci, 8);
            cmoves[i].uci[7] = '\0';
            cmoves[i].probability = response->moves[i].probability;
        }
        rdb_put_maia(config->db, fen, config->maia_elo, cmoves, n);
    }
    return ok;
}


/* ========== Interleaved build (BFS queue) ========== */

typedef struct BuildQueue {
    TreeNode **buf;
    size_t head;
    size_t tail;
    size_t cap;
} BuildQueue;

static void build_queue_init(BuildQueue *q) {
    q->buf = NULL;
    q->head = 0;
    q->tail = 0;
    q->cap = 0;
}

static void build_queue_free(BuildQueue *q) {
    free(q->buf);
    build_queue_init(q);
}

static bool build_queue_push(BuildQueue *q, TreeNode *n) {
    if (q->tail >= q->cap) {
        size_t new_cap = q->cap ? q->cap * 2 : 256;
        TreeNode **nb = realloc(q->buf, new_cap * sizeof(TreeNode *));
        if (!nb) return false;
        q->buf = nb;
        q->cap = new_cap;
    }
    q->buf[q->tail++] = n;
    return true;
}

static TreeNode *build_queue_pop(BuildQueue *q) {
    for (;;) {
        if (q->head >= q->tail)
            return NULL;
        if (q->head > 1024 && q->head * 2 > q->tail) {
            size_t len = q->tail - q->head;
            memmove(q->buf, q->buf + q->head, len * sizeof(TreeNode *));
            q->head = 0;
            q->tail = len;
            continue;
        }
        return q->buf[q->head++];
    }
}

/**
 * On resume, register expanded FENs and enqueue only frontier leaves
 * (no children, not explored) instead of re-walking the full tree via BFS.
 *
 * Nodes with children but explored=false are partial expansions from an
 * interrupted build — enqueue the parent for re-expansion instead of
 * walking its (possibly incomplete) subtree.
 */
static void resume_prepare_frontier(TreeNode *node, FenMap *fmap,
                                    BuildQueue *q, size_t *frontier_count,
                                    int *min_frontier_depth) {
    if (!node) return;
    if (node->children_count > 0) {
        if (!node->explored) {
            if (build_queue_push(q, node)) {
                (*frontier_count)++;
                if (node->depth < *min_frontier_depth)
                    *min_frontier_depth = node->depth;
            }
            return;
        }
        fen_map_put(fmap, node->fen, node);
        for (size_t i = 0; i < node->children_count; i++)
            resume_prepare_frontier(node->children[i], fmap, q, frontier_count,
                                    min_frontier_depth);
        return;
    }
    if (!node->explored) {
        if (build_queue_push(q, node)) {
            (*frontier_count)++;
            if (node->depth < *min_frontier_depth)
                *min_frontier_depth = node->depth;
        }
    }
}

static int compare_node_depth(const void *a, const void *b) {
    const TreeNode *na = *(const TreeNode * const *)a;
    const TreeNode *nb = *(const TreeNode * const *)b;
    if (na->depth < nb->depth) return -1;
    if (na->depth > nb->depth) return 1;
    return 0;
}

/** Restore BFS level order after DFS frontier collection on resume. */
static void build_queue_sort_by_depth(BuildQueue *q) {
    size_t len = q->tail - q->head;
    if (len > 1)
        qsort(q->buf + q->head, len, sizeof(TreeNode *), compare_node_depth);
}

/** Append all children in sibling order (matches former DFS order). */
static void build_queue_push_children(BuildQueue *q, Tree *tree, TreeNode *node) {
    if (!tree->is_building) return;
    for (size_t i = 0; i < node->children_count; i++) {
        if (!tree->is_building) break;
        if (!build_queue_push(q, node->children[i])) {
            fprintf(stderr, "Error: out of memory expanding build queue\n");
            tree->is_building = false;
            break;
        }
    }
}


static int g_depth_tracker = -1;
static int g_session_start_depth = 0;

static void emit_build_progress_ex(Tree *tree, const TreeConfig *config,
                                   bool force);

static bool progress_display_reset;

static void reset_build_progress_timer(void) {
    progress_display_reset = true;
}

static void count_nodes_per_depth(TreeNode *node, int *counts) {
    if (!node) return;
    if (node->depth >= 0 && node->depth < BUILD_PROGRESS_MAX_DEPTH)
        counts[node->depth]++;
    for (size_t i = 0; i < node->children_count; i++)
        count_nodes_per_depth(node->children[i], counts);
}

static void format_int_commas(int n, char *buf, size_t len) {
    if (n < 0) {
        snprintf(buf, len, "-%d", -n);
        return;
    }
    char raw[32];
    snprintf(raw, sizeof(raw), "%d", n);
    size_t raw_len = strlen(raw);
    size_t pos = 0;
    int first_group = (int)(raw_len % 3);
    if (first_group == 0) first_group = 3;
    for (size_t i = 0; i < raw_len && pos + 1 < len; i++) {
        if (i > 0 && (i - (size_t)first_group) % 3 == 0)
            buf[pos++] = ',';
        buf[pos++] = raw[i];
    }
    buf[pos] = '\0';
}

static void format_duration_hms(int sec, char *buf, size_t len) {
    if (sec < 60)
        snprintf(buf, len, "%ds", sec);
    else if (sec < 3600) {
        int m = sec / 60;
        int s = sec % 60;
        snprintf(buf, len, "%dm %ds", m, s);
    } else {
        int h = sec / 3600;
        int m = (sec % 3600) / 60;
        snprintf(buf, len, "%dh %dm", h, m);
    }
}

static struct timespec g_progress_start_time;
static struct timespec g_depth_enter_time;
static struct timespec g_progress_last_emit;
static int g_progress_last_emit_processed = -1;
static bool g_progress_started = false;

static void emit_build_progress_reset(void) {
    memset(g_nodes_created_at_depth, 0, sizeof(g_nodes_created_at_depth));
    memset(g_nodes_processed_at_depth, 0, sizeof(g_nodes_processed_at_depth));
    g_depth_tracker = -1;
    g_session_start_depth = 0;
    g_progress_last_emit_processed = -1;
    g_progress_started = false;
}

static void emit_depth_complete_line(Tree *tree, int depth,
                                     const TreeConfig *config) {
    if (!config->progress_callback) return;
    if (depth < 0 || depth >= BUILD_PROGRESS_MAX_DEPTH) return;

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed_s = (now.tv_sec - g_progress_start_time.tv_sec)
                     + (now.tv_nsec - g_progress_start_time.tv_nsec) / 1e9;
    size_t session_added = tree->total_nodes - config->progress_baseline_nodes;
    double rate = (elapsed_s > 0.5)
        ? session_added / (elapsed_s / 60.0) : 0.0;

    char nodes_buf[32], elapsed_buf[32];
    format_int_commas(g_nodes_processed_at_depth[depth], nodes_buf, sizeof(nodes_buf));
    format_duration_hms((int)(elapsed_s + 0.5), elapsed_buf, sizeof(elapsed_buf));
    printf("\n  Depth %d complete: %s nodes, %.1f/min, %s elapsed\n",
           depth, nodes_buf, rate, elapsed_buf);
    fflush(stdout);
}

static void emit_build_summary(Tree *tree, const TreeConfig *config) {
    if (!config->progress_callback) return;

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed_s = (now.tv_sec - g_progress_start_time.tv_sec)
                     + (now.tv_nsec - g_progress_start_time.tv_nsec) / 1e9;
    size_t session_added = tree->total_nodes - config->progress_baseline_nodes;
    double rate = (elapsed_s > 0.5)
        ? session_added / (elapsed_s / 60.0) : 0.0;

    char nodes_buf[32], elapsed_buf[32];
    format_int_commas((int)tree->total_nodes, nodes_buf, sizeof(nodes_buf));
    format_duration_hms((int)(elapsed_s + 0.5), elapsed_buf, sizeof(elapsed_buf));
    printf("\n  Build complete: %s nodes, depth %d/%d, %.1f/min, %s total\n",
           nodes_buf, tree->max_depth_reached, config->max_depth,
           rate, elapsed_buf);
    fflush(stdout);
}

static void emit_build_progress(Tree *tree, const TreeConfig *config,
                                bool force) {
    if (!config->progress_callback) return;

    if (!g_progress_started || tree->total_nodes <= 1) {
        clock_gettime(CLOCK_MONOTONIC, &g_progress_start_time);
        g_progress_started = true;
        clock_gettime(CLOCK_MONOTONIC, &g_progress_last_emit);
        g_progress_last_emit_processed = -1;
    }

    int active = g_depth_tracker >= 0 ? g_depth_tracker : 0;
    if (active >= BUILD_PROGRESS_MAX_DEPTH)
        active = BUILD_PROGRESS_MAX_DEPTH - 1;

    int processed_at = g_nodes_processed_at_depth[active];

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (!force) {
        double since_emit = (now.tv_sec - g_progress_last_emit.tv_sec)
                          + (now.tv_nsec - g_progress_last_emit.tv_nsec) / 1e9;
        if (since_emit < 0.5 && processed_at - g_progress_last_emit_processed < 50)
            return;
    }
    g_progress_last_emit = now;
    g_progress_last_emit_processed = processed_at;

    double elapsed_s = (now.tv_sec - g_progress_start_time.tv_sec)
                     + (now.tv_nsec - g_progress_start_time.tv_nsec) / 1e9;
    double depth_elapsed_s = (now.tv_sec - g_depth_enter_time.tv_sec)
                             + (now.tv_nsec - g_depth_enter_time.tv_nsec) / 1e9;

    size_t session_added = tree->total_nodes - config->progress_baseline_nodes;
    double rate = (elapsed_s > 0.5)
        ? session_added / (elapsed_s / 60.0) : 0.0;

    int nodes_at = g_nodes_created_at_depth[active];
    int remaining = nodes_at - processed_at;
    if (remaining < 0) remaining = 0;

    double depth_rate = (depth_elapsed_s > 0.5 && processed_at > 0)
        ? processed_at / (depth_elapsed_s / 60.0) : rate;
    int eta = (depth_rate > 0 && remaining > 0)
            ? (int)(remaining * 60.0 / depth_rate + 0.5) : 0;

    BuildProgressInfo info = {
        .total_nodes              = (int)tree->total_nodes,
        .current_depth            = active,
        .max_depth_config         = config->max_depth,
        .nodes_at_current_depth   = nodes_at,
        .nodes_processed_at_depth = processed_at,
        .nodes_per_minute         = rate,
        .eta_depth_seconds        = eta,
    };
    config->progress_callback(&info);
}

static void emit_build_progress_ex(Tree *tree, const TreeConfig *config,
                                   bool force) {
    emit_build_progress(tree, config, force);
}

static void on_bfs_dequeue_node(Tree *tree, TreeNode *n,
                                const TreeConfig *config) {
    if (n->depth != g_depth_tracker) {
        if (n->depth > g_depth_tracker &&
            g_depth_tracker >= g_session_start_depth)
            emit_depth_complete_line(tree, g_depth_tracker, config);
        g_depth_tracker = n->depth;
        clock_gettime(CLOCK_MONOTONIC, &g_depth_enter_time);
    }
    if (n->depth >= 0 && n->depth < BUILD_PROGRESS_MAX_DEPTH)
        g_nodes_processed_at_depth[n->depth]++;
    tree->build_active_depth = n->depth;
    emit_build_progress(tree, config, false);
}

/* Scale cumP through a canonical's subtree when a transposition path
 * has higher probability.  Optionally re-enqueue unexpanded leaves that
 * now pass min_probability (q != NULL means build is active). */
static void propagate_cumP_recursive(TreeNode *node, double ratio,
                                      double min_prob, BuildQueue *q) {
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        child->cumulative_probability *= ratio;
        if (child->children_count > 0) {
            propagate_cumP_recursive(child, ratio, min_prob, q);
        } else if (q && !child->explored &&
                   child->cumulative_probability >= min_prob) {
            build_queue_push(q, child);
        }
    }
}

static void propagate_higher_cumP(TreeNode *canonical, double new_cumP,
                                   const TreeConfig *config, BuildQueue *q) {
    if (!canonical || new_cumP <= canonical->cumulative_probability) return;
    double ratio = new_cumP / canonical->cumulative_probability;
    canonical->cumulative_probability = new_cumP;
    propagate_cumP_recursive(canonical, ratio, config->min_probability, q);
}

static void build_process_node(Tree *tree, TreeNode *node,
                               const TreeConfig *config,
                               LichessExplorer *explorer, BuildQueue *q);

static void build_our_move(Tree *tree, TreeNode *node,
                            const TreeConfig *config,
                            LichessExplorer *explorer, BuildQueue *q);

static void build_opponent_move(Tree *tree, TreeNode *node,
                                 const TreeConfig *config,
                                 LichessExplorer *explorer, BuildQueue *q);

#define PV_INJECT_EPSILON 0.01

static bool child_has_move_uci(const TreeNode *node, const char *uci) {
    for (size_t i = 0; i < node->children_count; i++) {
        if (strcmp(node->children[i]->move_uci, uci) == 0)
            return true;
    }
    return false;
}

static double maia_prob_for_uci(const MaiaResponse *resp, const char *uci) {
    if (!resp || !resp->success) return -1.0;
    for (int i = 0; i < resp->move_count; i++) {
        if (strcmp(resp->moves[i].uci, uci) == 0)
            return resp->moves[i].probability;
    }
    return -1.0;
}

/**
 * After Maia/Lichess children are built, inject the stashed PV reply if
 * human move sources omitted it (or pruned it by mass/child caps).
 */
static void maybe_inject_pv_continuation(Tree *tree, TreeNode *node,
                                          const TreeConfig *config,
                                          const MaiaResponse *maia_resp) {
    if (node->pv_continuation_move[0] == '\0') return;

    const char *uci = node->pv_continuation_move;
    if (child_has_move_uci(node, uci)) return;

    char child_fen[MAX_FEN_LENGTH];
    if (!apply_uci(node->fen, uci, child_fen, MAX_FEN_LENGTH))
        return;

    char san_buf[MAX_MOVE_LENGTH];
    const char *san = uci;
    if (uci_to_san(node->fen, uci, san_buf, sizeof(san_buf)))
        san = san_buf;

    TreeNode *child = make_child(node, child_fen, san, uci, tree);
    if (!child) return;

    double prob = maia_prob_for_uci(maia_resp, uci);
    if (prob < 0.0 && config->maia) {
        MaiaResponse lookup;
        double maia_t = 0;
        if (query_maia_cached(config, node->fen, &lookup, &maia_t)) {
            node->maia_ms += maia_t;
            prob = maia_prob_for_uci(&lookup, uci);
        }
    }
    if (prob < 0.0) prob = PV_INJECT_EPSILON;

    child->move_probability = prob;
    child->cumulative_probability = node->cumulative_probability * prob;
    child->engine_injected = true;

    emit_build_progress(tree, config, false);
    emit_event(config, "inject", node->depth, "opp",
               "move=%s prob=%.4f", uci, prob);
}

/**
 * OUR MOVE (Maia + DB): top-N Maia candidates, DB evals only, stop on miss.
 */
static void build_our_move_maia_db(Tree *tree, TreeNode *node,
                                    const TreeConfig *config,
                                    LichessExplorer *explorer, BuildQueue *q) {
    (void)explorer;

    if (!config->maia) return;

    if (node->has_engine_eval) {
        int eval_us = node_eval_for_us(node, config->play_as_white);
        if (eval_us > config->max_eval_cp) {
            node->prune_reason = PRUNE_EVAL_TOO_HIGH;
            node->prune_eval_cp = eval_us;
            return;
        }
        if (eval_us < config->min_eval_cp) {
            node->prune_reason = PRUNE_EVAL_TOO_LOW;
            node->prune_eval_cp = eval_us;
            return;
        }
    }

    MaiaResponse maia_resp;
    double maia_t = 0;
    if (!query_maia_cached(config, node->fen, &maia_resp, &maia_t))
        return;
    node->maia_ms += maia_t;
    if (!maia_resp.success || maia_resp.move_count == 0)
        return;

    int max_candidates = config->our_multipv;
    if (max_candidates < 1) max_candidates = 1;
    if (max_candidates > MAX_MULTIPV) max_candidates = MAX_MULTIPV;

    int best_cp_white = 0;
    bool have_best = false;
    if (node->has_engine_eval) {
        best_cp_white = node->is_white_to_move ? node->engine_eval_cp
                                               : -node->engine_eval_cp;
        have_best = true;
    }

    char san_buf[MAX_MOVE_LENGTH];
    int added = 0;

    for (int i = 0; i < maia_resp.move_count && added < max_candidates; i++) {
        const char *uci = maia_resp.moves[i].uci;
        double prob = maia_resp.moves[i].probability;
        if (prob < config->maia_min_prob) continue;

        char child_fen[MAX_FEN_LENGTH];
        if (!apply_uci(node->fen, uci, child_fen, MAX_FEN_LENGTH))
            continue;

        int child_cp = 0, child_depth = 0;
        if (!lookup_db_eval_white(config, child_fen, &child_cp, &child_depth))
            continue;

        if (have_best) {
            ChessPosition child_pos;
            bool child_white = position_from_fen(&child_pos, child_fen)
                               && child_pos.white_to_move;
            int child_cp_white = child_white ? child_cp : -child_cp;
            if (best_cp_white - child_cp_white > config->max_eval_loss_cp)
                continue;
        }

        const char *san = uci;
        if (uci_to_san(node->fen, uci, san_buf, sizeof(san_buf)))
            san = san_buf;

        TreeNode *child = make_child(node, child_fen, san, uci, tree);
        if (!child) continue;

        child->move_probability = 1.0;
        child->cumulative_probability = node->cumulative_probability;
        child->maia_frequency = prob;
        node_set_eval(child, child_cp);
        if (config->db)
            rdb_put_eval(config->db, child_fen, child_cp,
                         child_depth > 0 ? child_depth : config->eval_depth);

        added++;
        emit_build_progress(tree, config, false);
    }

    build_queue_push_children(q, tree, node);
}

/**
 * OUR MOVE: Stockfish MultiPV → window prune → eval filter → enqueue children.
 *
 * Also queries Lichess for SAN notation and win-rate enrichment.
 *
 * The window-prune step lives here (rather than in `build_process_node`) so
 * that MultiPV's line-0 eval doubles as the node's engine eval — otherwise
 * we'd pay an extra single-PV Stockfish call on the same FEN just to gate
 * the MultiPV call that follows.
 */
static void build_our_move(Tree *tree, TreeNode *node,
                            const TreeConfig *config,
                            LichessExplorer *explorer, BuildQueue *q) {
    /* 0. External eval shortcut (ChessDB local → Lichess local → API).
     *    If depth-qualified and outside the eval window, prune without
     *    running MultiPV.  In-window hits still need MultiPV for candidates. */
    if (!node->has_engine_eval) {
        EvalChainContext chain = eval_chain_from_config(config);
        int db_cp = 0, db_depth = 0;
        const char *src = NULL;
        if (eval_chain_try_external(node, &chain, &db_cp, &db_depth, &src)) {
            emit_event(config, "eval", node->depth, "our",
                       "src=%s cp=%d depth=%d", src ? src : "ext",
                       db_cp, db_depth);
            node_set_eval(node, db_cp);
            if (config->db)
                rdb_put_eval(config->db, node->fen, db_cp, db_depth);

            int eval_us = node_eval_for_us(node, config->play_as_white);
            if (eval_us > config->max_eval_cp) {
                node->prune_reason = PRUNE_EVAL_TOO_HIGH;
                node->prune_eval_cp = eval_us;
                emit_event(config, "prune", node->depth, "our",
                           "reason=eval_high cp=%d src=%s", eval_us,
                           src ? src : "ext");
                return;
            }
            if (eval_us < config->min_eval_cp) {
                node->prune_reason = PRUNE_EVAL_TOO_LOW;
                node->prune_eval_cp = eval_us;
                emit_event(config, "prune", node->depth, "our",
                           "reason=eval_low cp=%d src=%s", eval_us,
                           src ? src : "ext");
                return;
            }
            /* In window — fall through to MultiPV for candidate generation. */
        }
    }

    /* 1. Run Stockfish MultiPV, widening the root to try more ideas. */
    int mpv_count = multipv_count_for_node(config, node);
    MultiPVJob mpv;
    bool mpv_from_cache = false;

    if (config->db &&
        rdb_get_multipv(config->db, node->fen, config->eval_depth,
                        mpv_count, &mpv)) {
        mpv_from_cache = true;
        STATS_INC(config, db_multipv_hits);
        emit_event(config, "mpv", node->depth, "our",
                   "src=db lines=%d", mpv.num_lines);
    } else {
        STATS_INC(config, db_multipv_misses);
        /* Stockfish MultiPV can take 10s+; refresh progress so the
         * terminal does not look frozen while blocked inside the engine. */
        emit_build_progress_ex(tree, config, true);
        struct timespec t0;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        bool ok = engine_pool_evaluate_multipv(config->engine_pool, node->fen,
                                               config->eval_depth,
                                               mpv_count, &mpv);
        double mpv_ms = elapsed_ms(&t0);
        node->sf_ms += mpv_ms;
        STATS_INC(config, sf_multipv_calls);
        STATS_ADD(config, sf_multipv_ms, mpv_ms);
        emit_event(config, "mpv", node->depth, "our",
                   "src=sf ms=%.1f ok=%d lines=%d",
                   mpv_ms, ok ? 1 : 0, ok ? mpv.num_lines : 0);
        if (!ok) return;

        if (mpv.success && mpv.num_lines > 0 && config->db)
            rdb_put_multipv(config->db, node->fen, config->eval_depth,
                            mpv_count, &mpv);
    }
    if (!mpv.success || mpv.num_lines == 0) return;
    (void)mpv_from_cache;

    /* Set node's own eval from the top line if not already set */
    if (!node->has_engine_eval) {
        node_set_eval(node, mpv.lines[0].eval_cp);
        if (config->db)
            rdb_put_eval(config->db, node->fen,
                         mpv.lines[0].eval_cp, mpv.lines[0].depth_reached);
    }

    /* 2. Eval-window pruning (deferred from build_process_node — see header
     *    comment).  If we're outside the window, mark the reason for
     *    PGN annotation / post-build cleanup and stop before branching. */
    {
        int eval_us = node_eval_for_us(node, config->play_as_white);
        if (eval_us > config->max_eval_cp) {
            node->prune_reason = PRUNE_EVAL_TOO_HIGH;
            node->prune_eval_cp = eval_us;
            emit_event(config, "prune", node->depth, "our",
                       "reason=eval_high cp=%d", eval_us);
            return;
        }
        if (eval_us < config->min_eval_cp) {
            node->prune_reason = PRUNE_EVAL_TOO_LOW;
            node->prune_eval_cp = eval_us;
            emit_event(config, "prune", node->depth, "our",
                       "reason=eval_low cp=%d", eval_us);
            return;
        }
    }

    /* 3. Query Lichess for SAN notation and win rates (enrichment only) */
    ExplorerResponse lichess;
    bool has_lichess = false;
    if (!config->maia_only) {
        double lich_t = 0;
        has_lichess = query_lichess_cached(config->db, explorer, node->fen,
                                           config->use_masters, &lichess, config,
                                           &lich_t);
        node->lichess_ms += lich_t;
    }

    if (has_lichess && lichess.success) {
        /* Normalize castling UCI in Lichess response */
        {
            ChessPosition _norm_pos;
            if (position_from_fen(&_norm_pos, node->fen)) {
                for (size_t i = 0; i < lichess.move_count; i++)
                    normalize_castling_uci(&_norm_pos, lichess.moves[i].uci);
            }
        }

        node_set_lichess_stats(node, lichess.total_white_wins,
                               lichess.total_black_wins, lichess.total_draws);
        if (lichess.has_opening) {
            snprintf(node->opening_name, sizeof(node->opening_name),
                     "%s", lichess.opening_name);
            snprintf(node->opening_eco, sizeof(node->opening_eco),
                     "%s", lichess.opening_eco);
        }
    }

    char our_san_buf[MAX_MOVE_LENGTH];

    /* 4. Filter candidates by eval threshold */
    int best_cp = mpv.lines[0].eval_cp;

    int added = 0;
    for (int pv = 0; pv < mpv.num_lines; pv++) {
        MultiPVLine *line = &mpv.lines[pv];
        if (line->move_uci[0] == '\0') continue;
        if (best_cp - line->eval_cp > config->max_eval_loss_cp) continue;

        char child_fen[MAX_FEN_LENGTH];
        if (!apply_uci(node->fen, line->move_uci, child_fen, MAX_FEN_LENGTH))
            continue;

        /* Look up SAN from Lichess data; fall back to computed SAN */
        const char *san = line->move_uci;
        if (has_lichess && lichess.success) {
            for (size_t j = 0; j < lichess.move_count; j++) {
                if (strcmp(lichess.moves[j].uci, line->move_uci) == 0) {
                    san = lichess.moves[j].san;
                    break;
                }
            }
        }
        if (san == line->move_uci &&
            uci_to_san(node->fen, line->move_uci,
                        our_san_buf, sizeof(our_san_buf)))
            san = our_san_buf;

        TreeNode *child = make_child(node, child_fen, san, line->move_uci, tree);
        if (!child) continue;

        child->move_probability = 1.0;
        child->cumulative_probability = node->cumulative_probability;
        node_set_eval(child, -line->eval_cp);
        if (config->db)
            rdb_put_eval(config->db, child_fen,
                         -line->eval_cp, line->depth_reached);

        /* Enrich with Lichess win-rate stats if available */
        if (has_lichess && lichess.success) {
            for (size_t j = 0; j < lichess.move_count; j++) {
                if (strcmp(lichess.moves[j].uci, line->move_uci) == 0) {
                    node_set_lichess_stats(child,
                        lichess.moves[j].white_wins,
                        lichess.moves[j].black_wins,
                        lichess.moves[j].draws);
                    break;
                }
            }
        }

        /* Line 0 only: stash engine's preferred opponent reply on the
         * child (opponent-to-move position after our best move). */
        if (pv == 0 && line->pv_reply_uci[0]) {
            snprintf(child->pv_continuation_move,
                     sizeof(child->pv_continuation_move),
                     "%s", line->pv_reply_uci);
        }

        added++;
        emit_build_progress(tree, config, false);
    }

    /* 5. Populate maia_frequency for novelty scoring.
     * Gated on `populate_maia_frequency` so builds that won't use novelty
     * (the common case: novelty_weight == 0) don't pay one Maia inference
     * per our-move node for data that's never consumed.  Goes through the
     * DB-cached wrapper so this inference is reused on resume. */
    if (config->maia && config->populate_maia_frequency && added > 0) {
        MaiaResponse maia_freq_resp;
        double maia_t = 0;
        if (query_maia_cached(config, node->fen, &maia_freq_resp, &maia_t)) {
            node->maia_ms += maia_t;
            for (size_t i = 0; i < node->children_count; i++) {
                TreeNode *child = node->children[i];
                for (int j = 0; j < maia_freq_resp.move_count; j++) {
                    if (strcmp(child->move_uci,
                              maia_freq_resp.moves[j].uci) == 0) {
                        child->maia_frequency =
                            maia_freq_resp.moves[j].probability;
                        break;
                    }
                }
            }
        }
    }

    /* 6. Enqueue children for breadth-first continuation */
    maybe_batch_prefetch_cdbdirect(config, node);
    build_queue_push_children(q, tree, node);
}


/**
 * OPPONENT MOVE: one source only — pure Maia or pure Lichess.
 *
 *   maia_only=true  → Maia's legal-move distribution is the sole source.
 *   maia_only=false → Lichess explorer's empirical distribution only.
 *
 * Probabilities are stored raw (no renormalization to 1).  The covered
 * mass Σ pᵢ is typically < 1 — the expectimax pass adds a tail term
 * for the uncovered mass so the result stays unbiased.
 *
 * Children are NOT pre-evaluated here.  Every opponent-move child is an
 * our-move node; when it is dequeued it will run MultiPV, whose line-0 eval
 * becomes both the node's eval and the basis for its own window-prune
 * check (see `build_our_move`).  Pre-evaluating with a single-PV call
 * would duplicate the work the MultiPV call does anyway.
 */
static void build_opponent_move(Tree *tree, TreeNode *node,
                                 const TreeConfig *config,
                                 LichessExplorer *explorer, BuildQueue *q) {
    char san_buf[MAX_MOVE_LENGTH];
    double mass_target = config->opp_mass_target;
    int children_added = 0;
    double mass_covered = 0.0;
    MaiaResponse maia_resp_for_inject;
    bool have_maia_for_inject = false;

    if (config->maia_only) {
        /* ---------- Pure Maia path ---------- */
        if (!config->maia) return;

        MaiaResponse maia_resp;
        double maia_t = 0;
        bool maia_ok = query_maia_cached(config, node->fen, &maia_resp, &maia_t);
        node->maia_ms += maia_t;

        if (!maia_ok || !maia_resp.success || maia_resp.move_count == 0)
            return;

        maia_resp_for_inject = maia_resp;
        have_maia_for_inject = true;

        for (int i = 0; i < maia_resp.move_count; i++) {
            const char *uci = maia_resp.moves[i].uci;
            double prob = maia_resp.moves[i].probability;
            if (prob < config->maia_min_prob) continue;

            if (config->opp_max_children > 0 &&
                children_added >= config->opp_max_children)
                break;
            if (mass_target > 0.0 && mass_covered >= mass_target)
                break;

            double new_cumul = node->cumulative_probability * prob;
            if (new_cumul < config->min_probability) continue;

            char child_fen[MAX_FEN_LENGTH];
            if (!apply_uci(node->fen, uci, child_fen, MAX_FEN_LENGTH))
                continue;

            const char *san = uci;
            if (uci_to_san(node->fen, uci, san_buf, sizeof(san_buf)))
                san = san_buf;

            TreeNode *child = make_child(node, child_fen, san, uci, tree);
            if (!child) continue;

            child->move_probability = prob;
            child->cumulative_probability = new_cumul;
            children_added++;
            mass_covered += prob;

            emit_build_progress(tree, config, false);
        }
    } else {
        /* ---------- Pure Lichess path ---------- */
        ExplorerResponse response;
        double lich_t = 0;
        if (!query_lichess_cached(config->db, explorer, node->fen,
                                  config->use_masters, &response, config,
                                  &lich_t))
            return;
        node->lichess_ms += lich_t;
        if (!response.success) return;

        {
            ChessPosition _norm_pos;
            if (position_from_fen(&_norm_pos, node->fen)) {
                for (size_t i = 0; i < response.move_count; i++)
                    normalize_castling_uci(&_norm_pos, response.moves[i].uci);
            }
        }

        node_set_lichess_stats(node, response.total_white_wins,
                               response.total_black_wins,
                               response.total_draws);
        if (response.has_opening) {
            snprintf(node->opening_name, sizeof(node->opening_name),
                     "%s", response.opening_name);
            snprintf(node->opening_eco, sizeof(node->opening_eco),
                     "%s", response.opening_eco);
        }

        uint64_t total = response.total_games;
        if (total == 0) return;

        for (size_t i = 0; i < response.move_count; i++) {
            ExplorerMove *move = &response.moves[i];
            uint64_t games = move->white_wins + move->draws + move->black_wins;
            if (games < (uint64_t)config->min_games) continue;

            if (config->opp_max_children > 0 &&
                children_added >= config->opp_max_children)
                break;
            if (mass_target > 0.0 && mass_covered >= mass_target)
                break;

            double prob = (double)games / (double)total;
            double new_cumul = node->cumulative_probability * prob;
            if (new_cumul < config->min_probability) continue;

            char child_fen[MAX_FEN_LENGTH];
            if (!apply_uci(node->fen, move->uci, child_fen, MAX_FEN_LENGTH))
                continue;

            TreeNode *child = make_child(node, child_fen, move->san,
                                          move->uci, tree);
            if (!child) continue;

            child->move_probability = prob;
            child->cumulative_probability = new_cumul;
            node_set_lichess_stats(child, move->white_wins,
                                   move->black_wins, move->draws);
            children_added++;
            mass_covered += prob;

            emit_build_progress(tree, config, false);
        }
    }

    maybe_inject_pv_continuation(tree, node, config,
                                 have_maia_for_inject ? &maia_resp_for_inject
                                                      : NULL);

    if (node->children_count == 0) return;

    /* Probabilities are kept RAW (Σ pᵢ ≤ 1).  The expectimax pass
     * accounts for the uncovered mass via a tail term so no
     * renormalization is needed or desired here — renormalizing
     * would silently assert that the moves we dropped behave like
     * the moves we kept, which is false. */

    /* No batch-eval here.  Every child is an our-move node whose own
     * MultiPV call (in build_our_move) will produce an eval naturally.
     * Pre-evaluating would be a redundant single-PV pass on positions
     * that are about to be searched again at the same depth. */

    /* Enqueue children for breadth-first continuation */
    maybe_batch_prefetch_cdbdirect(config, node);
    build_queue_push_children(q, tree, node);
}


/**
 * Process one dequeued node — the BFS worker that builds the tree.
 *
 * At each node:
 *   1. Check stop conditions (depth, cumP, interrupt)
 *   2. Resume support (already-expanded nodes: FenMap + enqueue children)
 *   3. For opponent-move nodes only: ensure eval and do the window-prune
 *      check.  Our-move nodes defer this to `build_our_move` so the eval
 *      can be harvested from the MultiPV call we're about to run anyway
 *      instead of paying an extra single-PV Stockfish call here.
 *   4. Transposition detection (O(1) FenMap lookup; links equivalent
 *      nodes into a circular ring via next_equivalent)
 *   5. Dispatch to build_our_move or build_opponent_move
 */
static void build_process_node(Tree *tree, TreeNode *node,
                               const TreeConfig *config,
                               LichessExplorer *explorer, BuildQueue *q) {
    if (!tree->is_building) return;

    if (node->depth >= config->max_depth) {
        /* Mark explored so progress/resume don't treat terminal leaves as
         * pending work when the build reaches the configured depth cap. */
        node->explored = true;
        emit_event(config, "skip", node->depth, "-", "reason=max_depth");
        return;
    }
    if (node->cumulative_probability < config->min_probability) {
        emit_event(config, "skip", node->depth, "-",
                   "reason=min_prob cum_prob=%.6f", node->cumulative_probability);
        return;
    }
    if (config->max_nodes > 0 && tree->total_nodes >= (size_t)config->max_nodes) {
        emit_event(config, "skip", node->depth, "-", "reason=max_nodes");
        return;
    }

    FenMap *fmap = (FenMap *)tree->expanded_fens;

    /* Resume: fully expanded in a prior session — enqueue children only */
    if (node->children_count > 0 && node->explored) {
        emit_event(config, "resume", node->depth, "-",
                   "children=%zu", node->children_count);
        fen_map_put(fmap, node->fen, node);
        build_queue_push_children(q, tree, node);
        return;
    }
    if (node->explored) return;

    bool is_our_move = (node->is_white_to_move == config->play_as_white);
    const char *nt = is_our_move ? "our" : "opp";

    node->build_t_ms = event_T(config);

    emit_event(config, "node", node->depth, nt,
               "total=%zu cum_prob=%.6f fen=%s",
               tree->total_nodes, node->cumulative_probability, node->fen);

    if (!is_our_move || config->build_mode == BUILD_MODE_MAIA_DB_EXPLORE) {
        if (!is_our_move && !node->has_engine_eval)
            emit_build_progress_ex(tree, config, true);
        ensure_eval(node, config);
        if (config->build_mode == BUILD_MODE_MAIA_DB_EXPLORE &&
            !node->has_engine_eval) {
            node->explored = true;
            return;
        }
        if (node->has_engine_eval) {
            int eval_us = node_eval_for_us(node, config->play_as_white);
            if (eval_us > config->max_eval_cp) {
                node->explored = true;
                node->prune_reason = PRUNE_EVAL_TOO_HIGH;
                node->prune_eval_cp = eval_us;
                emit_event(config, "prune", node->depth, nt,
                           "reason=eval_high cp=%d", eval_us);
                return;
            }
            if (eval_us < config->min_eval_cp) {
                node->explored = true;
                node->prune_reason = PRUNE_EVAL_TOO_LOW;
                node->prune_eval_cp = eval_us;
                emit_event(config, "prune", node->depth, nt,
                           "reason=eval_low cp=%d", eval_us);
                return;
            }
        }
    }

    /* Transposition detection */
    TreeNode *canonical = fen_map_get(fmap, node->fen);
    if (canonical) {
        if (canonical->next_equivalent) {
            node->next_equivalent = canonical->next_equivalent;
        } else {
            node->next_equivalent = canonical;
        }
        canonical->next_equivalent = node;
        node->explored = true;

        if (node->cumulative_probability > canonical->cumulative_probability)
            propagate_higher_cumP(canonical, node->cumulative_probability,
                                  config, q);

        emit_event(config, "transposition", node->depth, nt, "fen=%s", node->fen);
        return;
    }
    fen_map_put(fmap, node->fen, node);

    if (is_our_move) {
        if (config->build_mode == BUILD_MODE_MAIA_DB_EXPLORE)
            build_our_move_maia_db(tree, node, config, explorer, q);
        else
            build_our_move(tree, node, config, explorer, q);
    } else
        build_opponent_move(tree, node, config, explorer, q);

    /* Mark explored only after expansion finishes so an interrupt mid-call
     * leaves the node resumable (explored=false, possibly partial children). */
    node->explored = true;

    emit_event(config, "expanded", node->depth, nt,
               "children=%zu total=%zu", node->children_count, tree->total_nodes);
}


bool tree_build(Tree *tree, const char *start_fen,
                const TreeConfig *config, LichessExplorer *explorer) {
    if (!tree || !start_fen) return false;
    if (!explorer && !config->maia_only) return false;
    if (config->build_mode == BUILD_MODE_MAIA_DB_EXPLORE) {
        if (!config->maia) {
            fprintf(stderr, "Error: Maia is required for maia-db-explore mode\n");
            return false;
        }
    } else if (!config->engine_pool) {
        fprintf(stderr, "Error: engine_pool is required for tree_build\n");
        return false;
    }

    tree->config = *config;

    if (tree->root) {
        /* Resuming — keep existing tree intact */
    } else {
        tree->root = node_create(start_fen, NULL, NULL, NULL);
        if (!tree->root) return false;
        tree->total_nodes = 1;
    }
    if (tree->total_nodes <= 1) tree->max_depth_reached = 0;
    tree->is_building = true;

    if (tree->config.relative_eval) {
        ensure_eval(tree->root, &tree->config);
        if (tree->root->has_engine_eval) {
            int root_eval = node_eval_for_us(tree->root, tree->config.play_as_white);
            tree->config.min_eval_cp += root_eval;
            tree->config.max_eval_cp += root_eval;
        }
    }

    /* Always set epoch so per-node build_t_ms works even without event log. */
    if (tree->config.event_log_epoch.tv_sec == 0 &&
        tree->config.event_log_epoch.tv_nsec == 0) {
        clock_gettime(CLOCK_MONOTONIC, &tree->config.event_log_epoch);
    }
    if (tree->config.event_log) {
        fprintf(tree->config.event_log,
                "T_ms\tevent\tdepth\tnode_type\tdetail\n");
        emit_event(&tree->config, "build_start", 0, "-",
                   "nodes=%zu max_depth=%d min_prob=%.6f",
                   tree->total_nodes, tree->config.max_depth,
                   tree->config.min_probability);
    }

    tree->expanded_fens = fen_map_create();
    tree->config.progress_baseline_nodes = tree->total_nodes;
    reset_build_progress_timer();

    emit_build_progress_reset();
    count_nodes_per_depth(tree->root, g_nodes_created_at_depth);

    BuildQueue bq;
    build_queue_init(&bq);

    bool fast_resume = tree->root && tree->total_nodes > 1 &&
                       tree->root->children_count > 0;
    size_t frontier_count = 0;
    int min_frontier_depth = INT_MAX;
    bool queued = false;

    if (fast_resume) {
        resume_prepare_frontier(tree->root, (FenMap *)tree->expanded_fens,
                                &bq, &frontier_count, &min_frontier_depth);
        build_queue_sort_by_depth(&bq);
        queued = frontier_count > 0;
    } else {
        queued = build_queue_push(&bq, tree->root);
    }

    if (fast_resume && frontier_count == 0) {
        printf("  No frontier positions to expand.\n");
        tree->is_building = false;
        queued = true;
    }

    if (!queued) {
        fprintf(stderr, "Error: out of memory for build queue\n");
        tree->is_building = false;
    } else if (tree->is_building) {
        if (fast_resume && frontier_count > 0 &&
            min_frontier_depth != INT_MAX) {
            g_session_start_depth = min_frontier_depth;
            g_depth_tracker = min_frontier_depth - 1;
            for (int d = 0; d < min_frontier_depth && d < BUILD_PROGRESS_MAX_DEPTH; d++)
                g_nodes_processed_at_depth[d] = g_nodes_created_at_depth[d];
        } else {
            g_session_start_depth = 0;
            g_depth_tracker = -1;
        }
        clock_gettime(CLOCK_MONOTONIC, &g_depth_enter_time);
        tree->build_active_depth = 0;
        tree->build_queue_pending = 0;
        size_t last_hb_nodes = tree->total_nodes;
        struct timespec last_hb;
        clock_gettime(CLOCK_MONOTONIC, &last_hb);

        while (tree->is_building) {
            TreeNode *n = build_queue_pop(&bq);
            if (!n) break;
            on_bfs_dequeue_node(tree, n, &tree->config);
            build_process_node(tree, n, &tree->config, explorer, &bq);

            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double hb_elapsed = (now.tv_sec - last_hb.tv_sec)
                              + (now.tv_nsec - last_hb.tv_nsec) / 1e9;
            if (hb_elapsed >= 15.0) {
                tree->build_queue_pending = bq.tail - bq.head;
                emit_build_progress_ex(tree, &tree->config, true);
                last_hb = now;
                last_hb_nodes = tree->total_nodes;
            } else if (tree->total_nodes != last_hb_nodes) {
                last_hb_nodes = tree->total_nodes;
                last_hb = now;
            }
        }

        if (g_depth_tracker >= g_session_start_depth)
            emit_depth_complete_line(tree, g_depth_tracker, &tree->config);
        emit_build_summary(tree, &tree->config);
    }
    build_queue_free(&bq);

    fen_map_destroy((FenMap *)tree->expanded_fens);
    tree->expanded_fens = NULL;

    tree->build_complete = tree->is_building;
    tree->is_building = false;

    emit_event(&tree->config, "build_end", 0, "-",
               "nodes=%zu max_depth=%d complete=%d",
               tree->total_nodes, tree->max_depth_reached,
               tree->build_complete ? 1 : 0);

    return true;
}


/** Remove a child from parent's children array by index. */
static void remove_child_at(TreeNode *parent, size_t idx) {
    if (idx >= parent->children_count) return;
    for (size_t i = idx; i + 1 < parent->children_count; i++)
        parent->children[i] = parent->children[i + 1];
    parent->children_count--;
}

/**
 * Post-build cleanup: delete nodes pruned for eval-too-low.
 * These positions are too bad for us — no point keeping them.
 * Returns the number of nodes removed.
 *
 * A pruned our-move canonical can still be a member of a live
 * equivalence ring (FenMap insertion in build_process_node happens
 * before build_our_move runs its eval-window check, so transposition
 * siblings may have already joined the ring by the time the canonical
 * is marked PRUNE_EVAL_TOO_LOW).  node_destroy handles the unlink
 * internally, so surviving siblings never see a dangling
 * next_equivalent.
 */
static size_t prune_low_eval_recursive(TreeNode *node, Tree *tree) {
    if (!node) return 0;
    size_t removed = 0;

    /* Process children in reverse so removal doesn't skip entries */
    for (size_t i = node->children_count; i > 0; i--) {
        TreeNode *child = node->children[i - 1];
        if (child->prune_reason == PRUNE_EVAL_TOO_LOW) {
            size_t subtree_size = node_count_subtree(child);
            remove_child_at(node, i - 1);
            node_destroy(child);
            removed += subtree_size;
        } else {
            removed += prune_low_eval_recursive(child, tree);
        }
    }
    return removed;
}

size_t tree_prune_eval_too_low(Tree *tree) {
    if (!tree || !tree->root) return 0;
    size_t removed = prune_low_eval_recursive(tree->root, tree);
    if (removed > 0) {
        tree->total_nodes = node_count_subtree(tree->root);
    }
    return removed;
}


void tree_stop_build(Tree *tree) {
    if (tree) tree->is_building = false;
}


/* ========== Search / utility ========== */

static TreeNode* find_by_fen_recursive(TreeNode *node, const char *fen) {
    if (!node) return NULL;
    if (strcmp(node->fen, fen) == 0) return node;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *found = find_by_fen_recursive(node->children[i], fen);
        if (found) return found;
    }
    return NULL;
}

TreeNode* tree_find_by_fen(const Tree *tree, const char *fen) {
    if (!tree || !tree->root || !fen) return NULL;
    return find_by_fen_recursive(tree->root, fen);
}

TreeNode* tree_find_by_moves(const Tree *tree, const char **moves, size_t num_moves) {
    if (!tree || !tree->root || !moves) return NULL;
    TreeNode *current = tree->root;
    for (size_t m = 0; m < num_moves; m++) {
        TreeNode *next = NULL;
        for (size_t i = 0; i < current->children_count; i++) {
            if (strcmp(current->children[i]->move_san, moves[m]) == 0) {
                next = current->children[i];
                break;
            }
        }
        if (!next) return NULL;
        current = next;
    }
    return current;
}


static void collect_leaves(TreeNode *node, TreeNode **leaves,
                           size_t *count, size_t max_count) {
    if (!node || *count >= max_count) return;
    if (node->children_count == 0) {
        leaves[*count] = node;
        (*count)++;
        return;
    }
    for (size_t i = 0; i < node->children_count; i++)
        collect_leaves(node->children[i], leaves, count, max_count);
}

size_t tree_get_leaves(const Tree *tree, TreeNode **out_leaves, size_t max_leaves) {
    if (!tree || !tree->root || !out_leaves) return 0;
    size_t count = 0;
    collect_leaves(tree->root, out_leaves, &count, max_leaves);
    return count;
}


static void collect_at_depth(TreeNode *node, int target_depth,
                              TreeNode **nodes, size_t *count, size_t max_count) {
    if (!node || *count >= max_count) return;
    if (node->depth == target_depth) { nodes[*count] = node; (*count)++; return; }
    if (node->depth > target_depth) return;
    for (size_t i = 0; i < node->children_count; i++)
        collect_at_depth(node->children[i], target_depth, nodes, count, max_count);
}

size_t tree_get_nodes_at_depth(const Tree *tree, int depth,
                                TreeNode **out_nodes, size_t max_nodes) {
    if (!tree || !tree->root || !out_nodes) return 0;
    size_t count = 0;
    collect_at_depth(tree->root, depth, out_nodes, &count, max_nodes);
    return count;
}




/* ========== Expectimax Value Propagation ========== */

/**
 * Centipawn → win probability (for us).
 *
 * Logistic curve matching Lichess's published eval-to-winrate
 * conversion (the one used in their UI):
 *
 *     wp = 1 / (1 + exp(-k · cp))
 *     k  = ln(10) / 625  ≈ 0.00368208
 *
 * Sanity checks at this k:
 *     wp(+100) ≈ 0.59   wp(+200) ≈ 0.68   wp(+400) ≈ 0.81
 *     wp(+625) ≈ 0.91   (k·625 = ln 10  ⇒  1/(1+10⁻¹))
 *
 * Mate scores (|cp| > 9000) are clamped explicitly to 1/0 — the
 * logistic alone does not saturate them cleanly and we don't want
 * engine `cp` values anywhere near the tails of the sigmoid to
 * propagate as non-trivial numbers.
 */
#define EVAL_TO_WP_K        0.00368208   /* = ln(10) / 625 */
#define WP_MATE_CUTOFF_CP   9000

double win_probability(int cp) {
    if (abs(cp) > WP_MATE_CUTOFF_CP) return cp > 0 ? 1.0 : 0.0;
    return 1.0 / (1.0 + exp(-EVAL_TO_WP_K * (double)cp));
}

/**
 * Leaf value used in the expectimax pass.
 *
 * Blends the engine's win-probability estimate with a neutral prior
 * (0.5 = "we don't know who's winning") using `leaf_confidence`:
 *
 *     V = leaf_conf · wp(eval_for_us) + (1 − leaf_conf) · 0.5
 *
 * At leaf_conf = 1.0 (the default) this is just wp(eval) — full trust in
 * the engine's verdict.  At smaller leaf_conf the value is pulled toward
 * 0.5, which is what an honest "I haven't expanded this position" estimate
 * should look like.  The previous form `leaf_conf · wp(eval)` biased
 * unexplored leaves toward 0 (certain loss), which is categorically the
 * wrong direction for an uncertainty discount.
 *
 * If the node has no engine eval at all (shouldn't happen post-build) we
 * return 0.5 for the same reason: "unknown" is the correct fallback, not
 * "certain loss".
 */
static double leaf_value(const TreeNode *node,
                         const RepertoireConfig *config) {
    double lc = config->leaf_confidence;
    if (lc < 0.0) lc = 0.0;
    if (lc > 1.0) lc = 1.0;

    if (!node->has_engine_eval)
        return 0.5;  /* neutral prior when we have nothing else */

    int cp_us = node_eval_for_us(node, config->play_as_white);
    return lc * win_probability(cp_us) + (1.0 - lc) * 0.5;
}


/** Compute local_cpl at opponent-move nodes (display/diagnostics only). */
static void compute_local_cpl(TreeNode *node) {
    if (!node || node->children_count == 0) return;

    int best_opp_cp = 100000;
    bool has_any = false;
    for (size_t i = 0; i < node->children_count; i++) {
        if (!node->children[i]->has_engine_eval) continue;
        if (node->children[i]->engine_eval_cp < best_opp_cp)
            best_opp_cp = node->children[i]->engine_eval_cp;
        has_any = true;
    }
    if (!has_any) return;

    double sum = 0.0;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_engine_eval) continue;
        if (child->move_probability < 0.01) continue;
        int delta = child->engine_eval_cp - best_opp_cp;
        if (delta < 0) delta = 0;
        sum += child->move_probability * (double)delta;
    }
    node->local_cpl = sum;
}


/** Novelty-adjusted V for move selection at an our-move node.
 *  novelty_weight = 0 (default) → returns V unchanged.  Otherwise
 *  boosts rarely-played moves proportionally.  Lichess game counts
 *  are preferred; Maia frequency is the fallback. */
static double adjusted_v_for_selection(const TreeNode *parent,
                                        const TreeNode *child,
                                        double nw) {
    double v = child->expectimax_value;
    if (nw <= 0.0) return v;

    double novelty = 0.0;
    if (parent->total_games > 0 && child->total_games > 0) {
        novelty = 1.0 - (double)child->total_games
                        / (double)parent->total_games;
    } else if (child->maia_frequency >= 0.0) {
        novelty = 1.0 - child->maia_frequency;
    }
    if (novelty < 0.0) novelty = 0.0;
    return v * (1.0 + nw * novelty);
}

/**
 * At an our-move node, pick the child with the highest expectimax_value
 * among candidates passing the eval-loss filter.
 *
 * Falls back to all children if none pass.  Under the default pipeline
 * every child already passed the same `max_eval_loss_cp` gate at build
 * time, so the filter is usually a no-op and the fallback is only
 * reached if the selection-phase config uses a stricter threshold.
 *
 * Returns the number of children that passed the eval-loss filter.
 */
int score_our_move_children(TreeNode *node,
                            const struct RepertoireConfig *config,
                            ScoredChild *best_out) {
    if (!node || !config || !best_out) return 0;

    best_out->child = NULL;
    best_out->expectimax_value = -1.0;

    /* Find best eval among children for the eval-loss filter. */
    int best_child_cp = -100000;
    for (size_t i = 0; i < node->children_count; i++) {
        if (!node->children[i]->has_engine_eval) continue;
        int cp_us = node_eval_for_us(node->children[i], config->play_as_white);
        if (cp_us > best_child_cp) best_child_cp = cp_us;
    }

    double nw = config->novelty_weight / 100.0;

    int passing = 0;
    double best_filtered_v = -1.0;
    TreeNode *best_filtered = NULL;
    double best_any_v = -1.0;
    TreeNode *best_any = NULL;

    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_expectimax) continue;

        double v = adjusted_v_for_selection(node, child, nw);

        if (v > best_any_v) {
            best_any_v = v;
            best_any = child;
        }

        int cp_us = node_eval_for_us(child, config->play_as_white);
        if (cp_us < best_child_cp - config->max_eval_loss_cp) continue;
        passing++;

        if (v > best_filtered_v) {
            best_filtered_v = v;
            best_filtered = child;
        }
    }

    TreeNode *winner = best_filtered ? best_filtered : best_any;
    best_out->child = winner;
    best_out->expectimax_value = winner ? winner->expectimax_value : -1.0;
    return passing;
}


static size_t calculate_expectimax_recursive(TreeNode *node,
                                              const RepertoireConfig *config) {
    if (!node) return 0;
    size_t count = 0;

    /* Post-order: recurse children first */
    for (size_t i = 0; i < node->children_count; i++)
        count += calculate_expectimax_recursive(node->children[i], config);

    bool is_our_move = (node->is_white_to_move == config->play_as_white);

    /* Compute local_cpl for display (only meaningful at opponent-move nodes) */
    if (!is_our_move && node->children_count > 0)
        compute_local_cpl(node);

    /* Compute subtree_depth and subtree_opp_plies for diagnostics */
    if (node->children_count == 0) {
        node->subtree_depth = 0;
        node->subtree_opp_plies = 0;
    } else {
        int max_sd = 0;
        int max_opp = 0;
        for (size_t i = 0; i < node->children_count; i++) {
            int sd = node->children[i]->subtree_depth + 1;
            if (sd > max_sd) max_sd = sd;

            int opp = node->children[i]->subtree_opp_plies;
            if (!is_our_move) opp += 1;
            if (opp > max_opp) max_opp = opp;
        }
        node->subtree_depth = max_sd;
        node->subtree_opp_plies = max_opp;
    }

    /* Transposition leaves: borrow V from the canonical node (the one
       in the equivalence ring that has children).  Must happen BEFORE
       the leaf case so we don't compute V = wp(eval) and then overwrite. */
    if (node->children_count == 0 && node->next_equivalent) {
        TreeNode *equiv = node->next_equivalent;
        while (equiv != node) {
            if (equiv->has_expectimax && equiv->children_count > 0) {
                node->expectimax_value = equiv->expectimax_value;
                node->local_cpl = equiv->local_cpl;
                node->subtree_depth = equiv->subtree_depth;
                node->subtree_opp_plies = equiv->subtree_opp_plies;
                node->has_expectimax = true;
                count++;
                return count;
            }
            if (!equiv->next_equivalent || equiv->next_equivalent == node)
                break;
            equiv = equiv->next_equivalent;
        }
    }

    if (node->children_count == 0) {
        /* Leaf: V = leaf_value(node) — see leaf_value() for the formula. */
        node->expectimax_value = leaf_value(node, config);

    } else if (is_our_move) {
        /* Our move: V = max(V_child) among eval-loss-filtered candidates.
         * If no child scored (shouldn't normally happen — post-order
         * guarantees children have has_expectimax set), fall back to the
         * leaf value for this node rather than asserting V=0 (certain
         * loss), which would be a worse lie than "we don't know". */
        ScoredChild best;
        score_our_move_children(node, config, &best);
        node->expectimax_value = best.child
            ? best.expectimax_value
            : leaf_value(node, config);

    } else {
        /* Opponent move — proper expectimax with a tail term for
         * uncovered probability mass.
         *
         *   V_opp = Σ pᵢ · V(childᵢ)  +  (1 − Σ pᵢ) · V_tail
         *
         * pᵢ are raw (not renormalized) covered probabilities.
         * V_tail is our win probability if the opponent plays a move
         * we didn't model.  Since Stockfish's eval at THIS node is
         * by definition the value after best opponent play, and rare
         * human moves are on average ≥ that (worse for opponent),
         * wp(eval_for_us) is a principled — and slightly conservative
         * — estimate.  leaf_value() applies the same uncertainty blend
         * toward 0.5 that it applies to any other unexplored leaf, so
         * the tail term honours leaf_confidence without double-counting
         * the bias. */
        double covered = 0.0;
        double v = 0.0;
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (!child->has_expectimax) continue;
            covered += child->move_probability;
            v += child->move_probability * child->expectimax_value;
        }

        /* Clamp covered to [0, 1] against float drift / data noise. */
        if (covered > 1.0) covered = 1.0;
        if (covered < 0.0) covered = 0.0;

        double tail = 1.0 - covered;
        if (tail > 0.0) {
            /* V_tail = leaf value at this node.  leaf_value() returns
             * the 0.5 neutral prior if this node somehow has no engine
             * eval, so the tail term always contributes something
             * reasonable rather than silently dropping to 0. */
            v += tail * leaf_value(node, config);
        }

        node->expectimax_value = v;
    }

    node->has_expectimax = true;
    count++;
    return count;
}

size_t tree_calculate_expectimax(Tree *tree, const struct RepertoireConfig *config) {
    if (!tree || !tree->root || !config) return 0;

    /* Two-pass expectimax.
     *
     * The transposition-leaf borrow rule in calculate_expectimax_recursive
     * copies V from the canonical (the equivalent node that has children).
     * In a single post-order DFS this only works if the canonical is
     * processed before any of its transposition leaves — which is true
     * whenever build-time DFS and expectimax DFS visit subtrees in the
     * same order, but is NOT guaranteed after a load-from-JSON or if a
     * later session reorders children.
     *
     * Fix: run the recursion twice.  Pass 1 gives every canonical a
     * correct has_expectimax flag (their subtrees don't depend on
     * transposition leaves, only the other way around).  Pass 2 fully
     * overwrites every node's V, so any transposition leaf that fell
     * back to leaf_value in pass 1 now finds its canonical ready and
     * the corrected value propagates up through its ancestors.
     *
     * Total cost is 2·O(n) — still linear in tree size, and dominated
     * by the build phase's Stockfish/Maia inferences by many orders of
     * magnitude. */
    calculate_expectimax_recursive(tree->root, config);
    return calculate_expectimax_recursive(tree->root, config);
}


/* ========== Probability recalculation ========== */

static void recalc_prob_recursive(TreeNode *node, double parent_cumul,
                                   bool play_as_white) {
    if (!node) return;
    bool parent_was_our_move = (node->parent &&
                                node->parent->is_white_to_move == play_as_white);
    node->cumulative_probability = parent_was_our_move
        ? parent_cumul
        : parent_cumul * node->move_probability;

    for (size_t i = 0; i < node->children_count; i++)
        recalc_prob_recursive(node->children[i],
                              node->cumulative_probability, play_as_white);
}

void tree_recalculate_probabilities(Tree *tree) {
    if (!tree || !tree->root) return;
    tree->root->cumulative_probability = 1.0;
    for (size_t i = 0; i < tree->root->children_count; i++)
        recalc_prob_recursive(tree->root->children[i], 1.0,
                              tree->config.play_as_white);
}


/* ========== Post-build transposition cumP fixup ========== */

static bool fix_transposition_cumP_walk(TreeNode *node, double min_prob) {
    if (!node) return false;
    bool any_update = false;

    if (node->children_count == 0 && node->next_equivalent) {
        TreeNode *equiv = node->next_equivalent;
        while (equiv != node) {
            if (equiv->children_count > 0) {
                if (node->cumulative_probability > equiv->cumulative_probability) {
                    double ratio = node->cumulative_probability /
                                   equiv->cumulative_probability;
                    equiv->cumulative_probability = node->cumulative_probability;
                    propagate_cumP_recursive(equiv, ratio, min_prob, NULL);
                    any_update = true;
                }
                break;
            }
            if (!equiv->next_equivalent || equiv->next_equivalent == node)
                break;
            equiv = equiv->next_equivalent;
        }
    }

    for (size_t i = 0; i < node->children_count; i++) {
        if (fix_transposition_cumP_walk(node->children[i], min_prob))
            any_update = true;
    }
    return any_update;
}

size_t tree_fix_transposition_probabilities(Tree *tree) {
    if (!tree || !tree->root) return 0;
    size_t passes = 0;
    while (fix_transposition_cumP_walk(tree->root,
                                        tree->config.min_probability)) {
        passes++;
        if (passes > 20) break;
    }
    return passes;
}


size_t tree_get_line_to_node(const TreeNode *node,
                              char (*out_moves)[MAX_MOVE_LENGTH],
                              size_t max_moves) {
    if (!node || !out_moves) return 0;
    size_t depth = 0;
    const TreeNode *temp = node;
    while (temp->parent) { depth++; temp = temp->parent; }
    if (depth == 0) return 0;
    if (depth > max_moves) depth = max_moves;

    temp = node;
    for (int i = (int)depth - 1; i >= 0 && temp->parent; i--) {
        snprintf(out_moves[i], MAX_MOVE_LENGTH, "%s", temp->move_san);
        temp = temp->parent;
    }
    return depth;
}


void tree_print_stats(const Tree *tree) {
    if (!tree) { printf("Tree: (null)\n"); return; }
    printf("\n=== Tree Statistics ===\n");
    printf("Total nodes: %zu\n", tree->total_nodes);
    printf("Max depth reached: %d ply\n", tree->max_depth_reached);
    if (tree->root) {
        printf("Root FEN: %s\n", tree->root->fen);
        printf("Actual node count: %zu\n", node_count_subtree(tree->root));
        if (tree->root->total_games > 0)
            printf("Root position games: %lu\n",
                   (unsigned long)tree->root->total_games);
    }
    printf("\nConfiguration:\n");
    printf("  Min probability: %.4f%%\n", tree->config.min_probability * 100.0);
    printf("  Max depth: %d ply\n", tree->config.max_depth);
    {
        int root_multipv = multipv_count_for_node(&tree->config, tree->root);
        if (root_multipv == tree->config.our_multipv) {
            printf("  Our MultiPV: %d (eval-loss filter %dcp)\n",
                   tree->config.our_multipv, tree->config.max_eval_loss_cp);
        } else {
            printf("  Our MultiPV: root %d, others %d (eval-loss filter %dcp)\n",
                   root_multipv, tree->config.our_multipv,
                   tree->config.max_eval_loss_cp);
        }
    }
    printf("  Opponent: max %d children, mass target %.0f%%\n",
           tree->config.opp_max_children,
           tree->config.opp_mass_target * 100.0);
    printf("  Eval window: [%+d, %+d] cp\n",
           tree->config.min_eval_cp, tree->config.max_eval_cp);
    printf("  Opponent source: %s\n",
           tree->config.maia_only ? "Maia (policy head)" : "Lichess explorer");
    if (tree->config.maia_only)
        printf("  Maia Elo: %d\n", tree->config.maia_elo);
    printf("========================\n\n");
}


static void print_recursive(TreeNode *node, int max_depth) {
    if (!node) return;
    if (max_depth >= 0 && node->depth > max_depth) return;
    node_print(node, node->depth);
    for (size_t i = 0; i < node->children_count; i++)
        print_recursive(node->children[i], max_depth);
}

void tree_print(const Tree *tree, int max_depth) {
    if (!tree || !tree->root) { printf("Tree: (empty)\n"); return; }
    printf("\n=== Tree Structure ===\n");
    print_recursive(tree->root, max_depth);
    printf("======================\n\n");
}


/* ========== Traversal ========== */

static void traverse_dfs_recursive(TreeNode *node,
                                    void (*callback)(TreeNode *, void *),
                                    void *user_data) {
    if (!node) return;
    callback(node, user_data);
    for (size_t i = 0; i < node->children_count; i++)
        traverse_dfs_recursive(node->children[i], callback, user_data);
}

void tree_traverse_dfs(const Tree *tree,
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data) {
    if (!tree || !tree->root || !callback) return;
    traverse_dfs_recursive(tree->root, callback, user_data);
}


typedef struct {
    TreeNode **nodes;
    size_t capacity, head, count;
} NodeQueue;

static NodeQueue* queue_create(size_t capacity) {
    NodeQueue *q = (NodeQueue *)malloc(sizeof(NodeQueue));
    if (!q) return NULL;
    q->nodes = (TreeNode **)malloc(capacity * sizeof(TreeNode *));
    if (!q->nodes) { free(q); return NULL; }
    q->capacity = capacity;
    q->head = 0;
    q->count = 0;
    return q;
}

static void queue_destroy(NodeQueue *q) {
    if (q) { free(q->nodes); free(q); }
}

static bool queue_push(NodeQueue *q, TreeNode *node) {
    if (q->head + q->count >= q->capacity) {
        if (q->head > 0) {
            memmove(q->nodes, q->nodes + q->head,
                    q->count * sizeof(TreeNode *));
            q->head = 0;
        } else {
            size_t new_cap = q->capacity * 2;
            TreeNode **new_nodes = (TreeNode **)realloc(
                q->nodes, new_cap * sizeof(TreeNode *));
            if (!new_nodes) return false;
            q->nodes = new_nodes;
            q->capacity = new_cap;
        }
    }
    q->nodes[q->head + q->count] = node;
    q->count++;
    return true;
}

static TreeNode* queue_pop(NodeQueue *q) {
    if (q->count == 0) return NULL;
    TreeNode *node = q->nodes[q->head];
    q->head++;
    q->count--;
    return node;
}

void tree_traverse_bfs(const Tree *tree,
                       void (*callback)(TreeNode *node, void *user_data),
                       void *user_data) {
    if (!tree || !tree->root || !callback) return;
    NodeQueue *queue = queue_create(256);
    if (!queue) return;
    queue_push(queue, tree->root);
    while (queue->count > 0) {
        TreeNode *node = queue_pop(queue);
        if (!node) continue;
        callback(node, user_data);
        if (node->children) {
            for (size_t i = 0; i < node->children_count; i++)
                if (node->children[i]) queue_push(queue, node->children[i]);
        }
    }
    queue_destroy(queue);
}
