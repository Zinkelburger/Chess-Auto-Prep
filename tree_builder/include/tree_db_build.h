/**
 * tree_db_build.h - Build opening trees from PGN frequency maps (Phase 1)
 *
 * Materializes a PgnFreqMap into a Tree via BFS without Maia/Stockfish
 * expansion.  Eval enrichment runs later in the normal pipeline.
 */

#ifndef TREE_DB_BUILD_H
#define TREE_DB_BUILD_H

#include "tree.h"
#include "pgn_freq.h"
#include <stdbool.h>

typedef struct DbBuildConfig {
    const char *start_fen;
    bool play_as_white;
    int max_depth;
    double min_probability;
    int db_min_games;      /* default 5 */
    double db_min_prob;    /* default 0.05 */
    int max_nodes;         /* 0 = unlimited */
} DbBuildConfig;

/** BFS tree build from a merged PGN frequency map. */
bool tree_build_from_freqmap(Tree *tree, const PgnFreqMap *freq,
                             const DbBuildConfig *cfg);

/** Counters from tree_enrich_evals(). */
typedef struct EvalEnrichStats {
    int total_nodes;   /* nodes that lacked eval at start */
    int cache_hits;    /* rdb_get_eval */
    int ext_hits;      /* external eval chain (Lichess DB, ChessDB, …) */
    int sf_evals;      /* Stockfish evaluations performed */
    int failed;        /* nodes still without eval after enrichment */
} EvalEnrichStats;

/**
 * Batch-evaluate nodes missing engine evals (DB cache → external → Stockfish).
 * Requires config->engine_pool and config->eval_depth for Stockfish fallback.
 */
bool tree_enrich_evals(Tree *tree, const TreeConfig *config,
                       EvalEnrichStats *stats);

#endif /* TREE_DB_BUILD_H */
