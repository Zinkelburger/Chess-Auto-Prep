/**
 * main.c - Repertoire Builder CLI
 *
 * Pipeline:
 *   0. INIT      - Open database + create Stockfish engine pool
 *   1. BUILD     - Interleaved Lichess + Stockfish tree construction
 *   2. SELECT    - Expectimax calculation → repertoire move selection
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
#include <math.h>
#include <sys/sysinfo.h>

#include "tree.h"
#include "lichess_api.h"
#include "serialization.h"
#include "database.h"
#include "engine_pool.h"
#include "repertoire.h"
#include "chess_logic.h"
#include "san_convert.h"
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
    "./maia3_simplified.onnx",
    "../assets/maia3_simplified.onnx",
    NULL
};

static Tree *g_tree = NULL;
volatile int g_interrupted = 0;


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
    printf("  --moves <SAN...>       Starting moves in SAN (e.g. \"e4 d5 exd5 Qxd5\")\n");
    printf("  -c, --color <w|b>      Play as white (w) or black (b) [REQUIRED]\n");
    printf("  -p, --probability <P>  Min probability threshold [default: 0.0001]\n");
    printf("  -d, --depth <N>        Max tree depth in ply [default: 20]\n");
    printf("  -e, --eval-depth <N>   Stockfish search depth [default: 20]\n");
    printf("  -t, --threads <N>      Total CPU cores to use [default: 4]\n");
    printf("  -S, --stockfish <path> Stockfish binary path\n");
    printf("  -D, --database <path>  SQLite database path [default: <name>.db]\n");
    printf("  -L, --load <file>      Load tree from a different JSON file\n");
    printf("  --skip-build           Skip tree building (use existing tree)\n");
    printf("\n");
    printf("Our-move candidates (engine-driven):\n");
    printf("  --our-multipv <N>      MultiPV count at every depth [default: 5]\n");
    printf("  --max-eval-loss <cp>   Skip candidates more than N cp worse than best [default: 50]\n");
    printf("\n");
    printf("Opponent-move selection:\n");
    printf("  --opp-max-children <N> Max opponent responses per position [default: 6]\n");
    printf("  --opp-mass <0-1>       Mass target at every depth [default: 0.95]\n");
    printf("  --maia-model <path>    Path to maia3_simplified.onnx [default: auto-detect]\n");
    printf("  --maia-elo <N>         Elo for Maia predictions [default: 2200]\n");
    printf("  --maia-min-prob <P>    Skip Maia moves below this [default: 0.05]\n");
    printf("\n");
    printf("Eval window pruning:\n");
    printf("  --min-eval <cp>        Stop DFS if our eval drops below this [default: color-dependent]\n");
    printf("  --max-eval <cp>        Stop DFS if our eval exceeds this [default: color-dependent]\n");
    printf("  --relative             Make --min-eval/--max-eval relative to root eval\n");
    printf("\n");
    printf("Preset modes (eval tolerance + novelty; omitted flags keep defaults):\n");
    printf("  --solid                Tight eval window, strict quality floor\n");
    printf("  --practical            Balanced eval tolerance\n");
    printf("  --tricky               Wider tolerance for speculative moves\n");
    printf("  --traps                Widest tolerance + find tricky positions in entire tree\n");
    printf("                         (writes <name>.traps.pgn with annotated trap lines)\n");
    printf("  --traps-in-repertoire  Find trap positions in the repertoire only (stdout)\n");
    printf("  --fresh                Sound but unusual moves; favors rarely-played lines\n");
    printf("\n");
    printf("Expectimax scoring (move selection phase):\n");
    printf("  --novelty-weight <0-100> Boost for rarely-played moves at our-move nodes [default: 0]\n");
    printf("  --leaf-confidence <0-1> Leaf V = c*wp(eval) + (1-c)*0.5  [default: 1.0; 0 = assume 50/50]\n");
    printf("\n");
    printf("Lichess API (use with --lichess to switch opponent source from Maia):\n");
    printf("  --lichess              Use Lichess API for opponent moves instead of Maia\n");
    printf("  -r, --ratings <R>      Rating buckets [default: 2000,2200,2500]\n");
    printf("  -s, --speeds <S>       Time controls [default: blitz,rapid,classical]\n");
    printf("  -g, --min-games <N>    Min games per move [default: 10]\n");
    printf("  -m, --masters          Use masters database instead of player DB\n");
    printf("  --token <token>        Auth token (also reads $LICHESS_TOKEN, ~/.config/tree_builder/token)\n");
    printf("\n");
    printf("Output:\n");
    printf("  -n, --name <name>      Repertoire name (shown in PGN headers)\n");
    printf("  --event-log <file>     Write timestamped build events (TSV) for analysis\n");
    printf("  -v, --verbose          Verbose progress output\n");
    printf("  -h, --help             Show this help\n\n");
    printf("Examples:\n");
    printf("  %s -c w -e 20 -t 4 -v repertoire\n", prog_name);
    printf("  %s -c b -f \"FEN\" -n \"Modern Benoni\" modern_benoni\n", prog_name);
    printf("  %s -c w --moves \"e4 d5 exd5 Qxd5\" scandinavian\n", prog_name);
    printf("  %s -c b -v modern_benoni   # resumes from modern_benoni.tree.json\n", prog_name);
    printf("\n");
}


static void progress_callback(int nodes_built, int current_depth,
                                const char *current_fen) {
    static int last_printed = -1;
    static struct timespec start_time;
    static bool started = false;

    if (!started || nodes_built <= 1) {
        clock_gettime(CLOCK_MONOTONIC, &start_time);
        started = true;
        last_printed = -1;
    }
    if (nodes_built - last_printed < 50) return;

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed_s = (now.tv_sec - start_time.tv_sec)
                     + (now.tv_nsec - start_time.tv_nsec) / 1e9;
    double rate = (elapsed_s > 0.5) ? nodes_built / (elapsed_s / 60.0) : 0;

    int em = (int)(elapsed_s / 60);
    int es = (int)elapsed_s % 60;

    printf("\r  [Build] %d nodes | %.0f/min | %dm%02ds | depth %d | %.30s...    ",
           nodes_built, rate, em, es, current_depth,
           current_fen ? current_fen : "");
    fflush(stdout);
    last_printed = nodes_built;
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
    snprintf(buf, sizeof(buf), "%s/maia3_simplified.onnx", g_exe_dir);
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
    const char *start_moves = NULL;
    char computed_fen[256] = {0};
    const char *base_name = NULL;
    char pgn_path[PATH_MAX] = {0};
    char tree_path[PATH_MAX] = {0};
    const char *db_path = NULL;
    char db_path_buf[PATH_MAX] = {0};
    const char *stockfish_path = NULL;
    const char *load_tree_file = NULL;
    double min_probability = 0.0001;
    int max_depth = 20;
    int eval_depth = 20;
    int num_threads = 4;

    const char *ratings = "2000,2200,2500";
    const char *speeds = "blitz,rapid,classical";
    int min_games = 10;
    bool play_as_white = false;  /* No default - must be specified */
    bool color_specified = false;
    bool verbose = false;
    bool use_masters = false;
    bool skip_build = false;
    bool find_traps = false;
    bool find_traps_in_repertoire = false;
    const char *lichess_token = NULL;
    const char *repertoire_name = NULL;
    const char *maia_model_path = NULL;
    int maia_elo = 2200;
    double maia_min_prob = 0.05;
    bool maia_only = true;
    bool use_lichess = false;
    bool relative_eval = false;
    const char *event_log_path = NULL;

    /* Our-move overrides (-1 = use default) */
    int our_multipv_arg = -1;
    int max_eval_loss_arg = -1;

    /* Opponent-move overrides */
    int opp_max_children_arg = -1;
    double opp_mass_target_arg = -1.0;

    /* Eval window overrides */
    int min_eval_arg = -99999;
    int max_eval_arg = -99999;

    /* Expectimax scoring overrides */
    int novelty_weight_arg = -1;
    const char *mode_name = NULL;
    int mode_id = 0;
    bool user_novelty_weight = false;
    bool user_min_eval = false;
    bool user_max_eval_loss = false;
    double leaf_confidence_arg = -1.0;

    static struct option long_options[] = {
        {"fen",              required_argument, 0, 'f'},
        {"moves",            required_argument, 0, 1010},
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
        {"traps-in-repertoire", no_argument,    0, 1005},
        {"token",            required_argument, 0, 1006},
        /* Our-move */
        {"our-multipv",      required_argument, 0, 2001},
        {"max-eval-loss",    required_argument, 0, 2005},
        /* Opponent-move */
        {"opp-max-children", required_argument, 0, 2010},
        {"opp-mass",         required_argument, 0, 2011},
        /* Eval window */
        {"min-eval",         required_argument, 0, 2020},
        {"max-eval",         required_argument, 0, 2021},
        {"relative",         no_argument,       0, 2022},
        /* Expectimax scoring */
        {"leaf-confidence",  required_argument, 0, 2031},
        {"novelty-weight",   required_argument, 0, 2034},
        {"solid",            no_argument,       0, 2040},
        {"practical",        no_argument,       0, 2041},
        {"tricky",           no_argument,       0, 2042},
        {"fresh",            no_argument,       0, 2044},
        /* Maia */
        /* --sf-threads removed: -t now means total cores */
        {"maia-model",       required_argument, 0, 3001},
        {"maia-elo",         required_argument, 0, 3002},
        {"maia-min-prob",    required_argument, 0, 3004},
        /* --maia-only removed: it's the default */
        {"lichess",          no_argument,       0, 3006},
        /* General */
        {"event-log",        required_argument, 0, 4001},
        {"verbose",          no_argument,       0, 'v'},
        {"help",             no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt, option_index = 0;
    while ((opt = getopt_long(argc, argv, "f:c:p:d:e:t:r:s:g:S:D:L:n:mvh",
                              long_options, &option_index)) != -1) {
        switch (opt) {
            case 'f': start_fen = optarg; break;
            case 1010: start_moves = optarg; break;
            case 'c':
                play_as_white = (optarg[0] == 'w' || optarg[0] == 'W');
                color_specified = true;
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
            case 1004: mode_id = 4; find_traps = true; break;
            case 1005: find_traps_in_repertoire = true; break;
            case 1006: lichess_token = optarg; break;
            /* Our-move */
            case 2001: if (!parse_int(optarg, "our-multipv", &our_multipv_arg)) return 1; break;
            case 2005:
                if (!parse_int(optarg, "max-eval-loss", &max_eval_loss_arg)) return 1;
                user_max_eval_loss = true;
                break;
            /* Opponent-move */
            case 2010: if (!parse_int(optarg, "opp-max-children", &opp_max_children_arg)) return 1; break;
            case 2011: if (!parse_double(optarg, "opp-mass", &opp_mass_target_arg)) return 1; break;
            /* Eval window */
            case 2020:
                if (!parse_int(optarg, "min-eval", &min_eval_arg)) return 1;
                user_min_eval = true;
                break;
            case 2021: if (!parse_int(optarg, "max-eval", &max_eval_arg)) return 1; break;
            case 2022: relative_eval = true; break;
            /* Expectimax scoring */
            case 2031: if (!parse_double(optarg, "leaf-confidence", &leaf_confidence_arg)) return 1; break;
            case 2034: {
                int nw;
                if (!parse_int(optarg, "novelty-weight", &nw)) return 1;
                if (nw < 0 || nw > 100) {
                    fprintf(stderr, "Error: --novelty-weight must be between 0 and 100\n");
                    return 1;
                }
                novelty_weight_arg = nw;
                user_novelty_weight = true;
                break;
            }
            case 2040: mode_id = 1; break;
            case 2041: mode_id = 2; break;
            case 2042: mode_id = 3; break;
            case 2044: mode_id = 5; break;
            /* 2006 removed: --sf-threads folded into -t */
            /* Maia */
            case 3001: maia_model_path = optarg; break;
            case 3002: if (!parse_int(optarg, "maia-elo", &maia_elo)) return 1; break;
            case 3004: if (!parse_double(optarg, "maia-min-prob", &maia_min_prob)) return 1; break;
            case 3006: use_lichess = true; break;
            case 4001: event_log_path = optarg; break;
            default: print_usage(argv[0]); return 1;
        }
    }

    if (use_lichess) maia_only = false;

    /* Preset modes: fill defaults only for options the user did not set */
    if (mode_id != 0) {
        switch (mode_id) {
        case 1:
            mode_name = "solid";
            if (!user_min_eval) min_eval_arg = play_as_white ? 0 : -100;
            if (!user_max_eval_loss) max_eval_loss_arg = 30;
            break;
        case 2:
            mode_name = "practical";
            if (!user_min_eval) min_eval_arg = play_as_white ? -25 : -200;
            if (!user_max_eval_loss) max_eval_loss_arg = 50;
            break;
        case 3:
            mode_name = "tricky";
            if (!user_min_eval) min_eval_arg = play_as_white ? -50 : -250;
            if (!user_max_eval_loss) max_eval_loss_arg = 75;
            break;
        case 4:
            mode_name = "traps";
            if (!user_min_eval) min_eval_arg = play_as_white ? -100 : -300;
            if (!user_max_eval_loss) max_eval_loss_arg = 100;
            find_traps = true;
            break;
        case 5:
            mode_name = "fresh";
            if (!user_novelty_weight) novelty_weight_arg = 60;
            if (!user_max_eval_loss) max_eval_loss_arg = 40;
            break;
        }
    }

    if (!color_specified) {
        fprintf(stderr, "Error: --color (-c) is required. Specify 'w' for white or 'b' for black.\n");
        fprintf(stderr, "Usage: %s --color <w|b> [options] <name>\n", argv[0]);
        return 1;
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

    /* Convert --moves to a FEN by applying each SAN move from startpos */
    if (start_moves) {
        if (start_fen != (const char *)DEFAULT_FEN && strcmp(start_fen, DEFAULT_FEN) != 0) {
            fprintf(stderr, "Error: --moves and --fen are mutually exclusive\n");
            return 1;
        }
        ChessPosition pos;
        position_from_fen(&pos, DEFAULT_FEN);

        char fen_buf[256];
        position_to_fen(&pos, fen_buf, sizeof(fen_buf));

        char moves_copy[2048];
        strncpy(moves_copy, start_moves, sizeof(moves_copy) - 1);
        moves_copy[sizeof(moves_copy) - 1] = '\0';

        printf("Applying moves:");
        char *saveptr = NULL;
        char *tok = strtok_r(moves_copy, " \t", &saveptr);
        int move_num = 0;
        while (tok) {
            /* Skip move number tokens like "1." or "2..." */
            {
                const char *p = tok;
                while (*p >= '0' && *p <= '9') p++;
                if (*p == '.' || *p == '\0') {
                    tok = strtok_r(NULL, " \t", &saveptr);
                    continue;
                }
            }

            char uci_move[8];
            if (!san_to_uci(fen_buf, tok, uci_move, sizeof(uci_move))) {
                fprintf(stderr, "\nError: illegal or unrecognised move '%s'\n", tok);
                return 1;
            }
            if (!position_apply_uci(&pos, uci_move)) {
                fprintf(stderr, "\nError: could not apply move '%s' (uci: %s)\n",
                        tok, uci_move);
                return 1;
            }
            position_to_fen(&pos, fen_buf, sizeof(fen_buf));
            move_num++;
            printf(" %s", tok);
            tok = strtok_r(NULL, " \t", &saveptr);
        }
        printf(" (%d plies)\n", move_num);

        snprintf(computed_fen, sizeof(computed_fen), "%s", fen_buf);
        start_fen = computed_fen;
    }

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
    printf("  Cores:            %d (dynamic thread distribution)\n", num_threads);
    if (!maia_only) {
        printf("  Ratings:          %s\n", ratings);
        printf("  Speeds:           %s\n", speeds);
        printf("  Min games:        %d\n", min_games);
    }
    {
        int nw_banner = novelty_weight_arg >= 0 ? novelty_weight_arg : 0;
        if (nw_banner > 0)
            printf("  Mode:             %s (novelty=%.2f)\n",
                   mode_name ? mode_name : "default",
                   nw_banner / 100.0);
        else
            printf("  Mode:             %s\n",
                   mode_name ? mode_name : "default");
    }
    printf("  Database:         %s\n", db_path);
    if (maia_only)
        printf("  Opponent source:  Maia-only (elo=%d, no API)\n", maia_elo);
    else
        printf("  Opponent source:  %s + Maia supplement\n",
               use_masters ? "Masters DB" : "Lichess API");
    printf("  Output:           %s\n", pgn_path);
    printf("  Tree state:       %s\n", tree_path);
    if (load_tree_file) printf("  Loading tree:     %s\n", load_tree_file);
    {
        int nw_warn = novelty_weight_arg >= 0 ? novelty_weight_arg : 0;
        if (nw_warn > 0 && maia_only) {
            printf("\n  Note: --fresh uses Maia-predicted frequency (approximate).\n");
            printf("        Use --lichess for novelty based on real game data.\n");
        }
    }
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
        fprintf(stderr, "  Warning: Maia model not found — falling back to Lichess API mode.\n");
        fprintf(stderr, "  Use --maia-model <path> or place maia3_simplified.onnx next to the binary.\n");
        maia_only = false;
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
    printf("  Cached: %d explorer | %d evals\n",
           cached_explorer, cached_evals);

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

        engine_pool = engine_pool_create(sf_path, num_threads, eval_depth, num_threads);
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

            /* CLI --moves (if given) overrides whatever was persisted
             * in the tree JSON, so a user can re-export with a
             * different leading move sequence without rebuilding. */
            if (start_moves) {
                strncpy(tree->start_moves, start_moves,
                        sizeof(tree->start_moves) - 1);
                tree->start_moves[sizeof(tree->start_moves) - 1] = '\0';
            }

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

        /* Persist the SAN move sequence so later skip-build runs
         * can re-export without having to re-specify --moves. */
        if (start_moves) {
            strncpy(tree->start_moves, start_moves,
                    sizeof(tree->start_moves) - 1);
            tree->start_moves[sizeof(tree->start_moves) - 1] = '\0';
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
        if (our_multipv_arg > 0) config.our_multipv = our_multipv_arg;
        if (max_eval_loss_arg >= 0) config.max_eval_loss_cp = max_eval_loss_arg;
        if (opp_max_children_arg >= 0) config.opp_max_children = opp_max_children_arg;
        if (opp_mass_target_arg >= 0.0) config.opp_mass_target = opp_mass_target_arg;
        if (min_eval_arg != -99999) config.min_eval_cp = min_eval_arg;
        if (max_eval_arg != -99999) config.max_eval_cp = max_eval_arg;
        config.relative_eval = relative_eval;

        if (maia) {
            config.maia = maia;
            config.maia_elo = maia_elo;
            config.maia_min_prob = maia_min_prob;
            config.maia_only = maia_only;
        }

        /* Only run Maia at our-move nodes for novelty scoring if we're
         * actually going to use it.  With novelty_weight == 0 and no
         * trap-hunting, `maia_frequency` would be written and never
         * read — one ONNX inference per our-move node wasted. */
        int planned_novelty = novelty_weight_arg >= 0 ? novelty_weight_arg : 0;
        config.populate_maia_frequency = (planned_novelty > 0) || find_traps
                                        || find_traps_in_repertoire;

        config.progress_callback = progress_callback;  /* Always show progress */

        printf("  Our moves:  MultiPV %d (constant), %dcp loss max\n",
               config.our_multipv, config.max_eval_loss_cp);
        printf("  Opponent:   max %d children, mass target %.0f%%\n",
               config.opp_max_children,
               config.opp_mass_target * 100.0);
        printf("  Eval window: [%+d, %+d] cp%s\n",
               config.min_eval_cp, config.max_eval_cp,
               relative_eval ? " (relative)" : "");

        BuildStats build_stats;
        memset(&build_stats, 0, sizeof(build_stats));
        config.stats = &build_stats;

        FILE *event_log_fp = NULL;
        if (event_log_path) {
            event_log_fp = fopen(event_log_path, "w");
            if (!event_log_fp) {
                fprintf(stderr, "Warning: cannot open event log %s: %s\n",
                        event_log_path, strerror(errno));
            } else {
                config.event_log = event_log_fp;
                clock_gettime(CLOCK_MONOTONIC, &config.event_log_epoch);
                printf("  Event log: %s\n", event_log_path);
            }
        }

        struct timespec build_start, build_end;
        clock_gettime(CLOCK_MONOTONIC, &build_start);

        size_t nodes_before = tree->total_nodes;
        bool success = tree_build(tree, start_fen, &config, explorer);

        clock_gettime(CLOCK_MONOTONIC, &build_end);
        double build_time = (build_end.tv_sec - build_start.tv_sec) +
                            (build_end.tv_nsec - build_start.tv_nsec) / 1e9;

        printf("\r%80s\r", "");  /* Always clear progress line */

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

        tree->build_time_seconds = build_time;
        tree->nodes_per_minute = (build_time > 0)
            ? tree->total_nodes / (build_time / 60.0) : 0;
        tree->branching_factor = (tree->max_depth_reached > 0)
            ? pow((double)tree->total_nodes, 1.0 / tree->max_depth_reached) : 1.0;
        tree->build_threads = num_threads;
        tree->build_eval_depth = eval_depth;

        if (nodes_before > 1)
            printf("  Resumed: %zu new nodes (total %zu) in %.1fs (max depth %d)\n",
                   new_nodes, tree->total_nodes, build_time,
                   tree->max_depth_reached);
        else
            printf("  Built %zu nodes in %.1fs (%.1f n/min, b=%.2f, %d threads, depth %d)\n",
                   tree->total_nodes, build_time, tree->nodes_per_minute,
                   tree->branching_factor, num_threads, eval_depth);

        /* Post-build: remove nodes where eval is too bad for us */
        size_t pruned = tree_prune_eval_too_low(tree);
        if (pruned > 0)
            printf("  Pruned %zu nodes (eval below %+dcp)\n",
                   pruned, config.min_eval_cp);

        /* Print build timing breakdown */
        printf("\n  Build timing breakdown:\n");
        if (build_stats.lichess_queries > 0 || build_stats.lichess_cache_hits > 0) {
            int total_lichess = build_stats.lichess_queries + build_stats.lichess_cache_hits;
            printf("    Lichess API:    %d queries (%d cached) | %.1fs",
                   build_stats.lichess_queries, build_stats.lichess_cache_hits,
                   build_stats.lichess_total_ms / 1000.0);
            if (build_stats.lichess_queries > 0)
                printf(" (%.1fms avg)",
                       build_stats.lichess_total_ms / build_stats.lichess_queries);
            printf("\n");
            (void)total_lichess;
        }
        if (build_stats.maia_evals > 0) {
            printf("    Maia:           %d evals | %.1fs",
                   build_stats.maia_evals, build_stats.maia_total_ms / 1000.0);
            if (build_stats.maia_evals > 0)
                printf(" (%.1fms avg)",
                       build_stats.maia_total_ms / build_stats.maia_evals);
            printf("\n");
        }
        printf("    Stockfish:\n");
        printf("      MultiPV:      %d calls | %.1fs",
               build_stats.sf_multipv_calls, build_stats.sf_multipv_ms / 1000.0);
        if (build_stats.sf_multipv_calls > 0)
            printf(" (%.0fms avg)",
                   build_stats.sf_multipv_ms / build_stats.sf_multipv_calls);
        printf("\n");
        printf("      Single eval:  %d calls | %.1fs",
               build_stats.sf_single_calls, build_stats.sf_single_ms / 1000.0);
        if (build_stats.sf_single_calls > 0)
            printf(" (%.0fms avg)",
                   build_stats.sf_single_ms / build_stats.sf_single_calls);
        printf("\n");
        printf("      Batch eval:   %d calls | %.1fs",
               build_stats.sf_batch_calls, build_stats.sf_batch_ms / 1000.0);
        if (build_stats.sf_batch_calls > 0)
            printf(" (%.0fms avg)",
                   build_stats.sf_batch_ms / build_stats.sf_batch_calls);
        printf("\n");
        {
            int total_eval = build_stats.db_eval_hits + build_stats.db_eval_misses;
            int total_expl = build_stats.db_explorer_hits + build_stats.db_explorer_misses;
            printf("    DB cache:       eval %d/%d hits",
                   build_stats.db_eval_hits, total_eval);
            if (total_eval > 0)
                printf(" (%d%%)", build_stats.db_eval_hits * 100 / total_eval);
            printf(" | explorer %d/%d hits",
                   build_stats.db_explorer_hits, total_expl);
            if (total_expl > 0)
                printf(" (%d%%)", build_stats.db_explorer_hits * 100 / total_expl);
            printf("\n");
            int total_mpv = build_stats.db_multipv_hits + build_stats.db_multipv_misses;
            printf("    MultiPV cache:  %d/%d hits",
                   build_stats.db_multipv_hits, total_mpv);
            if (total_mpv > 0)
                printf(" (%d%%)", build_stats.db_multipv_hits * 100 / total_mpv);
            printf("\n");
        }
        printf("\n");

        if (event_log_fp) {
            fclose(event_log_fp);
            config.event_log = NULL;
        }

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
     *  STAGE 2: Generate Repertoire (Expectimax + Selection)
     * ================================================================ */
    printf("[2/4] Generating repertoire...\n");

    RepertoireConfig rep_config = repertoire_config_default();
    rep_config.play_as_white = play_as_white;
    rep_config.min_eval_cp = tree->config.min_eval_cp;
    rep_config.max_eval_cp = tree->config.max_eval_cp;
    /* Prefer the tree root's FEN — it's the authoritative start
     * position even after resume/skip-build.  Fall back to the CLI
     * start_fen only if the tree somehow has no root. */
    const char *export_fen = (tree->root && tree->root->fen[0])
                             ? tree->root->fen
                             : start_fen;
    snprintf(rep_config.start_fen, sizeof(rep_config.start_fen), "%s",
             export_fen);
    snprintf(rep_config.start_moves, sizeof(rep_config.start_moves), "%s",
             tree->start_moves);
    rep_config.max_depth = max_depth;
    rep_config.min_probability = min_probability;
    rep_config.min_games = min_games;
    rep_config.eval_depth = eval_depth;
    rep_config.quick_eval_depth = eval_depth > 15 ? 15 : eval_depth;
    rep_config.verbose_search = verbose;
    if (novelty_weight_arg >= 0) rep_config.novelty_weight = novelty_weight_arg;
    if (leaf_confidence_arg >= 0.0) rep_config.leaf_confidence = leaf_confidence_arg;
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
    char traps_pgn_path[PATH_MAX] = {0};

    if (find_traps) {
        printf("[3/4] Searching entire tree for tricky positions...\n");

        int max_trap_lines = 200;
        TrapLineInfo *trap_lines = (TrapLineInfo *)calloc(
            max_trap_lines, sizeof(TrapLineInfo));
        if (trap_lines) {
            int num_traps = find_trap_lines(tree, db, play_as_white,
                                            trap_lines, max_trap_lines);
            if (num_traps > 0) {
                printf("  Found %d tricky positions (sorted by trick surplus)\n\n",
                       num_traps);
                int show = num_traps > 20 ? 20 : num_traps;
                for (int i = 0; i < show; i++) {
                    printf("  %2d. [surplus %+.1f%% V=%.1f%% wp=%.1f%%] ",
                           i + 1,
                           trap_lines[i].trick_surplus * 100,
                           trap_lines[i].expectimax_value * 100,
                           trap_lines[i].wp_eval * 100);
                    for (int j = 0; j < trap_lines[i].num_moves && j < 16; j++) {
                        if (j % 2 == 0) printf("%d.", (j / 2) + 1);
                        printf("%s ", trap_lines[i].moves_san[j]);
                    }
                    printf("\n         %s (%.0f%%) loses %d cp vs best %s  [trap=%.0f%% reach=%.2f%%]\n",
                           trap_lines[i].popular_move,
                           trap_lines[i].popular_prob * 100,
                           trap_lines[i].eval_diff_cp,
                           trap_lines[i].best_move,
                           trap_lines[i].trap_score * 100,
                           trap_lines[i].cumulative_prob * 100);
                }

                snprintf(traps_pgn_path, sizeof(traps_pgn_path),
                         "%s.traps.pgn", base_name);
                if (export_traps_pgn(trap_lines, num_traps,
                                     traps_pgn_path, &rep_config))
                    printf("\n  Trap PGN saved: %s (%d lines)\n",
                           traps_pgn_path, num_traps);
            } else {
                printf("  No significant trap positions found.\n");
            }
            free(trap_lines);
        }
        printf("\n");
    } else if (find_traps_in_repertoire) {
        printf("[3/4] Finding mistake-prone lines in repertoire...\n");

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
        printf("[3/4] Skipped trap detection (use --traps or --traps-in-repertoire)\n\n");
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

    /* Copy build performance stats into rep_config for PGN headers */
    rep_config.build_time_seconds = tree->build_time_seconds;
    rep_config.build_nodes        = (int)tree->total_nodes;
    rep_config.nodes_per_minute   = tree->nodes_per_minute;
    rep_config.branching_factor   = tree->branching_factor;
    rep_config.build_threads      = tree->build_threads;
    rep_config.build_eval_depth   = tree->build_eval_depth;

    /* PGN is the primary output */
    if (result) {
        if (repertoire_export_pgn(result, pgn_path, &rep_config))
            printf("  PGN saved: %s (%d moves, %d lines)\n",
                   pgn_path, result->num_moves, result->num_lines);
    }

    rdb_get_stats(db, &cached_explorer, &cached_evals, &cached_ease);
    printf("  Database: %d explorer | %d evals\n",
           cached_explorer, cached_evals);

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
