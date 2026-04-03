/**
 * tree.c - Opening Tree Implementation
 *
 * The build pass interleaves Lichess explorer queries with Stockfish
 * evaluation.  At our-move nodes, Stockfish MultiPV finds candidates
 * and the eval filter prunes immediately.  At opponent-move nodes,
 * Lichess DB moves are added first, then Maia fills remaining mass
 * with predicted human moves (a single node can have a mix of both
 * sources).  The engine's top-1 move is injected if not already present.
 */

#include "tree.h"
#include "repertoire.h"
#include "lichess_api.h"
#include "chess_logic.h"
#include "san_convert.h"
#include "engine_pool.h"
#include "database.h"
#include "maia.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <time.h>


/* ========== Instrumentation helpers ========== */

static double elapsed_ms(const struct timespec *start) {
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &end);
    return (end.tv_sec - start->tv_sec) * 1000.0 +
           (end.tv_nsec - start->tv_nsec) / 1e6;
}

#define STATS_INC(cfg, field)  do { if ((cfg)->stats) (cfg)->stats->field++; } while(0)
#define STATS_ADD(cfg, field, v) do { if ((cfg)->stats) (cfg)->stats->field += (v); } while(0)


/* ========== FEN Map (transposition table — FEN → canonical TreeNode*) ========== */

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
    uint32_t idx = fen_hash(fen, map->num_buckets);
    for (FenMapEntry *e = map->buckets[idx]; e; e = e->next) {
        if (strcmp(e->fen, fen) == 0) return e->node;
    }
    return NULL;
}

/** Insert a FEN → node mapping.  No-op if the FEN is already present. */
static void fen_map_put(FenMap *map, const char *fen, TreeNode *node) {
    if (!map || fen_map_get(map, fen)) return;
    if ((double)map->count / (double)map->num_buckets >= FEN_MAP_LOAD_FACTOR)
        fen_map_resize(map);
    uint32_t idx = fen_hash(fen, map->num_buckets);
    FenMapEntry *e = (FenMapEntry *)malloc(sizeof(FenMapEntry));
    if (!e) return;
    e->fen = strdup(fen);
    e->node = node;
    e->next = map->buckets[idx];
    map->buckets[idx] = e;
    map->count++;
}


/* Ease calculation constants (matching the Flutter/Python implementation) */
#define EASE_ALPHA (1.0/3.0)
#define EASE_BETA  1.5


TreeConfig tree_config_default(void) {
    TreeConfig config = {
        .play_as_white = true,
        .min_probability = 0.0001,
        .max_depth = 30,
        .max_nodes = 0,

        .engine_pool = NULL,
        .db = NULL,
        .eval_depth = 20,

        .our_multipv_root = 10,
        .our_multipv_floor = 2,
        .taper_depth = 8,
        .max_eval_loss_cp = 50,

        .opp_max_children = 6,
        .opp_mass_root = 0.95,
        .opp_mass_floor = 0.50,

        .min_eval_cp = 0,
        .max_eval_cp = 200,
        .relative_eval = false,

        .rating_range = "2000,2200,2500",
        .speeds = "blitz,rapid,classical",
        .min_games = 10,
        .use_masters = false,

        .maia = NULL,
        .maia_elo = 2200,
        .maia_threshold = 0.01,
        .maia_min_prob = 0.02,
        .maia_only = false,
        .progress_callback = NULL,
        .stats = NULL,
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
    if (child->depth > tree->max_depth_reached)
        tree->max_depth_reached = child->depth;
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
 * Checks the DB cache first, then runs a single Stockfish eval.
 * If out_job is non-NULL, the full EvalJob result is written there
 * so callers can reuse the bestmove without a redundant engine call.
 */
static void ensure_eval(TreeNode *node, const TreeConfig *config,
                        EvalJob *out_job) {
    if (out_job) memset(out_job, 0, sizeof(*out_job));

    if (node->has_engine_eval) return;

    /* Try DB cache */
    if (config->db) {
        int cp, depth;
        if (rdb_get_eval(config->db, node->fen, &cp, &depth)) {
            STATS_INC(config, db_eval_hits);
            node_set_eval(node, cp);
            return;
        }
        STATS_INC(config, db_eval_misses);
    }

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
            if (out_job) *out_job = job;
        }

        STATS_INC(config, sf_single_calls);
        STATS_ADD(config, sf_single_ms, elapsed_ms(&t0));
    }
}

