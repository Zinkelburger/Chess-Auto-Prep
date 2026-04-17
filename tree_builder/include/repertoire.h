/**
 * repertoire.h - Automatic Repertoire Generation
 * 
 * Algorithms for traversing the move tree and selecting optimal
 * repertoire lines based on:
 * - Expectimax values (practical win probability from opponent mistakes)
 * - Engine evaluation (objective quality)
 * - Win rates from Lichess database
 * - Move probabilities (focus on likely lines)
 * 
 * The core insight: we want positions where opponents frequently
 * play suboptimal moves, giving us a practical edge beyond the
 * raw engine evaluation.
 */

#ifndef REPERTOIRE_H
#define REPERTOIRE_H

#include "tree.h"
#include "database.h"
#include "engine_pool.h"
#include <stdbool.h>

/**
 * Configuration for repertoire generation
 */
typedef struct RepertoireConfig {
    bool play_as_white;             /* Are we building for White or Black? */
    int max_depth;                  /* Maximum depth to explore (ply) */
    double min_probability;         /* Stop exploring below this cumul. probability */
    int min_games;                  /* Minimum games to consider a line */

    /* Engine settings */
    int eval_depth;                 /* Depth for engine evaluation */
    int quick_eval_depth;           /* Depth for quick/filtering evaluation */
    
    /* Expectimax settings */
    double leaf_confidence;         /* Blend factor between wp(eval) and a 0.5 neutral prior at leaves (1.0=trust eval fully, 0.0=assume 50/50). See tree.c:leaf_value(). */
    int novelty_weight;             /* 0-100: boost for rarely-played moves at our-move nodes (0=off) */
    
    /* Eval-window pruning (stop exploring lines outside this range) */
    int min_eval_cp;                 /* Stop DFS if our eval drops below this (default: -50) */
    int max_eval_cp;                 /* Stop DFS if our eval exceeds this (default: 300, already winning) */
    int max_eval_loss_cp;            /* Our-move candidates must be within this of best (default: 50) */
    bool relative_eval;              /* If true, min/max_eval_cp are relative to root position eval */

    /* Candidate selection */
    int max_candidates_per_position; /* Max moves to consider at each position */

    /* Logging */
    bool verbose_search;             /* Log each decision point during traversal */

    /* Starting FEN (for PGN export side-to-move detection, and
     * emitted as [FEN]/[SetUp "1"] when start_moves is empty) */
    char start_fen[128];

    /* SAN move sequence from standard start that leads to the root
     * position (e.g. "e4 c6 d4 d5 e5 Bf5").  When non-empty, PGN
     * export inlines these moves at the start of every game's
     * movetext and omits the [FEN] header — preferred form since
     * it reads more naturally in PGN viewers. */
    char start_moves[2048];

    /* Human-readable name for this repertoire */
    char name[128];

    /* Build performance (for PGN headers) */
    double build_time_seconds;
    int    build_nodes;
    double nodes_per_minute;
    double branching_factor;
    int    build_threads;
    int    build_eval_depth;

} RepertoireConfig;

/**
 * A single scored move in the repertoire
 */
typedef struct {
    char fen[128];                  /* Position FEN */
    char move_san[16];              /* Selected move (SAN) */
    char move_uci[16];             /* Selected move (UCI) */
    
    /* Scoring components */
    double composite_score;         /* Final composite score */
    double eval_score;              /* Normalized engine eval component */
    double ease_score;              /* Ease component (for our side) */
    double opponent_ease;           /* Ease for opponent (lower = better for us) */
    double winrate_score;           /* Win rate component */
    double probability;             /* Probability of reaching this position */
    
    /* Raw data */
    int eval_cp;                    /* Raw centipawn evaluation */
    double win_rate;                /* Raw win rate */
    uint64_t total_games;           /* Games in database */
    int depth;                      /* Depth in tree */
    
} RepertoireMove;

/**
 * A complete repertoire line (sequence of moves)
 */
typedef struct {
    char moves_san[128][16];        /* SAN moves in the line */
    char moves_uci[128][16];       /* UCI moves in the line */
    int num_moves;                  /* Number of moves */
    
    /* Aggregate scores */
    double line_score;              /* Overall line quality */
    double avg_ease_for_us;         /* Average ease when it's our turn */
    double avg_ease_for_opponent;   /* Average ease when opponent moves */
    double final_eval;              /* Engine eval at leaf */
    double probability;             /* Cumulative probability of reaching end */
    double mistake_potential;       /* How likely opponent is to err in this line */

    /* Terminal node info: why this line ended */
    int    leaf_prune_reason;       /* PruneReason of the terminal node (0 = normal leaf) */
    int    leaf_prune_eval_cp;      /* Eval that triggered pruning (from our perspective) */

    /* Opening info */
    char opening_name[128];
    char opening_eco[8];
    
} RepertoireLine;


/**
 * Result of repertoire generation
 */
typedef struct {
    RepertoireMove *moves;          /* Array of all repertoire moves */
    int num_moves;                  /* Number of moves */
    
    RepertoireLine *lines;          /* Array of complete lines */
    int num_lines;                  /* Number of lines */
    
    /* Statistics */
    int total_positions_analyzed;
    int positions_evaluated;
    double coverage_percent;        /* % of likely opponent moves we have answers for */
    double avg_eval;                /* Average evaluation across repertoire */
    double avg_ease;                /* Average ease for our positions */
    
} RepertoireResult;


