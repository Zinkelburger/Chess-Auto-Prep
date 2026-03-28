/**
 * main.c - Repertoire Builder CLI
 *
 * Pipeline:
 *   0. INIT      - Open database + create Stockfish engine pool
 *   1. BUILD     - Interleaved Lichess + Stockfish tree construction
 *   2. SELECT    - Ease + ECA calculation → repertoire move selection
 *   3. TRAPS     - (optional) find opponent trap positions
 *   4. EXPORT    - Save PGN, tree (for resume), and database
 *
 * Usage:
 *   tree_builder [options] <name>
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


#define DEFAULT_FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

static char g_exe_dir[PATH_MAX] = {0};

static void resolve_exe_dir(void) {
    ssize_t len = readlink("/proc/self/exe", g_exe_dir, sizeof(g_exe_dir) - 1);
    if (len <= 0) { g_exe_dir[0] = '.'; g_exe_dir[1] = '\0'; return; }
    g_exe_dir[len] = '\0';
    char *slash = strrchr(g_exe_dir, '/');
    if (slash) *slash = '\0';
    else { g_exe_dir[0] = '.'; g_exe_dir[1] = '\0'; }
}

static const char *STOCKFISH_SEARCH_PATHS[] = {
    "./stockfish",
    "../assets/executables/stockfish-linux",
    "/usr/bin/stockfish",
    "/usr/local/bin/stockfish",
    "/usr/games/stockfish",
    NULL
};

static const char *MAIA_SEARCH_PATHS[] = {
    "./maia_rapid.onnx",
    "../assets/maia_rapid.onnx",
    NULL
};

static Tree *g_tree = NULL;
static volatile int g_interrupted = 0;


static void print_usage(const char *prog_name) {
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════╗\n");
    printf("║        Chess Repertoire Builder - tree_builder           ║\n");
    printf("╚══════════════════════════════════════════════════════════╝\n\n");
    printf("Usage: %s [options] <name>\n\n", prog_name);
    printf("Builds an opening repertoire by interleaving Lichess database\n");
    printf("queries with Stockfish evaluation, pruning immediately by eval.\n\n");
    printf("The <name> argument is the base name for all output files:\n");
    printf("  <name>.pgn        Repertoire lines (primary output)\n");
    printf("  <name>.tree.json  Tree state (for resumption)\n");
    printf("  <name>.db         Cached evals and explorer data\n\n");
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
    printf("  -D, --database <path>  SQLite database path [default: <name>.db]\n");
    printf("  -L, --load <file>      Load tree from a different JSON file\n");
    printf("  -m, --masters          Use masters database\n");
    printf("  --skip-build           Skip tree building (use existing tree)\n");
    printf("  --token <token>        Lichess API auth token\n");
    printf("                         Also reads: $LICHESS_TOKEN, ~/.config/tree_builder/token, .lichess_token\n");
    printf("\n");
    printf("Our-move candidates (engine-driven):\n");
    printf("  --our-multipv-root <N> MultiPV at root (explore broadly) [default: 10]\n");
    printf("  --our-multipv-floor <N> MultiPV floor (deep positions) [default: 2]\n");
    printf("  --taper-depth <N>      Ply at which MultiPV bottoms out [default: 8]\n");
    printf("  --max-eval-loss <cp>   Skip candidates more than N cp worse than best [default: 50]\n");
    printf("\n");
    printf("Opponent-move selection (Lichess-driven):\n");
    printf("  --opp-max-children <N> Max opponent responses per position [default: 6]\n");
    printf("  --opp-mass-root <0-1>  Mass target at root (explore broadly) [default: 0.95]\n");
    printf("  --opp-mass-floor <0-1> Mass target floor (deep positions) [default: 0.50]\n");
    printf("\n");
    printf("Eval window pruning:\n");
    printf("  --min-eval <cp>        Stop DFS if our eval drops below this [default: color-dependent]\n");
    printf("  --max-eval <cp>        Stop DFS if our eval exceeds this [default: color-dependent]\n");
    printf("  --relative             Make --min-eval/--max-eval relative to root eval\n");
    printf("\n");
    printf("ECA scoring (move selection phase):\n");
    printf("  --eval-weight <0-1>    Eval vs trickiness blend [default: 0.40]\n");
    printf("  --eval-guard <0-1>     Min win probability to consider a move [default: 0.35]\n");
    printf("  --depth-decay <0-1>    Depth discount for ECA [default: 1.0]\n");
    printf("\n");
    printf("Maia fallback (extends tree when explorer is exhausted):\n");
    printf("  --maia-model <path>    Path to maia_rapid.onnx [default: auto-detect]\n");
    printf("  --maia-elo <N>         Elo for Maia predictions [default: 2000]\n");
    printf("  --maia-threshold <P>   Min cumProb to trigger Maia [default: 0.01]\n");
    printf("  --maia-min-prob <P>    Skip Maia moves below this [default: 0.02]\n");
    printf("  --maia-only            Use Maia exclusively for opponent moves (no Lichess API)\n");
    printf("\n");
    printf("Output:\n");
    printf("  -n, --name <name>      Repertoire name (shown in PGN headers)\n");
    printf("  --traps                Find opponent trap positions\n");
    printf("  -v, --verbose          Verbose progress output\n");
    printf("  -h, --help             Show this help\n\n");
    printf("Examples:\n");
    printf("  %s -c w -e 20 -t 4 -v repertoire\n", prog_name);
    printf("  %s -c b -f \"FEN\" -n \"Modern Benoni\" modern_benoni\n", prog_name);
    printf("  %s -c b -v modern_benoni   # resumes from modern_benoni.tree.json\n", prog_name);
    printf("\n");
}


static void progress_callback(int nodes_built, int current_depth,
                                const char *current_fen) {
    static int last_printed = -1;
    if (nodes_built == 0) last_printed = -1;
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


static char* read_token_from_config(void) {
    static const char *config_paths[] = { NULL, ".lichess_token", NULL };
    char xdg_path[PATH_MAX];
    const char *home = getenv("HOME");
    if (home) {
        snprintf(xdg_path, sizeof(xdg_path),
                 "%s/.config/tree_builder/token", home);
        config_paths[0] = xdg_path;
    }
    for (int i = 0; config_paths[i]; i++) {
        FILE *f = fopen(config_paths[i], "r");
        if (!f) continue;
        char buf[256];
        if (fgets(buf, sizeof(buf), f)) {
            fclose(f);
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


static const char* find_stockfish(const char *user_path) {
    static char buf[PATH_MAX];
    if (user_path && access(user_path, X_OK) == 0) return user_path;
    /* Check next to binary first */
    snprintf(buf, sizeof(buf), "%s/stockfish", g_exe_dir);
    if (access(buf, X_OK) == 0) return buf;
    for (int i = 0; STOCKFISH_SEARCH_PATHS[i]; i++) {
        if (access(STOCKFISH_SEARCH_PATHS[i], X_OK) == 0)
            return STOCKFISH_SEARCH_PATHS[i];
    }
    return NULL;
}