/**
 * Batch-evaluate children that don't have evals yet.
 * Checks the DB cache first, then engine-evaluates the remainder.
 */
static void batch_eval_children(TreeNode *node, const TreeConfig *config) {
    if (!config->engine_pool || node->children_count == 0) return;

    /* Collect children needing evals */
    size_t n = node->children_count;
    EvalJob *jobs = (EvalJob *)calloc(n, sizeof(EvalJob));
    size_t *idx_map = (size_t *)calloc(n, sizeof(size_t));
    if (!jobs || !idx_map) { free(jobs); free(idx_map); return; }

    int job_count = 0;
    for (size_t i = 0; i < n; i++) {
        TreeNode *child = node->children[i];
        if (child->has_engine_eval) continue;

        /* Check DB cache */
        if (config->db) {
            int cp, depth;
            if (rdb_get_eval(config->db, child->fen, &cp, &depth)) {
                STATS_INC(config, db_eval_hits);
                node_set_eval(child, cp);
                continue;
            }
            STATS_INC(config, db_eval_misses);
        }

        snprintf(jobs[job_count].fen, MAX_EVAL_FEN_LENGTH, "%s", child->fen);
        idx_map[job_count] = i;
        job_count++;
    }

    if (job_count > 0) {
        struct timespec t0;
        clock_gettime(CLOCK_MONOTONIC, &t0);

        engine_pool_evaluate_batch(config->engine_pool, jobs, job_count, NULL, NULL);

        STATS_INC(config, sf_batch_calls);
        STATS_ADD(config, sf_batch_ms, elapsed_ms(&t0));

        for (int k = 0; k < job_count; k++) {
            if (!jobs[k].success) continue;
            TreeNode *child = node->children[idx_map[k]];
            node_set_eval(child, jobs[k].eval_cp);
            if (config->db)
                rdb_put_eval(config->db, child->fen,
                             jobs[k].eval_cp, jobs[k].depth_reached);
        }
    }

    free(jobs);
    free(idx_map);
}


/* ========== Lichess query with DB caching ========== */

