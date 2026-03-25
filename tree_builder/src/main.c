/**
 * main.c - Repertoire Builder CLI
 * 
 * Full pipeline for automatic chess repertoire generation:
 * 
 *   1. BUILD     - Build opening tree from Lichess explorer data
 *   2. DISCOVER  - Find strong engine moves not in Lichess (MultiPV)
 *      EVAL      - Evaluate all positions with Stockfish (multithreaded)
 *   3. EASE      - Calculate ease scores (opponent mistake potential)
 *   4. SELECT    - Score and select optimal repertoire moves
 *   5. EXPORT    - Export to JSON, PGN, and SQLite
 * 
 * Usage:
 *   tree_builder [options] <output_file>
 * 
 * Options:
 *   -f, --fen <FEN>        Starting position (default: standard)
 *   -c, --color <w|b>      Play as white or black (default: white)
 *   -p, --probability <P>  Minimum probability threshold (default: 0.0001)
 *   -d, --depth <N>        Maximum depth in ply (default: 30)
 *   -e, --eval-depth <N>   Stockfish search depth (default: 20)
 *   -t, --threads <N>      Number of Stockfish engines (default: 4)
 *   -r, --ratings <R>      Rating range (default: "2000,2200,2500")
 *   -s, --speeds <S>       Time controls (default: "blitz,rapid,classical")
 *   -g, --min-games <N>    Minimum games per move (default: 10)
 *   -S, --stockfish <path> Path to Stockfish binary
 *   -D, --database <path>  Path to SQLite database (default: repertoire.db)
 *   -L, --load <file>      Load existing tree JSON instead of building
 *   --discovery             Enable Stockfish discovery pass
 *   --discovery-multipv <N> Top-N engine moves to check (default: 3)
 *   --discovery-expand <N>  Expansion depth for new branches (default: 4)
 *   -m, --masters          Use masters database
 *   --skip-build           Skip tree building (use cached data)
 *   --skip-eval            Skip engine evaluation
 *   --traps                Find and print opponent trap positions
 *   -n, --name <name>      Repertoire name (e.g. "Three Knights Petrov")
 *   --pgn <file>           Also export as PGN
 *   -v, --verbose          Verbose output
 *   -h, --help             Show help
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <sys/sysinfo.h>

#include "tree.h"
#include "lichess_api.h"
#include "serialization.h"
#include "database.h"
#include "engine_pool.h"
#include "repertoire.h"
#include "chess_logic.h"
#include "maia.h"


/* Default starting position */
#define DEFAULT_FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

/* Default Stockfish paths to search */
static const char *STOCKFISH_SEARCH_PATHS[] = {
    "./stockfish",
    "../assets/executables/stockfish-linux",
    "/usr/bin/stockfish",
    "/usr/local/bin/stockfish",
    "/usr/games/stockfish",
    NULL
};

/* Global state for signal handling */
static Tree *g_tree = NULL;
static volatile int g_interrupted = 0;