/**
 * Create default repertoire configuration
 * 
 * @return Config with sensible defaults
 */
RepertoireConfig repertoire_config_default(void);

/**
 * Generate a complete repertoire from a tree
 * 
 * This is the main entry point. It:
 * 1. Loads DB-cached evals into nodes
 * 2. Computes expectimax values (practical win probability)
 * 3. Scores and selects moves
 * 4. Extracts complete lines
 * 
 * @param tree The opening tree (with Lichess data)
 * @param db Database for caching
 * @param engine_pool Stockfish pool for evaluation
 * @param config Repertoire configuration
 * @param progress Optional progress callback
 * @return RepertoireResult (caller must free with repertoire_result_free)
 */
RepertoireResult* generate_repertoire(Tree *tree, RepertoireDB *db,
                                       EnginePool *engine_pool,
                                       const RepertoireConfig *config,
                                       void (*progress)(const char *stage, 
                                                         int current, int total));

/**
 * Free a repertoire result
 */
void repertoire_result_free(RepertoireResult *result);

/**
 * Find the most "mistake-prone" lines for the opponent
 * 
 * Returns lines sorted by how likely the opponent is to err.
 * Uses high engine disparity
 * between popular and best moves.
 * 
 * @param tree The opening tree
 * @param db Database
 * @param play_as_white Whether we play White
 * @param out_lines Output array of lines
 * @param max_lines Maximum lines to return
 * @return Number of lines found
 */
int find_mistake_prone_lines(const Tree *tree, RepertoireDB *db,
                              bool play_as_white,
                              RepertoireLine *out_lines, int max_lines);

/**
 * Calculate the "trap score" for a position
 * 
 * Measures how much the popular move (from database) differs from
 * the objectively best move. High trap score = opponents frequently
 * play suboptimal moves here.
 * 
 * @param node The tree node
 * @param db Database with evaluations
 * @return Trap score [0,1], or -1 if insufficient data
 */
double calculate_trap_score(const TreeNode *node, RepertoireDB *db);


/**
 * A trap line found anywhere in the tree (not limited to the repertoire).
 * Includes detailed annotation data explaining why the position is tricky.
 */
typedef struct {
    char moves_san[128][16];    /* Path from root to the trap position */
    int num_moves;              /* Length of path */

    double trap_score;          /* Composite trap score [0,1] */
    double popular_prob;        /* Probability opponent plays the bad move */
    char popular_move[16];      /* SAN of the popular (bad) move */
    char best_move[16];         /* SAN of the objectively best move */
    int popular_eval_cp;        /* Eval after popular move (from our perspective) */
    int best_eval_cp;           /* Eval after best move (from our perspective) */
    int eval_diff_cp;           /* best_eval - popular_eval (centipawn gain) */
    double cumulative_prob;     /* Probability of reaching this position */

    /* Trick surplus: how much better we do in practice (expectimax)
     * than the raw engine eval predicts.  V - wp(eval_for_us).
     * Positive = subtree is trickier than the eval suggests.
     * This compounds through the tree: multiple tricky positions
     * along a line all contribute to a higher surplus. */
    double trick_surplus;
    double expectimax_value;    /* Raw V at this node */
    double wp_eval;             /* wp(eval_for_us) at this node */
} TrapLineInfo;


/**
 * Search the entire tree for tricky opponent positions.
 *
 * Unlike find_mistake_prone_lines (which uses RepertoireLine and
 * minimal annotation), this returns TrapLineInfo with full detail
 * about the popular-vs-best move discrepancy for PGN annotation.
 *
 * @param tree   The opening tree (full, not just repertoire)
 * @param db     Database with cached evaluations
 * @param play_as_white  Whether we are White
 * @param out_lines  Output array (caller-allocated)
 * @param max_lines  Capacity of out_lines
 * @return Number of trap lines found (sorted by trap_score descending)
 */
int find_trap_lines(const Tree *tree, RepertoireDB *db,
                    bool play_as_white,
                    TrapLineInfo *out_lines, int max_lines);

/**
 * Export trap lines to an annotated PGN file.
 *
 * Each game in the PGN is a line leading to a tricky position.
 * The final comment explains WHY it is tricky: which move opponents
 * play, how often, and how much eval they give away.
 *
 * @param lines      Array of TrapLineInfo from find_trap_lines
 * @param num_lines  Number of lines
 * @param filename   Output .pgn path
 * @param config     Repertoire config (for start_moves, FEN, etc.)
 * @return true on success
 */
bool export_traps_pgn(const TrapLineInfo *lines, int num_lines,
                      const char *filename,
                      const RepertoireConfig *config);


/**
 * Export repertoire to PGN with annotations
 * 
 * Creates a PGN file with:
 * - Main line = our chosen moves
 * - Variations = likely opponent responses
 * - Comments = eval, probability
 * 
 * @param result The repertoire result
 * @param filename Output PGN file
 * @param config Configuration used
 * @return true on success
 */
bool repertoire_export_pgn(const RepertoireResult *result, 
                            const char *filename,
                            const RepertoireConfig *config);

/**
 * Export repertoire to JSON
 * 
 * @param result The repertoire result
 * @param filename Output JSON file
 * @return true on success
 */
bool repertoire_export_json(const RepertoireResult *result, const char *filename);

/**
 * Print repertoire summary to stdout
 */
void repertoire_print_summary(const RepertoireResult *result);

#endif /* REPERTOIRE_H */