static bool query_lichess_cached(RepertoireDB *db, LichessExplorer *explorer,
                                  const char *fen, bool use_masters,
                                  ExplorerResponse *response,
                                  const TreeConfig *config) {
    memset(response, 0, sizeof(*response));

    if (db) {
        CachedExplorerResponse cached;
        if (rdb_get_explorer_cache(db, fen, &cached) && cached.found) {
            STATS_INC(config, db_explorer_hits);
            STATS_INC(config, lichess_cache_hits);

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

    STATS_INC(config, lichess_queries);
    STATS_ADD(config, lichess_total_ms, elapsed_ms(&t0));

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


/** MultiPV tapers linearly from root value to floor over taper_depth plies. */
static int multipv_for_depth(const TreeConfig *config, int depth) {
    if (depth >= config->taper_depth)
        return config->our_multipv_floor;
    int span = config->our_multipv_root - config->our_multipv_floor;
    return config->our_multipv_root - span * depth / config->taper_depth;
}

/** Opponent mass target tapers linearly from root to floor over taper_depth. */
static double opp_mass_for_depth(const TreeConfig *config, int depth) {
    if (depth >= config->taper_depth)
        return config->opp_mass_floor;
    double span = config->opp_mass_root - config->opp_mass_floor;
    return config->opp_mass_root - span * depth / config->taper_depth;
}


/* ========== Interleaved build ========== */

static void build_recursive(Tree *tree, TreeNode *node,
                             const TreeConfig *config,
                             LichessExplorer *explorer);

/**
 * OUR MOVE: Stockfish MultiPV → eval filter → recurse.
 *
 * Also queries Lichess for SAN notation and win-rate enrichment.
 */
static void build_our_move(Tree *tree, TreeNode *node,
                            const TreeConfig *config,
                            LichessExplorer *explorer) {
    /* 1. Run Stockfish MultiPV (tapers with depth) */
    int mpv_count = multipv_for_depth(config, node->depth);
    MultiPVJob mpv;
    {
        struct timespec t0;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        bool ok = engine_pool_evaluate_multipv(config->engine_pool, node->fen,
                                               config->eval_depth,
                                               mpv_count, &mpv);
        STATS_INC(config, sf_multipv_calls);
        STATS_ADD(config, sf_multipv_ms, elapsed_ms(&t0));
        if (!ok) return;
    }
    if (!mpv.success || mpv.num_lines == 0) return;

    /* Set node's own eval from the top line if not already set */
    if (!node->has_engine_eval) {
        node_set_eval(node, mpv.lines[0].eval_cp);
        if (config->db)
            rdb_put_eval(config->db, node->fen,
                         mpv.lines[0].eval_cp, mpv.lines[0].depth_reached);
    }

    /* 2. Query Lichess for SAN notation and win rates (enrichment only) */
    ExplorerResponse lichess;
    bool has_lichess = false;
    if (!config->maia_only) {
        has_lichess = query_lichess_cached(config->db, explorer, node->fen,
                                           config->use_masters, &lichess, config);
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

    /* 3. Filter candidates by eval threshold */
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

        added++;
        if (config->progress_callback)
            config->progress_callback(tree->total_nodes, child->depth, child->fen);
    }

    /* 4. Recurse into children */
    for (size_t i = 0; i < node->children_count; i++) {
        if (!tree->is_building) break;
        build_recursive(tree, node->children[i], config, explorer);
    }
}


/**
 * OPPONENT MOVE: Lichess DB + Maia supplement + engine top-1 → recurse.
 *
 * Blended strategy: Lichess moves are added first (real game data),
 * then Maia fills in until the mass target is reached.  A position
 * can end up with a mix of Lichess and Maia children.
 *
 * Children are batch-evaluated before recursion so the eval window
 * can prune immediately.
 */
static void build_opponent_move(Tree *tree, TreeNode *node,
                                 const TreeConfig *config,
                                 LichessExplorer *explorer,
                                 const EvalJob *precomputed_job) {
    char san_buf[MAX_MOVE_LENGTH];
    double mass_target = opp_mass_for_depth(config, node->depth);
    int children_added = 0;
    double mass_covered = 0.0;

    /* Maia response at function scope so engine injection can
       look up the probability for its bestmove. */
    MaiaResponse maia_resp;
    memset(&maia_resp, 0, sizeof(maia_resp));
    bool has_maia_resp = false;

    /* 1. Query Lichess explorer and add qualifying moves */
    ExplorerResponse response;
    bool has_lichess = false;

    if (!config->maia_only) {
        has_lichess = query_lichess_cached(config->db, explorer, node->fen,
                                           config->use_masters, &response, config);
        if (has_lichess && response.success) {
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
            for (size_t i = 0; i < response.move_count && total > 0; i++) {
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

                if (config->progress_callback)
                    config->progress_callback(tree->total_nodes,
                                              child->depth, child->fen);
            }
        }
    }

    /* 2. Maia supplement: fill remaining mass with predicted human moves.
       Runs when Lichess didn't cover the mass target (or had no data at
       all) and cumP is above the Maia threshold. */
    bool need_maia = config->maia_only
        || (mass_covered < mass_target &&
            (config->opp_max_children <= 0 ||
             children_added < config->opp_max_children));

    if (need_maia && config->maia &&
        (config->maia_only ||
         node->cumulative_probability >= config->maia_threshold)) {
        struct timespec t_maia;
        clock_gettime(CLOCK_MONOTONIC, &t_maia);

        bool maia_ok = maia_evaluate(config->maia, node->fen,
                                     config->maia_elo, &maia_resp);

        STATS_INC(config, maia_evals);
        STATS_ADD(config, maia_total_ms, elapsed_ms(&t_maia));

        if (maia_ok && maia_resp.success && maia_resp.move_count > 0) {
            has_maia_resp = true;
            for (int i = 0; i < maia_resp.move_count; i++) {
                const char *uci = maia_resp.moves[i].uci;
                double prob = maia_resp.moves[i].probability;
                if (prob < config->maia_min_prob) continue;

                if (config->opp_max_children > 0 &&
                    children_added >= config->opp_max_children)
                    break;
                if (mass_target > 0.0 && mass_covered >= mass_target)
                    break;

                bool exists = false;
                for (size_t c = 0; c < node->children_count; c++) {
                    if (strcmp(node->children[c]->move_uci, uci) == 0) {
                        exists = true;
                        break;
                    }
                }
                if (exists) continue;

                double new_cumul = node->cumulative_probability * prob;
                if (new_cumul < config->min_probability) continue;

                char child_fen[MAX_FEN_LENGTH];
                if (!apply_uci(node->fen, uci, child_fen, MAX_FEN_LENGTH))
                    continue;

                const char *maia_san = uci;
                if (uci_to_san(node->fen, uci, san_buf, sizeof(san_buf)))
                    maia_san = san_buf;

                TreeNode *child = make_child(node, child_fen, maia_san,
                                              uci, tree);
                if (!child) continue;

                child->move_probability = prob;
                child->cumulative_probability = new_cumul;
                children_added++;
                mass_covered += prob;

                if (config->progress_callback)
                    config->progress_callback(tree->total_nodes,
                                              child->depth, child->fen);
            }
        }
    }

    if (children_added == 0 && node->children_count == 0) return;

    /* 3. Engine top-1 injection: reuse the EvalJob from ensure_eval
     *    (passed in as precomputed_job) to avoid a redundant engine call.
     *    If the engine's best move isn't already a child, inject it. */
    if (config->engine_pool && precomputed_job &&
        precomputed_job->success && precomputed_job->bestmove[0]) {
        STATS_INC(config, injections_attempted);

        /* Check if this move already exists as a child */
        bool exists = false;
        for (size_t c = 0; c < node->children_count; c++) {
            if (strcmp(node->children[c]->move_uci, precomputed_job->bestmove) == 0) {
                if (!node->children[c]->has_engine_eval) {
                    node_set_eval(node->children[c], -precomputed_job->eval_cp);
                    if (config->db)
                        rdb_put_eval(config->db, node->children[c]->fen,
                                     -precomputed_job->eval_cp, precomputed_job->depth_reached);
                }
                exists = true;
                break;
            }
        }

        if (exists) {
            STATS_INC(config, injections_skipped_exists);
        } else {
            char child_fen[MAX_FEN_LENGTH];
            if (apply_uci(node->fen, precomputed_job->bestmove,
                          child_fen, MAX_FEN_LENGTH)) {
                FenMap *fmap = (FenMap *)tree->expanded_fens;
                if (fmap && fen_map_get(fmap, child_fen)) {
                    STATS_INC(config, injections_skipped_transposition);
                } else {
                    const char *eng_san = precomputed_job->bestmove;
                    if (uci_to_san(node->fen, precomputed_job->bestmove,
                                   san_buf, sizeof(san_buf)))
                        eng_san = san_buf;
                    TreeNode *child = make_child(node, child_fen,
                                                  eng_san,
                                                  precomputed_job->bestmove, tree);
                    if (child) {
                        child->engine_injected = true;

                        double inj_prob = 0.01;
                        if (has_maia_resp) {
                            for (int m = 0; m < maia_resp.move_count; m++) {
                                if (strcmp(maia_resp.moves[m].uci,
                                           precomputed_job->bestmove) == 0) {
                                    inj_prob = maia_resp.moves[m].probability;
                                    break;
                                }
                            }
                        }

                        child->move_probability = inj_prob;
                        child->cumulative_probability =
                            node->cumulative_probability * inj_prob;
                        node_set_eval(child, -precomputed_job->eval_cp);
                        if (config->db)
                            rdb_put_eval(config->db, child_fen,
                                         -precomputed_job->eval_cp,
                                         precomputed_job->depth_reached);
                        STATS_INC(config, injections_created);
                    }
                }
            }
        }
    }

    /* 3b. Normalize child probabilities so they sum to 1.0.
     *     Lichess, Maia, and engine injection contribute from different
     *     distributions; without normalization the missing mass biases
     *     the ECA signal downward at every opponent node. */
    {
        double prob_sum = 0.0;
        for (size_t i = 0; i < node->children_count; i++)
            prob_sum += node->children[i]->move_probability;
        if (prob_sum > 0.0 && fabs(prob_sum - 1.0) > 1e-9) {
            for (size_t i = 0; i < node->children_count; i++) {
                node->children[i]->move_probability /= prob_sum;
                node->children[i]->cumulative_probability =
                    node->cumulative_probability * node->children[i]->move_probability;
            }
        }
    }

    /* 4. Batch-evaluate children that still lack evals */
    batch_eval_children(node, config);

    /* 5. Recurse into children */
    for (size_t i = 0; i < node->children_count; i++) {
        if (!tree->is_building) break;
        build_recursive(tree, node->children[i], config, explorer);
    }
}


/**
 * Main recursive build — the single DFS that builds the tree.
 *
 * At each node:
 *   1. Check stop conditions (depth, cumP, interrupt)
 *   2. Resume support (skip explored nodes, recurse into existing children)
 *   3. Ensure this node has an eval (for window pruning); keep the EvalJob
 *      so opponent nodes can reuse the bestmove for engine injection
 *   4. Eval-window pruning (marks prune reason for annotation/deletion)
 *   5. Transposition detection (O(1) FenMap lookup; links equivalent
 *      nodes into a circular ring via next_equivalent)
 *   6. Dispatch to build_our_move or build_opponent_move
 */
static void build_recursive(Tree *tree, TreeNode *node,
                             const TreeConfig *config,
                             LichessExplorer *explorer) {
    if (!tree->is_building) return;
    if (node->depth >= config->max_depth) return;
    if (node->cumulative_probability < config->min_probability) return;
    if (config->max_nodes > 0 && tree->total_nodes >= (size_t)config->max_nodes)
        return;

    FenMap *fmap = (FenMap *)tree->expanded_fens;

    /* Resume: skip nodes that were already explored */
    if (node->children_count > 0) {
        fen_map_put(fmap, node->fen, node);
        for (size_t i = 0; i < node->children_count; i++)
            build_recursive(tree, node->children[i], config, explorer);
        return;
    }
    if (node->explored) return;

    /* Ensure this node has an eval for window pruning.
       The EvalJob is kept so opponent nodes can reuse the bestmove
       for engine injection without a redundant engine call. */
    EvalJob eval_job;
    ensure_eval(node, config, &eval_job);

    /* Eval-window pruning — mark the reason for downstream use. */
    if (node->has_engine_eval) {
        int eval_us = node_eval_for_us(node, config->play_as_white);
        if (eval_us > config->max_eval_cp) {
            node->explored = true;
            node->prune_reason = PRUNE_EVAL_TOO_HIGH;
            node->prune_eval_cp = eval_us;
            return;
        }
        if (eval_us < config->min_eval_cp) {
            node->explored = true;
            node->prune_reason = PRUNE_EVAL_TOO_LOW;
            node->prune_eval_cp = eval_us;
            return;
        }
    }

    /* Transposition detection: O(1) lookup via FenMap.  If this FEN
       was already expanded elsewhere, link this node into the
       equivalence ring and skip expansion. */
    TreeNode *canonical = fen_map_get(fmap, node->fen);
    if (canonical) {
        /* Insert into the circular equivalence ring:
           canonical → ... → node → canonical */
        if (canonical->next_equivalent) {
            node->next_equivalent = canonical->next_equivalent;
        } else {
            node->next_equivalent = canonical;
        }
        canonical->next_equivalent = node;
        node->explored = true;
        return;
    }
    fen_map_put(fmap, node->fen, node);

    bool is_our_move = (node->is_white_to_move == config->play_as_white);
    node->explored = true;

    if (is_our_move)
        build_our_move(tree, node, config, explorer);
    else
        build_opponent_move(tree, node, config, explorer, &eval_job);
}


bool tree_build(Tree *tree, const char *start_fen,
                const TreeConfig *config, LichessExplorer *explorer) {
    if (!tree || !start_fen) return false;
    if (!explorer && !config->maia_only) return false;
    if (!config->engine_pool) {
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
        ensure_eval(tree->root, &tree->config, NULL);
        if (tree->root->has_engine_eval) {
            int root_eval = node_eval_for_us(tree->root, tree->config.play_as_white);
            tree->config.min_eval_cp += root_eval;
            tree->config.max_eval_cp += root_eval;
        }
    }

    tree->expanded_fens = fen_map_create();

    build_recursive(tree, tree->root, &tree->config, explorer);

    fen_map_destroy((FenMap *)tree->expanded_fens);
    tree->expanded_fens = NULL;

    tree->build_complete = tree->is_building;
    tree->is_building = false;

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


/* ========== Ease calculation ========== */

static double ease_cp_to_q(int cp) {
    if (abs(cp) > 9000) return cp > 0 ? 1.0 : -1.0;
    double wp = 1.0 / (1.0 + exp(-0.004 * cp));
    return 2.0 * wp - 1.0;
}

static void calculate_node_ease(TreeNode *node) {
    if (!node || node->children_count == 0) return;

    int best_eval = -100000;
    bool has_evals = false;
    for (size_t i = 0; i < node->children_count; i++) {
        if (node->children[i]->has_engine_eval) {
            int eval_for_us = -node->children[i]->engine_eval_cp;
            if (eval_for_us > best_eval) best_eval = eval_for_us;
            has_evals = true;
        }
    }
    if (!has_evals) return;

    double q_max = ease_cp_to_q(best_eval);
    double sum_weighted_regret = 0.0;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_engine_eval) continue;
        if (child->move_probability < 0.01) continue;
        double q_val = ease_cp_to_q(-child->engine_eval_cp);
        double regret = fmax(0.0, q_max - q_val);
        sum_weighted_regret += pow(child->move_probability, EASE_BETA) * regret;
    }

    double ease = 1.0 - pow(sum_weighted_regret / 2.0, EASE_ALPHA);
    if (ease < 0.0) ease = 0.0;
    if (ease > 1.0) ease = 1.0;
    node_set_ease(node, ease);
}

static size_t calculate_ease_recursive(TreeNode *node) {
    if (!node) return 0;
    size_t count = 0;
    if (node->children_count > 0) {
        calculate_node_ease(node);
        if (node->has_ease) count++;
    }
    for (size_t i = 0; i < node->children_count; i++)
        count += calculate_ease_recursive(node->children[i]);
    return count;
}

size_t tree_calculate_ease(Tree *tree) {
    if (!tree || !tree->root) return 0;
    return calculate_ease_recursive(tree->root);
}


/* ========== ECA (Expected Centipawn Advantage) ========== */

double win_probability(int cp) {
    if (abs(cp) > 9000) return cp > 0 ? 1.0 : 0.0;
    return 1.0 / (1.0 + exp(-0.00368208 * cp));
}


static void compute_local_eca(TreeNode *node) {
    if (!node || node->children_count == 0) return;

    /* Find the opponent's best move (lowest eval for us = best for them).
       child->engine_eval_cp is from side-to-move perspective; at opponent-
       move nodes the children have our side to move, so low values = good
       for the opponent. */
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


int score_our_move_children(TreeNode *node,
                            const struct RepertoireConfig *config,
                            ScoredChild *best_out) {
    if (!node || !config || !best_out) return 0;

    best_out->child = NULL;
    best_out->score = -1e9;
    best_out->accumulated_eca = 0.0;

    int best_child_cp = -100000;
    for (size_t i = 0; i < node->children_count; i++) {
        if (!node->children[i]->has_engine_eval) continue;
        int cp_us = node_eval_for_us(node->children[i], config->play_as_white);
        if (cp_us > best_child_cp) best_child_cp = cp_us;
    }

    int passing = 0;
    double best_score = -1e9;
    TreeNode *best_child = NULL;
    double best_eca = 0.0;

    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_eca) continue;
        int cp_us = node_eval_for_us(child, config->play_as_white);
        if (cp_us < best_child_cp - config->max_eval_loss_cp) continue;
        passing++;
        int opp_plies = child->subtree_opp_plies > 0 ? child->subtree_opp_plies : 1;
        double avg_cpl = child->accumulated_eca / opp_plies;
        double eval_conf = (child->subtree_opp_plies > 0) ? 1.0 : config->leaf_confidence;
        double score = eval_conf * (double)cp_us + config->eca_weight * avg_cpl;
        if (score > best_score) {
            best_score = score;
            best_child = child;
            best_eca = child->accumulated_eca;
        }
    }

    /* Fallback: all filtered out → re-score without filters */
    if (passing == 0) {
        best_score = -1e9;
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (!child->has_eca) continue;
            int cp_us = node_eval_for_us(child, config->play_as_white);
            int opp_plies = child->subtree_opp_plies > 0 ? child->subtree_opp_plies : 1;
            double avg_cpl = child->accumulated_eca / opp_plies;
            double eval_conf = (child->subtree_opp_plies > 0) ? 1.0 : config->leaf_confidence;
            double score = eval_conf * (double)cp_us + config->eca_weight * avg_cpl;
            if (score > best_score) {
                best_score = score;
                best_child = child;
                best_eca = child->accumulated_eca;
            }
        }
    }

    best_out->child = best_child;
    best_out->score = best_score;
    best_out->accumulated_eca = best_eca;
    return passing;
}