static void print_usage(const char *prog_name) {
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════╗\n");
    printf("║        Chess Repertoire Builder - tree_builder           ║\n");
    printf("╚══════════════════════════════════════════════════════════╝\n\n");
    printf("Usage: %s [options] <output.json>\n\n", prog_name);
    printf("Builds an opening repertoire by traversing the Lichess database,\n");
    printf("evaluating positions with Stockfish, calculating ease scores,\n");
    printf("and selecting moves that maximize opponent mistakes.\n\n");
    printf("Options:\n");
    printf("  -f, --fen <FEN>        Starting position FEN\n");
    printf("  -c, --color <w|b>      Play as white (w) or black (b) [default: w]\n");
    printf("  -p, --probability <P>  Min probability threshold [default: 0.0001]\n");
    printf("  -d, --depth <N>        Max tree depth in ply [default: 30]\n");
    printf("  -e, --eval-depth <N>   Stockfish search depth [default: 20]\n");
    printf("  -t, --threads <N>      Parallel Stockfish engines [default: 4]\n");
    printf("  -r, --ratings <R>      Rating buckets [default: 2000,2200,2500]\n");
    printf("  -s, --speeds <S>       Time controls [default: blitz,rapid,classical]\n");
    printf("  -g, --min-games <N>    Min games per move [default: 10]\n");
    printf("  -S, --stockfish <path> Stockfish binary path\n");
    printf("  -D, --database <path>  SQLite database path [default: repertoire.db]\n");
    printf("  -L, --load <file>      Load tree from JSON file\n");
    printf("  -m, --masters          Use masters database\n");
    printf("  --skip-build           Skip tree building (use cached DB data)\n");
    printf("  --skip-eval            Skip engine evaluation step\n");
    printf("  --token <token>        Lichess API auth token\n");
    printf("                         Also reads: $LICHESS_TOKEN, ~/.config/tree_builder/token, .lichess_token\n");
    printf("  --eval-weight <0-1>    Eval vs trickiness blend (0=pure trickiness, 1=pure eval) [default: 0.40]\n");
    printf("  --eval-guard <0-1>     Min win probability to consider a move [default: 0.35]\n");
    printf("  --depth-decay <0-1>    Depth discount for ECA (1.0=none, lower=prefer early blunders) [default: 1.0]\n");
    printf("  --max-children <N>     Max moves to explore per position (0=unlimited) [default: 0]\n");
    printf("  --mass-cutoff <0-1>    Stop adding moves after this fraction of prob mass [default: 0=off]\n");
    printf("  --min-eval <cp>        Stop DFS if our eval drops below this [default: W=0, B=-200]\n");
    printf("  --max-eval <cp>        Stop DFS if our eval exceeds this (already won) [default: W=200, B=100]\n");
    printf("  --max-eval-loss <cp>   Skip our-move candidates more than N cp worse than best [default: 50]\n");
    printf("  --relative             Make --min-eval/--max-eval relative to starting position eval\n");
    printf("\n");
    printf("Maia fallback (extends tree with NN when explorer is exhausted):\n");
    printf("  --maia-model <path>    Path to maia_rapid.onnx (enables Maia fallback)\n");
    printf("  --maia-elo <N>         Elo for Maia predictions [default: 2000]\n");
    printf("  --maia-threshold <P>   Min cumProb to trigger Maia fallback [default: 0.01]\n");
    printf("  --maia-min-prob <P>    Skip Maia moves below this probability [default: 0.02]\n");
    printf("\n");
    printf("Discovery (find strong engine moves not in Lichess database):\n");
    printf("  --discovery            Enable Stockfish discovery pass after tree build\n");
    printf("  --discovery-multipv <N>  Top-N engine moves to check per position [default: 3]\n");
    printf("  --discovery-expand <N>   Expansion depth for new branches in ply [default: 4]\n");
    printf("  -n, --name <name>      Repertoire name (shown in output/PGN headers)\n");
    printf("  --traps                Find opponent trap positions\n");
    printf("  --pgn <file>           Also export repertoire as PGN\n");
    printf("  -v, --verbose          Verbose progress output\n");
    printf("  -h, --help             Show this help\n\n");
    printf("Examples:\n");
    printf("  %s -c w -v repertoire.json\n", prog_name);
    printf("  %s -c b -e 20 -t 8 --pgn rep.pgn rep.json\n", prog_name);
    printf("  %s -L existing_tree.json --skip-build rep.json\n", prog_name);
    printf("  %s --traps -D my_data.db traps.json\n", prog_name);
    printf("\n");
}


static void progress_callback(int nodes_built, int current_depth, const char *current_fen) {
    static int last_printed = 0;
    if (nodes_built - last_printed >= 50) {
        printf("\r  [Build] Nodes: %d | Depth: %d | %.40s...    ", 
               nodes_built, current_depth, current_fen ? current_fen : "");
        fflush(stdout);
        last_printed = nodes_built;
    }
}

static void pipeline_progress(const char *stage, int current, int total) {
    if (total > 0) {
        double pct = 100.0 * current / total;
        printf("\r  [%s] %d/%d (%.1f%%)    ", stage, current, total, pct);
    } else {
        printf("\r  [%s] %d...    ", stage, current);
    }
    fflush(stdout);
}


static void signal_handler(int sig) {
    (void)sig;
    g_interrupted = 1;
    if (g_tree) tree_stop_build(g_tree);
}


/**
 * Read Lichess API token from config file.
 * Checks (in order): ~/.config/tree_builder/token, then ./.lichess_token
 * Returns heap-allocated string (caller frees) or NULL.
 */
static char* read_token_from_config(void) {
    static const char *config_paths[] = {
        NULL,  /* placeholder for ~/.config/tree_builder/token */
        ".lichess_token",
        NULL
    };

    char xdg_path[PATH_MAX];
    const char *home = getenv("HOME");
    if (home) {
        snprintf(xdg_path, sizeof(xdg_path), "%s/.config/tree_builder/token", home);
        config_paths[0] = xdg_path;
    }

    for (int i = 0; config_paths[i]; i++) {
        FILE *f = fopen(config_paths[i], "r");
        if (!f) continue;

        char buf[256];
        if (fgets(buf, sizeof(buf), f)) {
            fclose(f);
            /* Strip trailing whitespace/newline */
            size_t len = strlen(buf);
            while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r' ||
                               buf[len-1] == ' '  || buf[len-1] == '\t'))
                buf[--len] = '\0';
            if (len > 0) {
                fprintf(stderr, "  Token loaded from %s\n", config_paths[i]);
                return strdup(buf);
            }
        }
        fclose(f);
    }
    return NULL;
}