static const char* find_maia_model(const char *user_path) {
    static char buf[PATH_MAX];
    if (user_path && access(user_path, R_OK) == 0) return user_path;
    /* Check next to binary first */
    snprintf(buf, sizeof(buf), "%s/maia_rapid.onnx", g_exe_dir);
    if (access(buf, R_OK) == 0) return buf;
    for (int i = 0; MAIA_SEARCH_PATHS[i]; i++) {
        if (access(MAIA_SEARCH_PATHS[i], R_OK) == 0)
            return MAIA_SEARCH_PATHS[i];
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
    resolve_exe_dir();

    /* Configuration with defaults */
    const char *start_fen = DEFAULT_FEN;
    const char *base_name = NULL;
    char pgn_path[PATH_MAX] = {0};
    char tree_path[PATH_MAX] = {0};
    const char *db_path = NULL;
    char db_path_buf[PATH_MAX] = {0};
    const char *stockfish_path = NULL;
    const char *load_tree_file = NULL;
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
    bool find_traps = false;
    const char *lichess_token = NULL;
    const char *repertoire_name = NULL;
    const char *maia_model_path = NULL;
    int maia_elo = 2000;
    double maia_threshold = 0.01;
    double maia_min_prob = 0.02;
    bool maia_only = false;
    bool relative_eval = false;

    /* Our-move overrides (-1 = use default) */
    int our_multipv_root_arg = -1;
    int our_multipv_floor_arg = -1;
    int taper_depth_arg = -1;
    int max_eval_loss_arg = -1;

    /* Opponent-move overrides */
    int opp_max_children_arg = -1;
    double opp_mass_root_arg = -1.0;
    double opp_mass_floor_arg = -1.0;

    /* Eval window overrides */
    int min_eval_arg = -99999;
    int max_eval_arg = -99999;

    /* ECA scoring overrides */
    double eval_weight_arg = -1.0;
    double eval_guard_arg = -1.0;
    double depth_decay_arg = -1.0;

    static struct option long_options[] = {
        {"fen",              required_argument, 0, 'f'},
        {"color",            required_argument, 0, 'c'},
        {"probability",      required_argument, 0, 'p'},
        {"depth",            required_argument, 0, 'd'},
        {"eval-depth",       required_argument, 0, 'e'},
        {"threads",          required_argument, 0, 't'},
        {"ratings",          required_argument, 0, 'r'},
        {"speeds",           required_argument, 0, 's'},
        {"min-games",        required_argument, 0, 'g'},
        {"stockfish",        required_argument, 0, 'S'},
        {"database",         required_argument, 0, 'D'},
        {"load",             required_argument, 0, 'L'},
        {"name",             required_argument, 0, 'n'},
        {"masters",          no_argument,       0, 'm'},
        {"skip-build",       no_argument,       0, 1001},
        {"traps",            no_argument,       0, 1004},
        {"token",            required_argument, 0, 1006},
        /* Our-move */
        {"our-multipv-root", required_argument, 0, 2001},
        {"our-multipv-floor",required_argument, 0, 2002},
        {"taper-depth",      required_argument, 0, 2004},
        {"max-eval-loss",    required_argument, 0, 2005},
        /* Opponent-move */
        {"opp-max-children", required_argument, 0, 2010},
        {"opp-mass-root",    required_argument, 0, 2011},
        {"opp-mass-floor",   required_argument, 0, 2012},
        /* Eval window */
        {"min-eval",         required_argument, 0, 2020},
        {"max-eval",         required_argument, 0, 2021},
        {"relative",         no_argument,       0, 2022},
        /* ECA scoring */
        {"eval-weight",      required_argument, 0, 2030},
        {"eval-guard",       required_argument, 0, 2031},
        {"depth-decay",      required_argument, 0, 2032},
        /* Maia */
        {"maia-model",       required_argument, 0, 3001},
        {"maia-elo",         required_argument, 0, 3002},
        {"maia-threshold",   required_argument, 0, 3003},
        {"maia-min-prob",    required_argument, 0, 3004},
        {"maia-only",        no_argument,       0, 3005},
        /* General */
        {"verbose",          no_argument,       0, 'v'},
        {"help",             no_argument,       0, 'h'},
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
                    fprintf(stderr, "Error: probability must be in (0, 1]\n"); return 1;
                }
                break;
            case 'd':
                if (!parse_int(optarg, "depth", &max_depth)) return 1;
                break;
            case 'e':
                if (!parse_int(optarg, "eval-depth", &eval_depth)) return 1;
                break;
            case 't':
                if (!parse_int(optarg, "threads", &num_threads)) return 1;
                break;
            case 'r': ratings = optarg; break;
            case 's': speeds = optarg; break;
            case 'g':
                if (!parse_int(optarg, "min-games", &min_games)) return 1;
                break;
            case 'S': stockfish_path = optarg; break;
            case 'D': db_path = optarg; break;
            case 'L': load_tree_file = optarg; break;
            case 'n': repertoire_name = optarg; break;
            case 'm': use_masters = true; break;
            case 'v': verbose = true; break;
            case 'h': print_usage(argv[0]); return 0;
            case 1001: skip_build = true; break;
            case 1004: find_traps = true; break;
            case 1006: lichess_token = optarg; break;
            /* Our-move */
            case 2001: if (!parse_int(optarg, "our-multipv-root", &our_multipv_root_arg)) return 1; break;
            case 2002: if (!parse_int(optarg, "our-multipv-floor", &our_multipv_floor_arg)) return 1; break;
            case 2004: if (!parse_int(optarg, "taper-depth", &taper_depth_arg)) return 1; break;
            case 2005: if (!parse_int(optarg, "max-eval-loss", &max_eval_loss_arg)) return 1; break;
            /* Opponent-move */
            case 2010: if (!parse_int(optarg, "opp-max-children", &opp_max_children_arg)) return 1; break;
            case 2011: if (!parse_double(optarg, "opp-mass-root", &opp_mass_root_arg)) return 1; break;
            case 2012: if (!parse_double(optarg, "opp-mass-floor", &opp_mass_floor_arg)) return 1; break;
            /* Eval window */
            case 2020: if (!parse_int(optarg, "min-eval", &min_eval_arg)) return 1; break;
            case 2021: if (!parse_int(optarg, "max-eval", &max_eval_arg)) return 1; break;
            case 2022: relative_eval = true; break;
            /* ECA */
            case 2030: if (!parse_double(optarg, "eval-weight", &eval_weight_arg)) return 1; break;
            case 2031: if (!parse_double(optarg, "eval-guard", &eval_guard_arg)) return 1; break;
            case 2032: if (!parse_double(optarg, "depth-decay", &depth_decay_arg)) return 1; break;
            /* Maia */
            case 3001: maia_model_path = optarg; break;
            case 3002: if (!parse_int(optarg, "maia-elo", &maia_elo)) return 1; break;
            case 3003: if (!parse_double(optarg, "maia-threshold", &maia_threshold)) return 1; break;
            case 3004: if (!parse_double(optarg, "maia-min-prob", &maia_min_prob)) return 1; break;
            case 3005: maia_only = true; break;
            default: print_usage(argv[0]); return 1;
        }
    }

    if (optind < argc) {
        base_name = argv[optind];
    } else {
        fprintf(stderr, "Error: base name required\n");
        print_usage(argv[0]);
        return 1;
    }

    /* Strip common extensions if the user passed e.g. "foo.json" or "foo.pgn" */
    static char base_buf[512];
    {
        size_t len = strlen(base_name);
        const char *exts[] = { ".tree.json", ".json", ".pgn", ".db", NULL };
        for (int i = 0; exts[i]; i++) {
            size_t elen = strlen(exts[i]);
            if (len > elen && strcmp(base_name + len - elen, exts[i]) == 0) {
                memcpy(base_buf, base_name, len - elen);
                base_buf[len - elen] = '\0';
                base_name = base_buf;
                break;
            }
        }
    }

    snprintf(pgn_path, sizeof(pgn_path), "%s.pgn", base_name);
    snprintf(tree_path, sizeof(tree_path), "%s.tree.json", base_name);

    /* Resolve Lichess token */
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

    /* Auto-derive DB path from base name */
    if (!db_path) {
        snprintf(db_path_buf, sizeof(db_path_buf), "%s.db", base_name);
        db_path = db_path_buf;
    }

    /* Signal handlers */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    /* Banner */
    printf("\n");
    printf("╔══════════════════════════════════════════════════════════╗\n");
    printf("║            Chess Repertoire Builder v3.0                 ║\n");
    printf("║                                                          ║\n");
    printf("║   Interleaved Lichess + Stockfish build                  ║\n");
    printf("║   Engine-driven our-move selection, DB-driven opponent   ║\n");
    printf("╚══════════════════════════════════════════════════════════╝\n\n");

    printf("Configuration:\n");
    if (repertoire_name) printf("  Repertoire:       %s\n", repertoire_name);
    printf("  Playing as:       %s\n", play_as_white ? "White" : "Black");
    printf("  Starting FEN:     %.60s%s\n", start_fen,
           strlen(start_fen) > 60 ? "..." : "");
    printf("  Min probability:  %.4f%% (%.6f)\n",
           min_probability * 100.0, min_probability);
    printf("  Max depth:        %d ply (%d moves each)\n",
           max_depth, max_depth / 2);
    printf("  Eval depth:       %d\n", eval_depth);
    printf("  Engines:          %d (of %d cores)\n", num_threads, get_nprocs());
    printf("  Ratings:          %s\n", ratings);
    printf("  Speeds:           %s\n", speeds);
    printf("  Min games:        %d\n", min_games);
    printf("  Database:         %s\n", db_path);
    printf("  Opponent source:  %s\n",
           maia_only ? "Maia-only (no API)" :
           use_masters ? "Masters" : "Lichess");
    printf("  Output:           %s\n", pgn_path);
    printf("  Tree state:       %s\n", tree_path);
    if (load_tree_file) printf("  Loading tree:     %s\n", load_tree_file);
    printf("\n");

    struct timespec pipeline_start, pipeline_end;
    clock_gettime(CLOCK_MONOTONIC, &pipeline_start);

    RepertoireResult *result = NULL;
    EnginePool *engine_pool = NULL;
    MaiaContext *maia = NULL;

    /* Auto-detect or use explicit Maia model path */
    const char *resolved_maia = find_maia_model(maia_model_path);
    if (resolved_maia) {
        maia = maia_create(resolved_maia);
        if (maia)
            printf("  Maia model: %s (elo=%d)\n", resolved_maia, maia_elo);
        else
            fprintf(stderr, "  Warning: Could not load Maia model from %s\n",
                    resolved_maia);
    } else if (maia_model_path) {
        fprintf(stderr, "  Warning: Maia model not found at %s\n",
                maia_model_path);
    }

    if (maia_only && !maia) {
        fprintf(stderr, "Error: --maia-only requires a working Maia model.\n");
        fprintf(stderr, "  Use --maia-model <path> or place maia_rapid.onnx next to the binary.\n");
        return 1;
    }

    /* ================================================================
     *  STAGE 0: Initialize Database + Engine Pool
     * ================================================================ */
    printf("[0/4] Opening database: %s\n", db_path);
    RepertoireDB *db = rdb_open(db_path);
    if (!db) {
        fprintf(stderr, "Error: Failed to open database\n");
        if (maia) maia_destroy(maia);
        return 1;
    }

    int cached_explorer, cached_evals, cached_ease;
    rdb_get_stats(db, &cached_explorer, &cached_evals, &cached_ease);
    printf("  Cached: %d explorer | %d evals | %d ease scores\n",
           cached_explorer, cached_evals, cached_ease);

    if (!skip_build) {
        const char *sf_path = find_stockfish(stockfish_path);
        if (!sf_path) {
            fprintf(stderr, "Error: Stockfish not found. Use -S <path>.\n");
            fprintf(stderr, "  Searched: ");
            for (int i = 0; STOCKFISH_SEARCH_PATHS[i]; i++)
                fprintf(stderr, "%s ", STOCKFISH_SEARCH_PATHS[i]);
            fprintf(stderr, "\n");
            if (maia) maia_destroy(maia);
            rdb_close(db);
            return 1;
        }

        printf("  Stockfish: %s\n", sf_path);
        printf("  Engines: %d | Depth: %d\n", num_threads, eval_depth);

        engine_pool = engine_pool_create(sf_path, num_threads, eval_depth);
        if (!engine_pool) {
            fprintf(stderr, "Error: Failed to create engine pool\n");
            if (maia) maia_destroy(maia);
            rdb_close(db);
            return 1;
        }
    }
    printf("\n");

    /* ================================================================
     *  STAGE 1: Build Opening Tree (interleaved Lichess + Stockfish)
     * ================================================================ */
    Tree *tree = NULL;
    bool needs_build = !skip_build;

    const char *tree_source = load_tree_file ? load_tree_file : tree_path;

    if (load_tree_file || (!skip_build && access(tree_path, F_OK) == 0)) {
        tree = tree_load(tree_source);
        if (tree) {
            tree->config.play_as_white = play_as_white;
            tree_recalculate_probabilities(tree);

            if (tree->build_complete) {
                printf("[1/4] Tree loaded from %s (%zu nodes, complete)\n",
                       tree_source, tree->total_nodes);
                printf("  Build already complete — skipping.\n\n");
                needs_build = false;
            } else {
                printf("[1/4] Resuming tree build from %s (%zu nodes, incomplete)\n",
                       tree_source, tree->total_nodes);
                printf("  Continuing from unexplored leaves...\n");
            }
        } else if (load_tree_file) {
            fprintf(stderr, "Error: Failed to load tree from %s\n", load_tree_file);
            if (engine_pool) engine_pool_destroy(engine_pool);
            if (maia) maia_destroy(maia);
            rdb_close(db);
            return 1;
        }
    }

    if (skip_build && !tree) {
        printf("[1/4] Skipped tree building (--skip-build)\n");
        fprintf(stderr, "Error: No tree available.\n");
        if (engine_pool) engine_pool_destroy(engine_pool);
        if (maia) maia_destroy(maia);
        rdb_close(db);
        return 1;
    }

    if (needs_build) {
        if (!tree) printf("[1/4] Building opening tree (%s)...\n",
                          maia_only ? "Maia-only" : "interleaved");

        LichessExplorer *explorer = NULL;
        if (!maia_only) {
            explorer = lichess_explorer_create();
            if (!explorer) {
                fprintf(stderr, "Error: Failed to create Lichess explorer\n");
                if (engine_pool) engine_pool_destroy(engine_pool);
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
        } else {
            printf("  Maia-only mode: no Lichess API queries\n");
        }

        if (!tree) {
            tree = tree_create();
            if (!tree) {
                fprintf(stderr, "Error: Failed to create tree\n");
                lichess_explorer_destroy(explorer);
                if (engine_pool) engine_pool_destroy(engine_pool);
                if (maia) maia_destroy(maia);
                rdb_close(db);
                return 1;
            }
        }

        g_tree = tree;

        /* Configure tree build */
        TreeConfig config = tree_config_default();
        config.play_as_white = play_as_white;
        tree_config_set_color_defaults(&config);
        config.min_probability = min_probability;
        config.max_depth = max_depth;
        config.engine_pool = engine_pool;
        config.db = db;
        config.eval_depth = eval_depth;
        config.rating_range = ratings;
        config.speeds = speeds;
        config.min_games = min_games;
        config.use_masters = use_masters;

        /* Apply CLI overrides */
        if (our_multipv_root_arg > 0) config.our_multipv_root = our_multipv_root_arg;
        if (our_multipv_floor_arg > 0) config.our_multipv_floor = our_multipv_floor_arg;
        if (taper_depth_arg >= 0) config.taper_depth = taper_depth_arg;
        if (max_eval_loss_arg >= 0) config.max_eval_loss_cp = max_eval_loss_arg;
        if (opp_max_children_arg >= 0) config.opp_max_children = opp_max_children_arg;
        if (opp_mass_root_arg >= 0.0) config.opp_mass_root = opp_mass_root_arg;
        if (opp_mass_floor_arg >= 0.0) config.opp_mass_floor = opp_mass_floor_arg;
        if (min_eval_arg != -99999) config.min_eval_cp = min_eval_arg;
        if (max_eval_arg != -99999) config.max_eval_cp = max_eval_arg;
        config.relative_eval = relative_eval;

        if (maia) {
            config.maia = maia;
            config.maia_elo = maia_elo;
            config.maia_threshold = maia_threshold;
            config.maia_min_prob = maia_min_prob;
            config.maia_only = maia_only;
        }

        if (verbose) config.progress_callback = progress_callback;

        printf("  Our moves:  MultiPV %d → %d (taper over %d ply), %dcp loss max\n",
               config.our_multipv_root, config.our_multipv_floor,
               config.taper_depth, config.max_eval_loss_cp);
        printf("  Opponent:   max %d children, mass %.0f%% → %.0f%%\n",
               config.opp_max_children,
               config.opp_mass_root * 100.0, config.opp_mass_floor * 100.0);
        printf("  Eval window: [%+d, %+d] cp%s\n",
               config.min_eval_cp, config.max_eval_cp,
               relative_eval ? " (relative)" : "");

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
            if (engine_pool) engine_pool_destroy(engine_pool);
            if (maia) maia_destroy(maia);
            rdb_close(db);
            return 1;
        }

        size_t new_nodes = tree->total_nodes - nodes_before;
        if (nodes_before > 1)
            printf("  Resumed: %zu new nodes (total %zu) in %.1fs (max depth %d)\n",
                   new_nodes, tree->total_nodes, build_time,
                   tree->max_depth_reached);
        else
            printf("  Built %zu nodes in %.1fs (max depth %d)\n",
                   tree->total_nodes, build_time, tree->max_depth_reached);

        if (explorer) {
            lichess_explorer_print_stats(explorer);
            lichess_explorer_destroy(explorer);
        }

        printf("  Saving tree to %s...\n", tree_path);
        SerializationOptions opts = serialization_options_default();
        opts.format = FORMAT_JSON;
        opts.json_indent = 2;
        tree_save(tree, tree_path, &opts);
        printf("\n");
    }

    if (g_interrupted) goto cleanup;

    /* ================================================================
     *  STAGE 2: Generate Repertoire (Ease + ECA + Selection)
     * ================================================================ */
    printf("[2/4] Generating repertoire...\n");

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
    if (eval_weight_arg >= 0.0) rep_config.eval_weight = eval_weight_arg;
    if (eval_guard_arg >= 0.0) rep_config.eval_guard_threshold = eval_guard_arg;
    if (depth_decay_arg >= 0.0) rep_config.depth_discount = depth_decay_arg;
    if (min_eval_arg != -99999) rep_config.min_eval_cp = min_eval_arg;
    if (max_eval_arg != -99999) rep_config.max_eval_cp = max_eval_arg;
    if (max_eval_loss_arg >= 0) rep_config.max_eval_loss_cp = max_eval_loss_arg;
    if (opp_max_children_arg >= 0) rep_config.max_candidates_per_position = opp_max_children_arg;
    rep_config.relative_eval = relative_eval;
    if (repertoire_name)
        strncpy(rep_config.name, repertoire_name, sizeof(rep_config.name) - 1);

    result = generate_repertoire(
        tree, db, engine_pool, &rep_config,
        verbose ? pipeline_progress : NULL
    );

    if (verbose) printf("\r%80s\r", "");

    if (result)
        repertoire_print_summary(result);
    else
        fprintf(stderr, "  Warning: Repertoire generation returned no results\n");
    printf("\n");

    if (g_interrupted) goto cleanup;

    /* ================================================================
     *  STAGE 3: Find Trap Lines (Optional)
     * ================================================================ */
    if (find_traps) {
        printf("[3/4] Finding opponent mistake-prone lines...\n");

        RepertoireLine trap_lines[50];
        int num_traps = find_mistake_prone_lines(tree, db, play_as_white,
                                                  trap_lines, 50);
        if (num_traps > 0) {
            printf("\n  Top %d trap lines:\n\n",
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
        printf("[3/4] Skipped trap detection (use --traps to enable)\n\n");
    }

    /* ================================================================
     *  STAGE 4: Export Results
     * ================================================================ */
    printf("[4/4] Exporting results...\n");

    /* Save tree state for resumption */
    {
        SerializationOptions opts = serialization_options_default();
        opts.format = FORMAT_JSON;
        opts.json_indent = 2;
        opts.include_engine_eval = true;
        opts.include_ease = true;
        if (tree_save(tree, tree_path, &opts))
            printf("  Tree state: %s (%zu nodes)\n", tree_path, tree->total_nodes);
    }

    /* PGN is the primary output */
    if (result) {
        if (repertoire_export_pgn(result, pgn_path, &rep_config))
            printf("  PGN saved: %s (%d moves, %d lines)\n",
                   pgn_path, result->num_moves, result->num_lines);
    }

    rdb_get_stats(db, &cached_explorer, &cached_evals, &cached_ease);
    printf("  Database: %d explorer | %d evals | %d ease scores\n",
           cached_explorer, cached_evals, cached_ease);

    if (engine_pool) {
        EnginePoolStats eng_stats;
        engine_pool_get_stats(engine_pool, &eng_stats);
        printf("  Engine: %d evals (%.1f avg ms, %d failed)\n",
               eng_stats.total_evaluations, eng_stats.avg_eval_time_ms,
               eng_stats.failed_evaluations);
    }

    clock_gettime(CLOCK_MONOTONIC, &pipeline_end);
    double total_time = (pipeline_end.tv_sec - pipeline_start.tv_sec) +
                        (pipeline_end.tv_nsec - pipeline_start.tv_nsec) / 1e9;
    printf("\n  Total time: %.1f seconds (%.1f minutes)\n",
           total_time, total_time / 60.0);
    printf("\nDone! Repertoire saved to %s\n\n", pgn_path);

cleanup:
    if (g_interrupted && tree && base_name) {
        printf("\n  [INTERRUPTED] Saving partial tree to %s...\n", tree_path);
        SerializationOptions interrupt_opts = serialization_options_default();
        interrupt_opts.format = FORMAT_JSON;
        interrupt_opts.json_indent = 2;
        tree_save(tree, tree_path, &interrupt_opts);
        printf("  Partial tree saved (%zu nodes). Re-run to resume.\n",
               tree->total_nodes);
    }
    if (result) repertoire_result_free(result);
    if (engine_pool) engine_pool_destroy(engine_pool);
    if (maia) maia_destroy(maia);
    if (tree) tree_destroy(tree);
    if (db) rdb_close(db);
    free(token_buf);

    return g_interrupted ? 130 : 0;
}