static size_t calculate_eca_recursive(TreeNode *node,
                                       const RepertoireConfig *config) {
    if (!node) return 0;
    size_t count = 0;
    for (size_t i = 0; i < node->children_count; i++)
        count += calculate_eca_recursive(node->children[i], config);

    compute_local_eca(node);

    double gamma_d = pow(config->depth_discount, (double)node->depth);
    bool is_our_move = (node->is_white_to_move == config->play_as_white);

    /* Compute subtree_depth: max ply below this node */
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

    /* For transposition leaves, borrow ECA from the canonical node
       (the one in the equivalence ring that has children). */
    if (node->children_count == 0 && node->next_equivalent) {
        TreeNode *equiv = node->next_equivalent;
        while (equiv != node) {
            if (equiv->has_eca && equiv->children_count > 0) {
                node->accumulated_eca = equiv->accumulated_eca;
                node->local_cpl = equiv->local_cpl;
                node->subtree_depth = equiv->subtree_depth;
                node->subtree_opp_plies = equiv->subtree_opp_plies;
                node->has_eca = true;
                count++;
                return count;
            }
            if (!equiv->next_equivalent || equiv->next_equivalent == node)
                break;
            equiv = equiv->next_equivalent;
        }
    }

    if (node->children_count == 0) {
        node->accumulated_eca = gamma_d * node->local_cpl;
    } else if (is_our_move) {
        ScoredChild best;
        score_our_move_children(node, config, &best);
        node->accumulated_eca = best.child ? best.accumulated_eca : 0.0;
    } else {
        double future = 0.0;
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (!child->has_eca) continue;
            future += child->move_probability * child->accumulated_eca;
        }
        node->accumulated_eca = gamma_d * node->local_cpl + future;
    }

    node->has_eca = true;
    count++;
    return count;
}

size_t tree_calculate_eca(Tree *tree, const struct RepertoireConfig *config) {
    if (!tree || !tree->root || !config) return 0;
    return calculate_eca_recursive(tree->root, config);
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
    printf("  Our MultiPV: %d → %d (taper over %d ply)\n",
           tree->config.our_multipv_root,
           tree->config.our_multipv_floor,
           tree->config.taper_depth);
    printf("  Opponent: max %d children, mass %.0f%% → %.0f%% (taper over %d ply)\n",
           tree->config.opp_max_children,
           tree->config.opp_mass_root * 100.0,
           tree->config.opp_mass_floor * 100.0,
           tree->config.taper_depth);
    printf("  Eval window: [%+d, %+d] cp\n",
           tree->config.min_eval_cp, tree->config.max_eval_cp);
    printf("  Opponent source: %s\n",
           tree->config.maia_only ? "Maia-only" : "Lichess API + Maia supplement");
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