/**
 * Find Stockfish binary
 */
static const char* find_stockfish(const char *user_path) {
    if (user_path && access(user_path, X_OK) == 0) {
        return user_path;
    }
    
    for (int i = 0; STOCKFISH_SEARCH_PATHS[i]; i++) {
        if (access(STOCKFISH_SEARCH_PATHS[i], X_OK) == 0) {
            return STOCKFISH_SEARCH_PATHS[i];
        }
    }
    
    return NULL;
}


static bool parse_int(const char *s, const char *name, int *out) {
    char *end;
    errno = 0;
    long val = strtol(s, &end, 10);
    if (end == s || *end != '\0') {
        fprintf(stderr, "Error: --%s requires an integer, got '%s'\n", name, s);
        return false;
    }
    if (errno == ERANGE || val < INT_MIN || val > INT_MAX) {
        fprintf(stderr, "Error: --%s value '%s' out of range\n", name, s);
        return false;
    }
    *out = (int)val;
    return true;
}

static bool parse_double(const char *s, const char *name, double *out) {
    char *end;
    errno = 0;
    double val = strtod(s, &end);
    if (end == s || *end != '\0') {
        fprintf(stderr, "Error: --%s requires a number, got '%s'\n", name, s);
        return false;
    }
    if (errno == ERANGE) {
        fprintf(stderr, "Error: --%s value '%s' out of range\n", name, s);
        return false;
    }
    *out = val;
    return true;
}


int main(int argc, char *argv[]) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);

    /* Configuration with defaults */
    const char *start_fen = DEFAULT_FEN;
    const char *output_file = NULL;
    const char *db_path = NULL;
    char db_path_buf[256] = {0};
    const char *stockfish_path = NULL;
    const char *load_tree_file = NULL;
    const char *pgn_output = NULL;
    double min_probability = 0.0001;
    int max_depth = 30;
    int eval_depth = 20;
    int num_threads = 4;
    const char *ratings = "2000,2200,2500";
    const char *speeds = "blitz,rapid,classical";
    int min_games = 10;
    bool play_as_white = true;
    bool verbose = false;
    bool use_masters = false;
    bool skip_build = false;
    bool skip_eval = false;
    bool find_traps = false;
    const char *lichess_token = NULL;
    const char *repertoire_name = NULL;
    double eval_weight_arg = -1.0;
    double eval_guard_arg = -1.0;
    double depth_decay_arg = -1.0;
    int max_children_arg = -1;
    double mass_cutoff_arg = -1.0;
    int min_eval_arg = -99999;
    int max_eval_arg = -99999;
    int max_eval_loss_arg = -1;
    const char *maia_model_path = NULL;
    int maia_elo = 2000;
    double maia_threshold = 0.01;
    double maia_min_prob = 0.02;
    bool relative_eval = false;
    bool discovery_enabled = false;
    int discovery_multipv = -1;
    int discovery_expand = -1;

    /* Parse command line */
    static struct option long_options[] = {
        {"fen",         required_argument, 0, 'f'},
        {"color",       required_argument, 0, 'c'},
        {"probability", required_argument, 0, 'p'},
        {"depth",       required_argument, 0, 'd'},
        {"eval-depth",  required_argument, 0, 'e'},
        {"threads",     required_argument, 0, 't'},
        {"ratings",     required_argument, 0, 'r'},
        {"speeds",      required_argument, 0, 's'},
        {"min-games",   required_argument, 0, 'g'},
        {"stockfish",   required_argument, 0, 'S'},
        {"database",    required_argument, 0, 'D'},
        {"load",        required_argument, 0, 'L'},
        {"name",        required_argument, 0, 'n'},
        {"masters",     no_argument,       0, 'm'},
        {"skip-build",  no_argument,       0, 1001},
        {"skip-eval",   no_argument,       0, 1002},
        {"traps",       no_argument,       0, 1004},
        {"pgn",         required_argument, 0, 1005},
        {"token",       required_argument, 0, 1006},
        {"eval-weight",   required_argument, 0, 1007},
        {"eval-guard",    required_argument, 0, 1008},
        {"depth-decay",   required_argument, 0, 1009},
        {"max-children",  required_argument, 0, 1010},
        {"mass-cutoff",   required_argument, 0, 1011},
        {"min-eval",      required_argument, 0, 1012},
        {"max-eval",      required_argument, 0, 1013},
        {"max-eval-loss", required_argument, 0, 1014},
        {"maia-model",    required_argument, 0, 1015},
        {"maia-elo",      required_argument, 0, 1016},
        {"maia-threshold",required_argument, 0, 1017},
        {"maia-min-prob", required_argument, 0, 1018},
        {"relative",          no_argument,       0, 1022},
        {"discovery",         no_argument,       0, 1019},
        {"discovery-multipv", required_argument, 0, 1020},
        {"discovery-expand",  required_argument, 0, 1021},
        {"verbose",     no_argument,       0, 'v'},
        {"help",        no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };
    
    int opt, option_index = 0;
    while ((opt = getopt_long(argc, argv, "f:c:p:d:e:t:r:s:g:S:D:L:n:mvh", 
                              long_options, &option_index)) != -1) {
        switch (opt) {
            case 'f': start_fen = optarg; break;
            case 'c':
                play_as_white = (optarg[0] == 'w' || optarg[0] == 'W');
                break;
            case 'p':
                if (!parse_double(optarg, "probability", &min_probability)) return 1;
                if (min_probability <= 0 || min_probability > 1) {
                    fprintf(stderr, "Error: probability must be in (0, 1]\n");
                    return 1;
                }
                break;
            case 'd':
                if (!parse_int(optarg, "depth", &max_depth)) return 1;
                if (max_depth <= 0) { fprintf(stderr, "Error: depth must be > 0\n"); return 1; }
                break;
            case 'e':
                if (!parse_int(optarg, "eval-depth", &eval_depth)) return 1;
                if (eval_depth <= 0) { fprintf(stderr, "Error: eval-depth must be > 0\n"); return 1; }
                break;
            case 't':
                if (!parse_int(optarg, "threads", &num_threads)) return 1;
                if (num_threads <= 0) { fprintf(stderr, "Error: threads must be > 0\n"); return 1; }
                break;
            case 'r': ratings = optarg; break;
            case 's': speeds = optarg; break;
            case 'g':
                if (!parse_int(optarg, "min-games", &min_games)) return 1;
                if (min_games < 1) { fprintf(stderr, "Error: min-games must be >= 1\n"); return 1; }
                break;
            case 'S': stockfish_path = optarg; break;
            case 'D': db_path = optarg; break;
            case 'L': load_tree_file = optarg; break;
            case 'n': repertoire_name = optarg; break;
            case 'm': use_masters = true; break;
            case 'v': verbose = true; break;
            case 'h': print_usage(argv[0]); return 0;
            case 1001: skip_build = true; break;
            case 1002: skip_eval = true; break;
            case 1004: find_traps = true; break;
            case 1005: pgn_output = optarg; break;
            case 1006: lichess_token = optarg; break;
            case 1007: if (!parse_double(optarg, "eval-weight", &eval_weight_arg)) return 1; break;
            case 1008: if (!parse_double(optarg, "eval-guard", &eval_guard_arg)) return 1; break;
            case 1009: if (!parse_double(optarg, "depth-decay", &depth_decay_arg)) return 1; break;
            case 1010: if (!parse_int(optarg, "max-children", &max_children_arg)) return 1; break;
            case 1011: if (!parse_double(optarg, "mass-cutoff", &mass_cutoff_arg)) return 1; break;
            case 1012: if (!parse_int(optarg, "min-eval", &min_eval_arg)) return 1; break;
            case 1013: if (!parse_int(optarg, "max-eval", &max_eval_arg)) return 1; break;
            case 1014: if (!parse_int(optarg, "max-eval-loss", &max_eval_loss_arg)) return 1; break;
            case 1015: maia_model_path = optarg; break;
            case 1016: if (!parse_int(optarg, "maia-elo", &maia_elo)) return 1; break;
            case 1017: maia_threshold = atof(optarg); break;
            case 1018: maia_min_prob = atof(optarg); break;
            case 1019: discovery_enabled = true; break;
            case 1022: relative_eval = true; break;
            case 1020: if (!parse_int(optarg, "discovery-multipv", &discovery_multipv)) return 1; break;
            case 1021: if (!parse_int(optarg, "discovery-expand", &discovery_expand)) return 1; break;
            default: print_usage(argv[0]); return 1;
        }
    }
    
    if (optind < argc) {
        output_file = argv[optind];
    } else {
        fprintf(stderr, "Error: output file required\n");
        print_usage(argv[0]);
        return 1;
    }
    
    /* Resolve Lichess token: --token flag > $LICHESS_TOKEN env > config file */
    char *token_buf = NULL;
    if (!lichess_token) {
        const char *env_token = getenv("LICHESS_TOKEN");
        if (env_token && env_token[0]) {
            lichess_token = env_token;
            fprintf(stderr, "  Token loaded from $LICHESS_TOKEN\n");
        } else {
            token_buf = read_token_from_config();
            if (token_buf) lichess_token = token_buf;
        }
    }

    /* Auto-derive DB name from --name if no explicit --database given */
    if (!db_path) {
        if (repertoire_name) {
            size_t j = 0;
            for (size_t i = 0; repertoire_name[i] && j < sizeof(db_path_buf) - 4; i++) {
                char c = repertoire_name[i];
                if (c == ' ') db_path_buf[j++] = '_';
                else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                         (c >= '0' && c <= '9') || c == '-' || c == '_')
                    db_path_buf[j++] = c >= 'A' && c <= 'Z' ? c + 32 : c;
            }
            db_path_buf[j] = '\0';
            strncat(db_path_buf, ".db", sizeof(db_path_buf) - j - 1);
            db_path = db_path_buf;
        } else {
            db_path = "repertoire.db";
        }
    }

    /* Setup signal handler */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    /* Print banner */
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════╗\n");
    printf("║            Chess Repertoire Builder v2.0                 ║\n");
    printf("║                                                          ║\n");
    printf("║   Lichess Database + Stockfish + Ease Metric             ║\n");
    printf("║   Automatic repertoire with opponent mistake detection   ║\n");
    printf("╚══════════════════════════════════════════════════════════╝\n\n");
    
    printf("Configuration:\n");
    if (repertoire_name) printf("  Repertoire:       %s\n", repertoire_name);
    printf("  Playing as:       %s\n", play_as_white ? "White" : "Black");
    printf("  Starting FEN:     %.60s%s\n", start_fen, strlen(start_fen) > 60 ? "..." : "");
    printf("  Min probability:  %.4f%% (%.6f)\n", min_probability * 100.0, min_probability);
    printf("  Max depth:        %d ply (%d moves each)\n", max_depth, max_depth / 2);
    printf("  Eval depth:       %d\n", eval_depth);
    printf("  Engines:          %d (of %d cores)\n", num_threads, get_nprocs());
    printf("  Ratings:          %s\n", ratings);
    printf("  Speeds:           %s\n", speeds);
    printf("  Min games:        %d\n", min_games);
    printf("  Database:         %s\n", db_path);
    printf("  Database source:  %s\n", use_masters ? "Masters" : "Lichess");
    printf("  Output:           %s\n", output_file);
    if (pgn_output) printf("  PGN output:       %s\n", pgn_output);
    if (load_tree_file) printf("  Loading tree:     %s\n", load_tree_file);
    printf("\n");
    
    struct timespec pipeline_start, pipeline_end;
    clock_gettime(CLOCK_MONOTONIC, &pipeline_start);

    /* Declare early so goto cleanup is safe regardless of jump point */
    RepertoireResult *result = NULL;
    EnginePool *engine_pool = NULL;
    MaiaContext *maia = NULL;

    /* Create Maia context if model provided (used for build and/or discovery) */
    if (maia_model_path) {
        maia = maia_create(maia_model_path);
        if (maia) {
            printf("  Maia model loaded (elo=%d)\n", maia_elo);
        } else {
            fprintf(stderr, "  Warning: Could not load Maia model, fallback disabled\n");
        }
    }
    
    /* ================================================================
     *  STAGE 0: Initialize Database
     * ================================================================ */
    printf("[0/5] Opening database: %s\n", db_path);
    RepertoireDB *db = rdb_open(db_path);
    if (!db) {
        fprintf(stderr, "Error: Failed to open database\n");
        if (maia) maia_destroy(maia);
        return 1;
    }
    
    int cached_explorer, cached_evals, cached_ease;
    rdb_get_stats(db, &cached_explorer, &cached_evals, &cached_ease);
    printf("  Cached: %d explorer | %d evals | %d ease scores\n\n",
           cached_explorer, cached_evals, cached_ease);
    
    /* ================================================================
     *  STAGE 1: Build Opening Tree
     * ================================================================ */
    Tree *tree = NULL;
    bool needs_build = !skip_build;

    /* Try to load an existing tree: explicit --load, or auto-detect output file */
    const char *tree_source = load_tree_file ? load_tree_file : output_file;

    if (load_tree_file || (!skip_build && access(output_file, F_OK) == 0)) {
        tree = tree_load(tree_source);
        if (tree) {
            tree->config.play_as_white = play_as_white;
            tree_recalculate_probabilities(tree);

            if (tree->build_complete) {
                printf("[1/5] Tree loaded from %s (%zu nodes, complete)\n",
                       tree_source, tree->total_nodes);
                printf("  Build already complete — skipping Lichess queries.\n\n");
                needs_build = false;
            } else {
                printf("[1/5] Resuming tree build from %s (%zu nodes, incomplete)\n",
                       tree_source, tree->total_nodes);
                printf("  Continuing from unexplored leaves...\n");
            }
        } else if (load_tree_file) {
            fprintf(stderr, "Error: Failed to load tree from %s\n", load_tree_file);
            if (maia) maia_destroy(maia);
            rdb_close(db);
            return 1;
        }
    }

    if (skip_build && !tree) {
        printf("[1/5] Skipped tree building (--skip-build)\n");
        fprintf(stderr, "Error: No tree available. Build first or provide a tree file.\n");
        if (maia) maia_destroy(maia);
        rdb_close(db);
        return 1;
    }

    if (needs_build) {
        if (!tree) printf("[1/5] Building opening tree from Lichess...\n");

        LichessExplorer *explorer = lichess_explorer_create();
        if (!explorer) {
            fprintf(stderr, "Error: Failed to create Lichess explorer\n");
            if (maia) maia_destroy(maia);
            if (tree) tree_destroy(tree);
            rdb_close(db);
            return 1;
        }

        lichess_explorer_set_ratings(explorer, ratings);
        lichess_explorer_set_speeds(explorer, speeds);
        lichess_explorer_set_delay(explorer, 500);
        if (lichess_token) {
            lichess_explorer_set_token(explorer, lichess_token);
            printf("  Using Lichess auth token\n");
        } else {
            printf("  Warning: No --token provided, API may return 401\n");
        }

        if (!tree) {
            tree = tree_create();
            if (!tree) {
                fprintf(stderr, "Error: Failed to create tree\n");
                lichess_explorer_destroy(explorer);
                if (maia) maia_destroy(maia);
                rdb_close(db);
                return 1;
            }
        }

        g_tree = tree;

        TreeConfig config = tree_config_default();
        config.play_as_white = play_as_white;
        config.min_probability = min_probability;
        config.max_depth = max_depth;
        config.rating_range = ratings;
        config.speeds = speeds;
        config.min_games = min_games;
        config.use_masters = use_masters;
        if (max_children_arg >= 0) config.max_children = max_children_arg;
        if (mass_cutoff_arg >= 0.0) config.opponent_mass_target = mass_cutoff_arg;
        if (verbose) config.progress_callback = progress_callback;

        /* Maia fallback (context created earlier, just configure) */
        if (maia) {
            config.maia = maia;
            config.maia_elo = maia_elo;
            config.maia_threshold = maia_threshold;
            config.maia_min_prob = maia_min_prob;
            printf("  Maia fallback enabled (elo=%d, threshold=%.4f)\n",
                   maia_elo, maia_threshold);
        }

        struct timespec build_start, build_end;
        clock_gettime(CLOCK_MONOTONIC, &build_start);

        size_t nodes_before = tree->total_nodes;
        bool success = tree_build(tree, start_fen, &config, explorer);

        clock_gettime(CLOCK_MONOTONIC, &build_end);
        double build_time = (build_end.tv_sec - build_start.tv_sec) +
                            (build_end.tv_nsec - build_start.tv_nsec) / 1e9;

        if (verbose) printf("\r%80s\r", "");

        if (!success && !g_interrupted) {
            fprintf(stderr, "Error: Tree building failed\n");
            tree_destroy(tree);
            lichess_explorer_destroy(explorer);
            if (maia) maia_destroy(maia);
            rdb_close(db);
            return 1;
        }

        size_t new_nodes = tree->total_nodes - nodes_before;
        if (nodes_before > 1) {
            printf("  Resumed: %zu new nodes (total %zu) in %.1fs (max depth %d)\n",
                   new_nodes, tree->total_nodes, build_time, tree->max_depth_reached);
        } else {
            printf("  Built %zu nodes in %.1fs (max depth %d)\n",
                   tree->total_nodes, build_time, tree->max_depth_reached);
        }

        lichess_explorer_print_stats(explorer);
        lichess_explorer_destroy(explorer);

        /* Save tree */
        printf("  Saving tree to %s...\n", output_file);
        SerializationOptions opts = serialization_options_default();
        opts.format = FORMAT_JSON;
        opts.json_indent = 2;
        tree_save(tree, output_file, &opts);

        printf("\n");
    }
    
    if (g_interrupted) goto cleanup;
    
    /* ================================================================
     *  STAGE 2: Engine Initialization + Discovery + Evaluation
     * ================================================================ */
    
    if (!skip_eval || discovery_enabled) {
        printf("[2/5] Initializing Stockfish engine pool...\n");
        
        const char *sf_path = find_stockfish(stockfish_path);
        if (!sf_path) {
            fprintf(stderr, "  Warning: Stockfish not found.\n");
            fprintf(stderr, "  Searched: ");
            for (int i = 0; STOCKFISH_SEARCH_PATHS[i]; i++) {
                fprintf(stderr, "%s ", STOCKFISH_SEARCH_PATHS[i]);
            }
            fprintf(stderr, "\n  Use -S <path> to specify Stockfish location.\n\n");
        } else {
            printf("  Stockfish: %s\n", sf_path);
            printf("  Engines: %d | Depth: %d | Hash: 64MB each\n", num_threads, eval_depth);
            
            engine_pool = engine_pool_create(sf_path, num_threads, eval_depth);
            
            if (!engine_pool) {
                fprintf(stderr, "  Warning: Failed to create engine pool\n\n");
            } else {
                printf("\n");
            }
        }
    } else {
        printf("[2/5] Skipped engine evaluation (--skip-eval)\n\n");
    }
    
    if (g_interrupted) goto cleanup;
    
    /* Discovery pass: find strong engine moves not in Lichess database */
    if (discovery_enabled && engine_pool && tree) {
        printf("  [Discovery] Running Stockfish MultiPV pass...\n");
        
        DiscoveryConfig disc_config = discovery_config_default();
        disc_config.play_as_white = play_as_white;
        disc_config.search_depth = eval_depth;
        disc_config.min_probability = min_probability;
        disc_config.maia_elo = maia_elo;
        disc_config.maia_min_prob = maia_min_prob;
        if (discovery_multipv > 0) disc_config.multipv = discovery_multipv;
        if (discovery_expand >= 0) disc_config.expansion_depth = discovery_expand;
        if (max_eval_loss_arg >= 0) disc_config.max_eval_loss_cp = max_eval_loss_arg;
        
        int discovered = tree_discover_engine_moves(
            tree, engine_pool, maia, db, &disc_config, NULL);
        
        if (discovered > 0) {
            printf("  [Discovery] Saving updated tree to %s...\n", output_file);
            SerializationOptions disc_opts = serialization_options_default();
            disc_opts.format = FORMAT_JSON;
            disc_opts.json_indent = 2;
            tree_save(tree, output_file, &disc_opts);
        }
        printf("\n");
    } else if (discovery_enabled && !engine_pool) {
        fprintf(stderr, "  Warning: --discovery requires Stockfish, skipping.\n\n");
    }
    
    if (g_interrupted) goto cleanup;
    
    /* ================================================================
     *  STAGE 3: Generate Repertoire (Eval + Ease + Selection)
     * ================================================================ */
    printf("[3/5] Generating repertoire...\n");
    printf("  Playing as: %s\n", play_as_white ? "White" : "Black");
    
    RepertoireConfig rep_config = repertoire_config_default();
    rep_config.play_as_white = play_as_white;
    repertoire_config_set_color_defaults(&rep_config);
    strncpy(rep_config.start_fen, start_fen, sizeof(rep_config.start_fen) - 1);
    rep_config.max_depth = max_depth;
    rep_config.min_probability = min_probability;
    rep_config.min_games = min_games;
    rep_config.eval_depth = eval_depth;
    rep_config.quick_eval_depth = eval_depth > 15 ? 15 : eval_depth;
    rep_config.verbose_search = verbose;
    if (eval_weight_arg >= 0.0)  rep_config.eval_weight = eval_weight_arg;
    if (eval_guard_arg >= 0.0)  rep_config.eval_guard_threshold = eval_guard_arg;
    if (depth_decay_arg >= 0.0) rep_config.depth_discount = depth_decay_arg;
    if (min_eval_arg != -99999) rep_config.min_eval_cp = min_eval_arg;
    if (max_eval_arg != -99999) rep_config.max_eval_cp = max_eval_arg;
    if (max_eval_loss_arg >= 0) rep_config.max_eval_loss_cp = max_eval_loss_arg;
    if (max_children_arg >= 0)  rep_config.max_candidates_per_position = max_children_arg;
    rep_config.relative_eval = relative_eval;
    if (repertoire_name) {
        strncpy(rep_config.name, repertoire_name, sizeof(rep_config.name) - 1);
    }
    
    result = generate_repertoire(
        tree, db, engine_pool, &rep_config,
        verbose ? pipeline_progress : NULL
    );
    
    if (verbose) printf("\r%80s\r", "");
    
    if (result) {
        repertoire_print_summary(result);
    } else {
        fprintf(stderr, "  Warning: Repertoire generation returned no results\n");
    }
    
    printf("\n");
    
    if (g_interrupted) goto cleanup;
    
    /* ================================================================
     *  STAGE 4: Find Trap Lines (Optional)
     * ================================================================ */
    if (find_traps) {
        printf("[4/5] Finding opponent mistake-prone lines...\n");
        
        RepertoireLine trap_lines[50];
        int num_traps = find_mistake_prone_lines(tree, db, play_as_white,
                                                  trap_lines, 50);
        
        if (num_traps > 0) {
            printf("\n  Top %d trap lines (opponent likely to err):\n\n", 
                   num_traps > 20 ? 20 : num_traps);
            
            for (int i = 0; i < num_traps && i < 20; i++) {
                printf("  %2d. [trap=%.1f%% prob=%.2f%%] ", 
                       i + 1,
                       trap_lines[i].mistake_potential * 100,
                       trap_lines[i].probability * 100);
                
                for (int j = 0; j < trap_lines[i].num_moves && j < 16; j++) {
                    if (j % 2 == 0) printf("%d.", (j / 2) + 1);
                    printf("%s ", trap_lines[i].moves_san[j]);
                }
                printf("\n");
            }
        } else {
            printf("  No significant trap lines found.\n");
        }
        printf("\n");
    } else {
        printf("[4/5] Skipped trap detection (use --traps to enable)\n\n");
    }
    
    /* ================================================================
     *  STAGE 5: Export Results
     * ================================================================ */
    printf("[5/5] Exporting results...\n");
    
    /* Save tree with all data to JSON */
    SerializationOptions opts = serialization_options_default();
    opts.format = FORMAT_JSON;
    opts.json_indent = 2;
    opts.include_engine_eval = true;
    opts.include_ease = true;
    
    if (tree_save(tree, output_file, &opts)) {
        printf("  Tree saved: %s (%zu nodes)\n", output_file, tree->total_nodes);
    }
    
    /* Export repertoire JSON */
    if (result) {
        char rep_json[512];
        snprintf(rep_json, sizeof(rep_json), "%s.repertoire.json", output_file);
        if (repertoire_export_json(result, rep_json)) {
            printf("  Repertoire JSON: %s (%d moves, %d lines)\n", 
                   rep_json, result->num_moves, result->num_lines);
        }
    }
    
    /* Export PGN */
    if (pgn_output && result) {
        if (repertoire_export_pgn(result, pgn_output, &rep_config)) {
            printf("  PGN saved: %s\n", pgn_output);
        }
    }
    
    /* Database stats */
    rdb_get_stats(db, &cached_explorer, &cached_evals, &cached_ease);
    printf("  Database: %d explorer | %d evals | %d ease scores\n",
           cached_explorer, cached_evals, cached_ease);
    
    /* Engine stats */
    if (engine_pool) {
        EnginePoolStats eng_stats;
        engine_pool_get_stats(engine_pool, &eng_stats);
        printf("  Engine: %d evals (%.1f avg ms, %d failed)\n",
               eng_stats.total_evaluations, eng_stats.avg_eval_time_ms,
               eng_stats.failed_evaluations);
    }
    
    /* Total time */
    clock_gettime(CLOCK_MONOTONIC, &pipeline_end);
    double total_time = (pipeline_end.tv_sec - pipeline_start.tv_sec) + 
                        (pipeline_end.tv_nsec - pipeline_start.tv_nsec) / 1e9;
    
    printf("\n  Total time: %.1f seconds (%.1f minutes)\n", total_time, total_time / 60.0);
    printf("\nDone! Repertoire saved to %s\n\n", output_file);
    
cleanup:
    if (g_interrupted && tree && output_file) {
        printf("\n  [INTERRUPTED] Saving partial tree to %s...\n", output_file);
        SerializationOptions interrupt_opts = serialization_options_default();
        interrupt_opts.format = FORMAT_JSON;
        interrupt_opts.json_indent = 2;
        tree_save(tree, output_file, &interrupt_opts);
        printf("  Partial tree saved (%zu nodes). Re-run to resume.\n",
               tree->total_nodes);
    }
    /* Cleanup */
    if (result) repertoire_result_free(result);
    if (engine_pool) engine_pool_destroy(engine_pool);
    if (maia) maia_destroy(maia);
    if (tree) tree_destroy(tree);
    if (db) rdb_close(db);
    free(token_buf);
    
    return g_interrupted ? 130 : 0;
}
