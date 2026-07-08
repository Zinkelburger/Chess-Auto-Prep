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
#include <sys/stat.h>
#include <pthread.h>

#include "tree.h"
#include "cJSON.h"
#include "tree_db_build.h"
#include "pgn_freq.h"
#include "lichess_api.h"
#include "serialization.h"
#include "database.h"
#include "engine_pool.h"
#include "repertoire.h"
#include "chess_logic.h"
#include "san_convert.h"
#include "maia.h"
#include "lichess_eval_db.h"
#include "chessdb_eval_db.h"
#include "chessdb_api.h"
#include "eval_source.h"
#include "progress_line.h"
#ifdef HAS_CDBDIRECT
#include "cdbdirect_eval.h"
#endif


#define DEFAULT_FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
#define MAX_PGN_FILES 16

static bool fen_keys_match(const char *a, const char *b) {
    char ca[128];
    char cb[128];
    snprintf(ca, sizeof(ca), "%s", a ? a : "");
    snprintf(cb, sizeof(cb), "%s", b ? b : "");
    eval_canonicalize_fen(ca);
    eval_canonicalize_fen(cb);
    return strcmp(ca, cb) == 0;
}

static bool confirm_yes_interactive(const char *prompt) {
    if (!isatty(STDIN_FILENO)) {
        fprintf(stderr,
                "Error: confirmation required but stdin is not a terminal.\n");
        fprintf(stderr, "  %s\n", prompt);
        return false;
    }
    fprintf(stderr, "%s", prompt);
    fflush(stderr);
    char buf[16];
    if (!fgets(buf, sizeof(buf), stdin)) return false;
    return buf[0] == 'y' || buf[0] == 'Y';
}

static void format_iso_timestamp(char *buf, size_t len) {
    time_t now = time(NULL);
    struct tm tm_utc;
    gmtime_r(&now, &tm_utc);
    strftime(buf, len, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

static void format_settings_flags(char *buf, size_t len, bool play_as_white,
                                  const char *ratings, const char *speeds) {
    snprintf(buf, len, "-c %c --ratings %s --speeds %s",
             play_as_white ? 'w' : 'b', ratings, speeds);
}

static void suggest_alternate_db_path(const char *db_path, bool play_as_white,
                                      char *out, size_t out_len) {
    if (!db_path || !out || out_len == 0) {
        if (out && out_len > 0) out[0] = '\0';
        return;
    }
    const char *suffix = play_as_white ? "_white" : "_black";
    size_t plen = strlen(db_path);
    if (plen > 3 && strcmp(db_path + plen - 3, ".db") == 0) {
        snprintf(out, out_len, "%.*s%s.db", (int)(plen - 3), db_path, suffix);
    } else {
        snprintf(out, out_len, "%s%s.db", db_path, suffix);
    }
}

static void store_build_metadata(RepertoireDB *db, bool play_as_white,
                                const char *ratings, const char *speeds,
                                bool set_created_at) {
    char paw[8];
    snprintf(paw, sizeof(paw), "%d", play_as_white ? 1 : 0);
    rdb_set_metadata(db, "play_as_white", paw);
    rdb_set_metadata(db, "rating_range", ratings);
    rdb_set_metadata(db, "speeds", speeds);
    if (set_created_at) {
        char ts[32];
        format_iso_timestamp(ts, sizeof(ts));
        rdb_set_metadata(db, "created_at", ts);
    }
}

/**
 * Compare stored build metadata with current CLI flags.
 * Returns false on any mismatch (caller should exit non-zero).
 */
static bool check_build_metadata(RepertoireDB *db, const char *db_path,
                                 const char *prog_name,
                                 bool db_file_existed, bool db_has_data,
                                 bool play_as_white, const char *ratings,
                                 const char *speeds) {
    char *stored_paw = rdb_get_metadata(db, "play_as_white");

    if (!stored_paw) {
        if (db_file_existed && db_has_data) {
            fprintf(stderr,
                    "Note: Database '%s' has cached data but no build metadata "
                    "(pre-existing DB).\n",
                    db_path);
            fprintf(stderr,
                    "  Current settings will be recorded. Cached explorer/eval "
                    "data will be reused.\n\n");
        }
        store_build_metadata(db, play_as_white, ratings, speeds, true);
        return true;
    }

    char cur_paw[8];
    snprintf(cur_paw, sizeof(cur_paw), "%d", play_as_white ? 1 : 0);
    bool paw_match = strcmp(stored_paw, cur_paw) == 0;

    char *stored_ratings = rdb_get_metadata(db, "rating_range");
    char *stored_speeds = rdb_get_metadata(db, "speeds");

    bool stored_white = stored_paw[0] == '1';
    bool ratings_match =
        stored_ratings && strcmp(stored_ratings, ratings) == 0;
    bool speeds_match =
        stored_speeds && strcmp(stored_speeds, speeds) == 0;

    if (paw_match && ratings_match && speeds_match) {
        if (db_file_existed) {
            fprintf(stderr,
                    "Resuming previous build with database '%s'.\n\n",
                    db_path);
        }
        free(stored_paw);
        free(stored_ratings);
        free(stored_speeds);
        return true;
    }

    char stored_flags[256];
    char current_flags[256];
    char alt_db[PATH_MAX];
    format_settings_flags(stored_flags, sizeof(stored_flags),
                          stored_white,
                          stored_ratings ? stored_ratings : "",
                          stored_speeds ? stored_speeds : "");
    format_settings_flags(current_flags, sizeof(current_flags),
                          play_as_white, ratings, speeds);
    suggest_alternate_db_path(db_path, play_as_white, alt_db, sizeof(alt_db));

    fprintf(stderr,
            "Error: Database '%s' was built with different settings.\n",
            db_path);
    fprintf(stderr, "  Stored:  %s\n", stored_flags);
    fprintf(stderr, "  Current: %s\n\n", current_flags);
    fprintf(stderr,
            "To resume this database, run with the original settings:\n");
    fprintf(stderr,
            "  %s [options] %s -D %s\n\n",
            prog_name, stored_flags, db_path);
    fprintf(stderr,
            "To start fresh with your current settings, use a different database:\n");
    fprintf(stderr,
            "  %s [options] %s -D %s\n\n",
            prog_name, current_flags, alt_db);
    fprintf(stderr,
            "To reuse cached evaluations from the old database in a new one:\n");
    fprintf(stderr,
            "  %s [options] %s -D %s --input-db %s\n\n",
            prog_name, current_flags, alt_db, db_path);

    free(stored_paw);
    free(stored_ratings);
    free(stored_speeds);
    return false;
}

/** Tracks which CLI options the user passed explicitly (for --resume overrides). */
typedef struct {
    bool fen, moves, color, probability, ply, eval_depth, threads;
    bool ratings, speeds, min_games, stockfish, database, name;
    bool masters, skip_build, build_now, traps, traps_in_repertoire;
    bool our_multipv, max_eval_loss, opp_max_children, opp_mass;
    bool min_eval, max_eval, absolute;
    bool leaf_confidence, novelty_weight;
    bool preset;
    bool maia_model, maia_elo, maia_min_prob, maia_only, lichess, build_mode;
    bool pgn, db_min_games, db_min_prob, no_freq_cache, min_elo;
    bool event_log, lichess_eval_db, chessdb_eval_db, chessdb_api;
    bool chessdb_api_quota, chessdb_api_concurrency, no_ext_eval_subtree_skip;
#ifdef HAS_CDBDIRECT
    bool cdbdirect_path, cdbdirect_read_ahead, batch_eval_lookups;
#endif
    bool verbose;
} CliExplicit;

/** Heap/static buffers for strings loaded from saved cli_args JSON. */
typedef struct {
    char fen[256];
    char moves[2048];
    char ratings[128];
    char speeds[128];
    char stockfish[PATH_MAX];
    char repertoire_name[256];
    char event_log[PATH_MAX];
    char lichess_eval_db[PATH_MAX];
    char chessdb_eval_db[PATH_MAX];
    char maia_model[PATH_MAX];
    char build_mode[64];
    char preset[32];
    char pgn[MAX_PGN_FILES][PATH_MAX];
#ifdef HAS_CDBDIRECT
    char cdbdirect[PATH_MAX];
#endif
} CliLoadedStrings;

static const char *build_mode_to_str(BuildMode mode) {
    switch (mode) {
    case BUILD_MODE_STOCKFISH_EXPECTIMAX: return "stockfish-expectimax";
    case BUILD_MODE_MAIA_DB_EXPLORE:     return "maia-db-explore";
    case BUILD_MODE_DB_EXPLORER:         return "db-explorer";
    case BUILD_MODE_TRAP_FINDER:         return "trap-finder";
    default:                             return "stockfish-expectimax";
    }
}

static bool build_mode_from_str(const char *s, BuildMode *out) {
    if (!s || !out) return false;
    if (strcmp(s, "stockfish-expectimax") == 0 ||
        strcmp(s, "stockfishExpectimax") == 0) {
        *out = BUILD_MODE_STOCKFISH_EXPECTIMAX;
        return true;
    }
    if (strcmp(s, "maia-db-explore") == 0 ||
        strcmp(s, "maiaDbExplore") == 0) {
        *out = BUILD_MODE_MAIA_DB_EXPLORE;
        return true;
    }
    if (strcmp(s, "db-explorer") == 0 ||
        strcmp(s, "dbExplorer") == 0) {
        *out = BUILD_MODE_DB_EXPLORER;
        return true;
    }
    if (strcmp(s, "trap-finder") == 0 ||
        strcmp(s, "trapFinder") == 0) {
        *out = BUILD_MODE_TRAP_FINDER;
        return true;
    }
    return false;
}

static void cli_json_add_str(cJSON *obj, const char *key, const char *val) {
    if (val && val[0]) cJSON_AddStringToObject(obj, key, val);
}

static cJSON *cli_build_config_json(
    const char *start_fen, const char *start_moves, bool play_as_white,
    double min_probability, int max_depth, int eval_depth, int num_threads,
    const char *ratings, const char *speeds, int min_games,
    const char *stockfish_path, bool use_masters, bool skip_build, bool build_now,
    bool find_traps, bool find_traps_in_repertoire, const char *repertoire_name,
    const char *maia_model_path, int maia_elo, double maia_min_prob,
    bool maia_only, bool relative_eval, BuildMode build_mode,
    const char *event_log_path, const char *lichess_eval_db_path,
    const char *chessdb_eval_db_path, bool chessdb_api_enabled,
    int chessdb_api_quota, int chessdb_api_concurrency, bool ext_eval_subtree_skip,
#ifdef HAS_CDBDIRECT
    const char *cdbdirect_path, bool cdbdirect_read_ahead, bool batch_eval_lookups,
#endif
    const char **pgn_files, int pgn_file_count, int db_min_games, double db_min_prob,
    bool no_freq_cache, int our_multipv, int max_eval_loss, int opp_max_children,
    double opp_mass_target, int min_eval, int max_eval, int novelty_weight,
    double leaf_confidence, const char *mode_name, bool verbose) {
    cJSON *obj = cJSON_CreateObject();
    if (!obj) return NULL;

    cJSON_AddStringToObject(obj, "color", play_as_white ? "w" : "b");
    if (start_fen && strcmp(start_fen, DEFAULT_FEN) != 0)
        cJSON_AddStringToObject(obj, "fen", start_fen);
    cli_json_add_str(obj, "moves", start_moves);
    cJSON_AddNumberToObject(obj, "probability", min_probability);
    cJSON_AddNumberToObject(obj, "ply", max_depth);
    cJSON_AddNumberToObject(obj, "eval_depth", eval_depth);
    cJSON_AddNumberToObject(obj, "threads", num_threads);
    cJSON_AddStringToObject(obj, "build_mode", build_mode_to_str(build_mode));

    if (pgn_file_count > 0) {
        cJSON *arr = cJSON_AddArrayToObject(obj, "pgn");
        for (int i = 0; i < pgn_file_count; i++)
            cJSON_AddItemToArray(arr, cJSON_CreateString(pgn_files[i]));
    }

    cJSON_AddBoolToObject(obj, "no_freq_cache", no_freq_cache);
    cJSON_AddNumberToObject(obj, "db_min_games", db_min_games);
    cJSON_AddNumberToObject(obj, "db_min_prob", db_min_prob);
    cli_json_add_str(obj, "stockfish", stockfish_path);
    cJSON_AddNumberToObject(obj, "our_multipv", our_multipv);
    cJSON_AddNumberToObject(obj, "max_eval_loss", max_eval_loss);
    cJSON_AddNumberToObject(obj, "opp_max_children", opp_max_children);
    cJSON_AddNumberToObject(obj, "opp_mass", opp_mass_target);
    cJSON_AddBoolToObject(obj, "maia_only", maia_only);
    cJSON_AddBoolToObject(obj, "lichess", !maia_only);
    cli_json_add_str(obj, "maia_model", maia_model_path);
    cJSON_AddNumberToObject(obj, "maia_elo", maia_elo);
    cJSON_AddNumberToObject(obj, "maia_min_prob", maia_min_prob);
    cJSON_AddNumberToObject(obj, "min_eval", min_eval);
    cJSON_AddNumberToObject(obj, "max_eval", max_eval);
    cJSON_AddBoolToObject(obj, "absolute", !relative_eval);
    cli_json_add_str(obj, "preset", mode_name);
    cJSON_AddNumberToObject(obj, "novelty_weight", novelty_weight);
    cJSON_AddNumberToObject(obj, "leaf_confidence", leaf_confidence);
    cJSON_AddStringToObject(obj, "ratings", ratings);
    cJSON_AddStringToObject(obj, "speeds", speeds);
    cJSON_AddNumberToObject(obj, "min_games", min_games);
    cJSON_AddBoolToObject(obj, "masters", use_masters);
    cli_json_add_str(obj, "lichess_eval_db", lichess_eval_db_path);
    cli_json_add_str(obj, "chessdb_eval_db", chessdb_eval_db_path);
    cJSON_AddBoolToObject(obj, "chessdb_api", chessdb_api_enabled);
    cJSON_AddNumberToObject(obj, "chessdb_api_quota", chessdb_api_quota);
    cJSON_AddNumberToObject(obj, "chessdb_api_concurrency", chessdb_api_concurrency);
    cJSON_AddBoolToObject(obj, "no_ext_eval_subtree_skip", !ext_eval_subtree_skip);
#ifdef HAS_CDBDIRECT
    cli_json_add_str(obj, "cdbdirect_path", cdbdirect_path);
    cJSON_AddBoolToObject(obj, "cdbdirect_read_ahead", cdbdirect_read_ahead);
    cJSON_AddBoolToObject(obj, "batch_eval_lookups", batch_eval_lookups);
#endif
    cli_json_add_str(obj, "name", repertoire_name);
    cli_json_add_str(obj, "event_log", event_log_path);
    cJSON_AddBoolToObject(obj, "verbose", verbose);
    cJSON_AddBoolToObject(obj, "skip_build", skip_build && !build_now);
    cJSON_AddBoolToObject(obj, "build_now", build_now);
    cJSON_AddBoolToObject(obj, "traps", find_traps);
    cJSON_AddBoolToObject(obj, "traps_in_repertoire", find_traps_in_repertoire);

    return obj;
}

static bool save_config_to_db(
    RepertoireDB *db, bool play_as_white, const char *ratings, const char *speeds,
    const char *start_fen, const char *start_moves, double min_probability,
    int max_depth, int eval_depth, int num_threads, int min_games,
    const char *stockfish_path, bool use_masters, bool skip_build, bool build_now,
    bool find_traps, bool find_traps_in_repertoire, const char *repertoire_name,
    const char *maia_model_path, int maia_elo, double maia_min_prob,
    bool maia_only, bool relative_eval, BuildMode build_mode,
    const char *event_log_path, const char *lichess_eval_db_path,
    const char *chessdb_eval_db_path, bool chessdb_api_enabled,
    int chessdb_api_quota, int chessdb_api_concurrency, bool ext_eval_subtree_skip,
#ifdef HAS_CDBDIRECT
    const char *cdbdirect_path, bool cdbdirect_read_ahead, bool batch_eval_lookups,
#endif
    const char **pgn_files, int pgn_file_count, int db_min_games, double db_min_prob,
    bool no_freq_cache, int our_multipv_arg, int max_eval_loss_arg,
    int opp_max_children_arg, double opp_mass_target_arg, int min_eval_arg,
    int max_eval_arg, int novelty_weight_arg, double leaf_confidence_arg,
    const char *mode_name, bool verbose) {
    TreeConfig cd = tree_config_default();
    cd.play_as_white = play_as_white;
    tree_config_set_color_defaults(&cd);

    int eff_our_multipv = our_multipv_arg > 0 ? our_multipv_arg : cd.our_multipv;
    int eff_max_eval_loss = max_eval_loss_arg >= 0 ? max_eval_loss_arg : cd.max_eval_loss_cp;
    int eff_opp_max = opp_max_children_arg >= 0 ? opp_max_children_arg : cd.opp_max_children;
    double eff_opp_mass = opp_mass_target_arg >= 0.0 ? opp_mass_target_arg
                                                     : cd.opp_mass_target;
    int eff_min_eval = min_eval_arg != -99999 ? min_eval_arg : cd.min_eval_cp;
    int eff_max_eval = max_eval_arg != -99999 ? max_eval_arg : cd.max_eval_cp;
    int eff_novelty = novelty_weight_arg >= 0 ? novelty_weight_arg : 0;
    double eff_leaf_conf = leaf_confidence_arg >= 0.0 ? leaf_confidence_arg : 1.0;

    cJSON *obj = cli_build_config_json(
        start_fen, start_moves, play_as_white, min_probability, max_depth,
        eval_depth, num_threads, ratings, speeds, min_games, stockfish_path,
        use_masters, skip_build, build_now, find_traps, find_traps_in_repertoire,
        repertoire_name, maia_model_path, maia_elo, maia_min_prob, maia_only,
        relative_eval, build_mode, event_log_path, lichess_eval_db_path,
        chessdb_eval_db_path, chessdb_api_enabled, chessdb_api_quota,
        chessdb_api_concurrency, ext_eval_subtree_skip,
#ifdef HAS_CDBDIRECT
        cdbdirect_path, cdbdirect_read_ahead, batch_eval_lookups,
#endif
        pgn_files, pgn_file_count, db_min_games, db_min_prob, no_freq_cache,
        eff_our_multipv, eff_max_eval_loss, eff_opp_max, eff_opp_mass,
        eff_min_eval, eff_max_eval, eff_novelty, eff_leaf_conf, mode_name,
        verbose);
    if (!obj) return false;

    char *json = cJSON_PrintUnformatted(obj);
    cJSON_Delete(obj);
    if (!json) return false;

    bool ok = rdb_save_cli_config(db, json);
    cJSON_free(json);
    if (ok)
        store_build_metadata(db, play_as_white, ratings, speeds, false);
    return ok;
}

static void print_resume_banner(
    bool play_as_white, const char *start_fen, int max_depth, int eval_depth,
    int num_threads, bool maia_only, const char *ratings, const char *speeds,
    const char *mode_name, const char *db_path) {
    fprintf(stderr, "\n");
    fprintf(stderr, "══════════════════════════════════════════════════════════\n");
    fprintf(stderr, "  Resuming with stored configuration:\n");
    fprintf(stderr, "══════════════════════════════════════════════════════════\n");
    fprintf(stderr, "  Color:      %s\n", play_as_white ? "white" : "black");
    fprintf(stderr, "  FEN:        %.56s%s\n", start_fen,
            strlen(start_fen) > 56 ? "..." : "");
    fprintf(stderr, "  Depth:      %d ply | eval %d | %d threads\n",
            max_depth, eval_depth, num_threads);
    fprintf(stderr, "  Opponent:   %s\n", maia_only ? "Maia" : "Lichess");
    if (!maia_only) {
        fprintf(stderr, "  Ratings:    %s\n", ratings);
        fprintf(stderr, "  Speeds:     %s\n", speeds);
    }
    if (mode_name && mode_name[0])
        fprintf(stderr, "  Preset:     %s\n", mode_name);
    fprintf(stderr, "  Database:   %s\n", db_path);
    fprintf(stderr, "══════════════════════════════════════════════════════════\n\n");
}

static bool load_config_from_db(
    const char *db_path, const char *base_name, CliExplicit *exp,
    CliLoadedStrings *loaded, const char **start_fen, const char **start_moves,
    bool *play_as_white, bool *color_specified, double *min_probability,
    int *max_depth, int *eval_depth, int *num_threads, const char **ratings,
    const char **speeds, int *min_games, const char **stockfish_path,
    bool *use_masters, bool *skip_build, bool *build_now, bool *find_traps,
    bool *find_traps_in_repertoire, const char **repertoire_name,
    const char **maia_model_path, int *maia_elo, double *maia_min_prob,
    bool *maia_only, bool *relative_eval, BuildMode *build_mode,
    const char **build_mode_str, const char **event_log_path,
    const char **lichess_eval_db_path, const char **chessdb_eval_db_path,
    bool *chessdb_api_enabled, int *chessdb_api_quota,
    int *chessdb_api_concurrency, bool *ext_eval_subtree_skip,
#ifdef HAS_CDBDIRECT
    const char **cdbdirect_path, bool *cdbdirect_read_ahead,
    bool *batch_eval_lookups,
#endif
    const char **pgn_files, int *pgn_file_count, int *db_min_games,
    double *db_min_prob, bool *no_freq_cache, int *our_multipv_arg,
    int *max_eval_loss_arg, int *opp_max_children_arg, double *opp_mass_target_arg,
    int *min_eval_arg, int *max_eval_arg, int *novelty_weight_arg,
    double *leaf_confidence_arg, const char **mode_name, int *mode_id,
    bool *user_min_eval, bool *user_max_eval_loss, bool *user_novelty_weight,
    bool *verbose) {
    (void)base_name;

    if (access(db_path, F_OK) != 0) {
        fprintf(stderr,
                "Error: No database found for '%s'. Run without --resume first.\n",
                db_path);
        return false;
    }

    RepertoireDB *db = rdb_open(db_path);
    if (!db) {
        fprintf(stderr, "Error: Failed to open database '%s'\n", db_path);
        return false;
    }

    char *json_str = rdb_load_cli_config(db);
    rdb_close(db);
    if (!json_str) {
        fprintf(stderr,
                "Error: No saved configuration found. "
                "This database was created before --resume support.\n");
        return false;
    }

    cJSON *root = cJSON_Parse(json_str);
    free(json_str);
    if (!root) {
        fprintf(stderr, "Error: Corrupt saved configuration in '%s'\n", db_path);
        return false;
    }

#define LOAD_STR(field, key, buf, ptr) \
    do { \
        if (!(exp)->field) { \
            cJSON *_it = cJSON_GetObjectItemCaseSensitive(root, key); \
            if (cJSON_IsString(_it) && _it->valuestring) { \
                snprintf((buf), sizeof(buf), "%s", _it->valuestring); \
                *(ptr) = (buf); \
            } \
        } \
    } while (0)

#define LOAD_BOOL(field, key, var) \
    do { \
        if (!(exp)->field) { \
            cJSON *_it = cJSON_GetObjectItemCaseSensitive(root, key); \
            if (cJSON_IsBool(_it)) *(var) = cJSON_IsTrue(_it); \
        } \
    } while (0)

#define LOAD_NUM(field, key, var) \
    do { \
        if (!(exp)->field) { \
            cJSON *_it = cJSON_GetObjectItemCaseSensitive(root, key); \
            if (cJSON_IsNumber(_it)) *(var) = _it->valueint; \
        } \
    } while (0)

#define LOAD_DBL(field, key, var) \
    do { \
        if (!(exp)->field) { \
            cJSON *_it = cJSON_GetObjectItemCaseSensitive(root, key); \
            if (cJSON_IsNumber(_it)) *(var) = _it->valuedouble; \
        } \
    } while (0)

    if (!exp->color) {
        cJSON *c = cJSON_GetObjectItemCaseSensitive(root, "color");
        if (cJSON_IsString(c) && c->valuestring) {
            *play_as_white = (c->valuestring[0] == 'w' || c->valuestring[0] == 'W');
            *color_specified = true;
        }
    }

    LOAD_STR(fen, "fen", loaded->fen, start_fen);
    LOAD_STR(moves, "moves", loaded->moves, start_moves);
    LOAD_DBL(probability, "probability", min_probability);
    LOAD_NUM(ply, "ply", max_depth);
    LOAD_NUM(eval_depth, "eval_depth", eval_depth);
    LOAD_NUM(threads, "threads", num_threads);
    LOAD_STR(ratings, "ratings", loaded->ratings, ratings);
    LOAD_STR(speeds, "speeds", loaded->speeds, speeds);
    LOAD_NUM(min_games, "min_games", min_games);
    LOAD_STR(stockfish, "stockfish", loaded->stockfish, stockfish_path);
    LOAD_BOOL(masters, "masters", use_masters);
    if (!exp->build_now && !exp->skip_build) {
        cJSON *bn = cJSON_GetObjectItemCaseSensitive(root, "build_now");
        if (cJSON_IsTrue(bn)) {
            *build_now = true;
            *skip_build = true;
        } else {
            cJSON *sb = cJSON_GetObjectItemCaseSensitive(root, "skip_build");
            if (cJSON_IsBool(sb)) *skip_build = cJSON_IsTrue(sb);
        }
    }
    LOAD_BOOL(traps, "traps", find_traps);
    LOAD_BOOL(traps_in_repertoire, "traps_in_repertoire", find_traps_in_repertoire);
    LOAD_STR(name, "name", loaded->repertoire_name, repertoire_name);
    LOAD_STR(maia_model, "maia_model", loaded->maia_model, maia_model_path);
    LOAD_NUM(maia_elo, "maia_elo", maia_elo);
    LOAD_DBL(maia_min_prob, "maia_min_prob", maia_min_prob);
    if (!exp->maia_only && !exp->lichess) {
        cJSON *mo = cJSON_GetObjectItemCaseSensitive(root, "maia_only");
        cJSON *li = cJSON_GetObjectItemCaseSensitive(root, "lichess");
        if (cJSON_IsBool(mo)) *maia_only = cJSON_IsTrue(mo);
        else if (cJSON_IsBool(li)) *maia_only = !cJSON_IsTrue(li);
    }
    if (!exp->absolute) {
        cJSON *ab = cJSON_GetObjectItemCaseSensitive(root, "absolute");
        if (cJSON_IsBool(ab)) *relative_eval = !cJSON_IsTrue(ab);
    }
    if (!exp->build_mode) {
        cJSON *bm = cJSON_GetObjectItemCaseSensitive(root, "build_mode");
        if (cJSON_IsString(bm) && bm->valuestring) {
            BuildMode parsed;
            if (build_mode_from_str(bm->valuestring, &parsed)) {
                *build_mode = parsed;
                snprintf(loaded->build_mode, sizeof(loaded->build_mode),
                         "%s", bm->valuestring);
                *build_mode_str = loaded->build_mode;
            }
        }
    }
    LOAD_STR(event_log, "event_log", loaded->event_log, event_log_path);
    LOAD_STR(lichess_eval_db, "lichess_eval_db", loaded->lichess_eval_db,
             lichess_eval_db_path);
    LOAD_STR(chessdb_eval_db, "chessdb_eval_db", loaded->chessdb_eval_db,
             chessdb_eval_db_path);
    LOAD_BOOL(chessdb_api, "chessdb_api", chessdb_api_enabled);
    LOAD_NUM(chessdb_api_quota, "chessdb_api_quota", chessdb_api_quota);
    LOAD_NUM(chessdb_api_concurrency, "chessdb_api_concurrency",
             chessdb_api_concurrency);
    if (!exp->no_ext_eval_subtree_skip) {
        cJSON *sk = cJSON_GetObjectItemCaseSensitive(root, "no_ext_eval_subtree_skip");
        if (cJSON_IsBool(sk)) *ext_eval_subtree_skip = !cJSON_IsTrue(sk);
    }
#ifdef HAS_CDBDIRECT
    LOAD_STR(cdbdirect_path, "cdbdirect_path", loaded->cdbdirect, cdbdirect_path);
    LOAD_BOOL(cdbdirect_read_ahead, "cdbdirect_read_ahead", cdbdirect_read_ahead);
    LOAD_BOOL(batch_eval_lookups, "batch_eval_lookups", batch_eval_lookups);
#endif
    if (!exp->pgn) {
        cJSON *pgn_arr = cJSON_GetObjectItemCaseSensitive(root, "pgn");
            if (cJSON_IsArray(pgn_arr)) {
            *pgn_file_count = 0;
            cJSON *item;
            cJSON_ArrayForEach(item, pgn_arr) {
                if (*pgn_file_count >= MAX_PGN_FILES) break;
                if (cJSON_IsString(item) && item->valuestring) {
                    int idx = *pgn_file_count;
                    snprintf(loaded->pgn[idx], PATH_MAX, "%s", item->valuestring);
                    pgn_files[idx] = loaded->pgn[idx];
                    (*pgn_file_count)++;
                }
            }
        }
    }
    LOAD_NUM(db_min_games, "db_min_games", db_min_games);
    LOAD_DBL(db_min_prob, "db_min_prob", db_min_prob);
    LOAD_BOOL(no_freq_cache, "no_freq_cache", no_freq_cache);
    LOAD_NUM(our_multipv, "our_multipv", our_multipv_arg);
    LOAD_NUM(max_eval_loss, "max_eval_loss", max_eval_loss_arg);
    if (!exp->max_eval_loss && *max_eval_loss_arg >= 0) *user_max_eval_loss = true;
    LOAD_NUM(opp_max_children, "opp_max_children", opp_max_children_arg);
    LOAD_DBL(opp_mass, "opp_mass", opp_mass_target_arg);
    LOAD_NUM(min_eval, "min_eval", min_eval_arg);
    if (!exp->min_eval && *min_eval_arg != -99999) *user_min_eval = true;
    LOAD_NUM(max_eval, "max_eval", max_eval_arg);
    LOAD_NUM(novelty_weight, "novelty_weight", novelty_weight_arg);
    if (!exp->novelty_weight && *novelty_weight_arg >= 0) *user_novelty_weight = true;
    LOAD_DBL(leaf_confidence, "leaf_confidence", leaf_confidence_arg);
    LOAD_BOOL(verbose, "verbose", verbose);

    if (!exp->preset) {
        cJSON *pr = cJSON_GetObjectItemCaseSensitive(root, "preset");
        if (cJSON_IsString(pr) && pr->valuestring && pr->valuestring[0]) {
            snprintf(loaded->preset, sizeof(loaded->preset), "%s",
                     pr->valuestring);
            *mode_name = loaded->preset;
            if (strcmp(loaded->preset, "solid") == 0) *mode_id = 1;
            else if (strcmp(loaded->preset, "practical") == 0) *mode_id = 2;
            else if (strcmp(loaded->preset, "tricky") == 0) *mode_id = 3;
            else if (strcmp(loaded->preset, "traps") == 0) *mode_id = 4;
            else if (strcmp(loaded->preset, "fresh") == 0) *mode_id = 5;
        }
    }

#undef LOAD_STR
#undef LOAD_BOOL
#undef LOAD_NUM
#undef LOAD_DBL

    cJSON_Delete(root);
    return true;
}

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
static EnginePool *g_engine_pool = NULL;
volatile int g_interrupted = 0;

/** Default -t: half of online CPU cores, at least 1. */
static int default_thread_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) n = 1;
    int half = (int)(n / 2);
    return half < 1 ? 1 : half;
}

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
    printf("  -d, --ply <N>          Max tree depth in ply (half-moves) [default: 20]\n");
    printf("  -e, --eval-depth <N>   Stockfish search depth [default: 16]\n");
    printf("  -t, --threads <N>      Total CPU cores to use [default: %d, half of CPUs]\n",
           default_thread_count());
    printf("  --build-mode <mode>    Build algorithm: stockfish-expectimax [default],\n");
    printf("                         maia-db-explore, db-explorer, trap-finder\n");
    printf("  --pgn <file>           PGN database file (repeatable, db-explorer mode)\n");
    printf("  --no-freq-cache        Force PGN reparse (ignore <name>.freq.bin)\n");
    printf("  --db-min-games <N>     Min games per move in PGN DB [default: 3]\n");
    printf("  --db-min-prob <P>      Min move probability in PGN DB [default: 0.05]\n");
    printf("  --min-elo <N>          Skip PGN games where both players are below N Elo [default: 2100]\n");
    printf("  -S, --stockfish <path> Stockfish binary path\n");
    printf("  -D, --database <path>  SQLite database path [default: <name>.db]\n");
    printf("  -I, --input-db <path>  Import eval/explorer cache from another DB\n");
    printf("                         (only for new/empty target databases)\n");
    printf("  -L, --load <file>      Load tree from a different JSON file\n");
    printf("  --resume               Restore CLI flags from <name>.db (overrides optional)\n");
    printf("  --skip-build           Skip tree building (use existing tree)\n");
    printf("  --build-now            Use existing partial tree as-is (skip to repertoire generation)\n");
    printf("\n");
    printf("Our-move candidates (engine-driven):\n");
    printf("  --our-multipv <N>      MultiPV count away from root [default: 5; root uses max(N,10)]\n");
    printf("  --max-eval-loss <cp>   Skip candidates more than N cp worse than best [default: 50]\n");
    printf("\n");
    printf("Opponent-move selection:\n");
    printf("  --opp-max-children <N> Max opponent responses per position [default: 6]\n");
    printf("  --opp-mass <0-1>       Mass target at every depth [default: 0.95]\n");
    printf("  --best-first / --bfs   Frontier order: priority (default) or FIFO level order\n");
    printf("  --alt-discount <0-1>   Priority multiplier for non-best our-move candidates [default: 0.25]\n");
    printf("  --maia-prior <N>       Dirichlet prior weight (virtual games) blending DB\n");
    printf("                         frequencies with Maia; 0 disables [default: 30]\n");
    printf("  --cover-min-prob <0-1> No-silent-holes floor: opponent replies at/above this\n");
    printf("                         local probability always get a repertoire answer;\n");
    printf("                         0 disables [default: 0.05]\n");
    printf("  --verify / --no-verify Deep-recheck every selected move after selection and\n");
    printf("                         replace moves losing > max-eval-loss at the verify\n");
    printf("                         depth [default: verify]\n");
    printf("  --verify-depth <N>     Stockfish depth for verification; 0 = auto\n");
    printf("                         (eval depth + 6, at least 20) [default: auto]\n");
    printf("  --setup \"<SAN...>\"     Preferred setup to play whenever sound, e.g.\n");
    printf("                         \"Be3 Qd2 f3 O-O-O h4 Nh3\": legal setup moves are\n");
    printf("                         evaluated as candidates and selection prefers them\n");
    printf("                         within the tolerance [default: off]\n");
    printf("  --setup-tolerance <cp> Max eval loss vs best move for a setup move to be\n");
    printf("                         preferred [default: 30]\n");
    printf("  --maia-only            Use Maia for opponent moves [default]\n");
    printf("  --lichess              Use Lichess API for opponent moves instead\n");
    printf("  --maia-model <path>    Path to maia3_simplified.onnx [default: auto-detect]\n");
    printf("  --maia-elo <N>         Elo for Maia predictions [default: 2200]\n");
    printf("  --maia-min-prob <P>    Skip Maia moves below this [default: 0.05]\n");
    printf("\n");
    printf("Eval window pruning:\n");
    printf("  --min-eval <cp>        Prune branch if our eval drops below this [default: color-dependent]\n");
    printf("  --max-eval <cp>        Prune branch if our eval exceeds this [default: color-dependent]\n");
    printf("  --absolute             Use absolute cp thresholds (default: relative to root eval)\n");
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
    printf("Lichess community eval DB (fast path for opponent-node evals):\n");
    printf("  --lichess-eval-db <path>  Slim SQLite built by build_lichess_eval_db\n");
    printf("                            (depth must meet -e)\n\n");
    printf("ChessDB eval sources (3-phase chain: local DB → API → Stockfish):\n");
    printf("  --chessdb-eval-db <path>  Local ChessDB SQLite slice (same schema)\n");
#ifdef HAS_CDBDIRECT
    printf("  --cdbdirect-path <dir>    TerarkDB ChessDB full dump data directory\n");
    printf("                            (e.g. /mnt/hdd/chessdb/data — ~1TB on HDD)\n");
    printf("  --cdbdirect-read-ahead    Hint sequential access (recommended on HDD)\n");
    printf("  --batch-eval-lookups      Sort/prefetch cdbdirect lookups per BFS level\n");
#endif
    printf("  --chessdb-api             Enable ChessDB cloud API (queryscore)\n");
    printf("  --chessdb-api-quota <N>   Daily API query limit [default: 5000]\n");
    printf("  --chessdb-api-concurrency <N>  Parallel HTTP cap [default: 2]\n");
    printf("  --no-ext-eval-subtree-skip  Disable off-book subtree skip heuristic\n\n");
    printf("Examples:\n");
    printf("  %s -c w -e 20 -t 4 -v repertoire\n", prog_name);
    printf("  %s -c b -f \"FEN\" -n \"Modern Benoni\" modern_benoni\n", prog_name);
    printf("  %s -c w --moves \"e4 d5 exd5 Qxd5\" scandinavian\n", prog_name);
    printf("  %s -c b -v modern_benoni   # resumes from modern_benoni.tree.json\n", prog_name);
    printf("  %s SicilianKan --resume      # restore all flags from SicilianKan.db\n", prog_name);
    printf("  %s -c b --build-now modern_benoni  # use partial tree as-is, generate lines\n", prog_name);
    printf("\n");
}


static void format_int_commas(int n, char *buf, size_t len) {
    if (n < 0) {
        snprintf(buf, len, "-%d", -n);
        return;
    }
    char raw[32];
    snprintf(raw, sizeof(raw), "%d", n);
    size_t raw_len = strlen(raw);
    if (raw_len <= 3) {
        snprintf(buf, len, "%s", raw);
        return;
    }
    size_t pos = 0;
    size_t lead = raw_len % 3;
    if (lead == 0) lead = 3;
    for (size_t i = 0; i < raw_len && pos + 1 < len; i++) {
        if (i == lead || (i > lead && (i - lead) % 3 == 0))
            buf[pos++] = ',';
        buf[pos++] = raw[i];
    }
    buf[pos] = '\0';
}

static const char *format_eta(int sec, char *buf, size_t len) {
    if (sec < 60)
        snprintf(buf, len, "%ds", sec);
    else if (sec < 3600)
        snprintf(buf, len, "%dm", (sec + 59) / 60);
    else
        snprintf(buf, len, "%dh %dm", sec / 3600, ((sec % 3600) + 59) / 60);
    return buf;
}

static void progress_callback(const BuildProgressInfo *info) {
    char new_buf[32], trans_buf[32], total_buf[32], eta_buf[32], line[320];

    format_int_commas(info->new_nodes_at_depth, new_buf, sizeof(new_buf));
    format_int_commas(info->transpositions_at_depth, trans_buf, sizeof(trans_buf));
    format_int_commas(info->total_nodes, total_buf, sizeof(total_buf));

    const char *eta = info->eta_depth_seconds > 0
        ? format_eta(info->eta_depth_seconds, eta_buf, sizeof(eta_buf))
        : NULL;

    if (eta) {
        snprintf(line, sizeof(line),
                 "  [Depth %d] %s new + %s transpositions | %s total | %.1f/min | ~%s",
                 info->current_depth,
                 new_buf,
                 trans_buf,
                 total_buf,
                 info->nodes_per_minute,
                 eta);
    } else {
        snprintf(line, sizeof(line),
                 "  [Depth %d] %s new + %s transpositions | %s total | %.1f/min",
                 info->current_depth,
                 new_buf,
                 trans_buf,
                 total_buf,
                 info->nodes_per_minute);
    }
    progress_line_update(line);
}

static void pipeline_progress(const char *stage, int current, int total) {
    char line[128];
    if (total > 0) {
        double pct = 100.0 * current / total;
        snprintf(line, sizeof(line), "  [%s] %d/%d (%.1f%%)", stage, current, total, pct);
    } else {
        snprintf(line, sizeof(line), "  [%s] %d...", stage, current);
    }
    progress_line_update(line);
}


static void signal_handler(int sig) {
    (void)sig;
    g_interrupted = 1;
    if (g_tree) tree_stop_build(g_tree);
    if (g_engine_pool) engine_pool_request_stop(g_engine_pool);
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

static EnginePool *create_stockfish_engine_pool(const char *stockfish_path,
                                                int num_threads, int eval_depth) {
    const char *sf_path = find_stockfish(stockfish_path);
    if (!sf_path) {
        fprintf(stderr, "Error: Stockfish not found. Use -S <path>.\n");
        fprintf(stderr, "  Searched: ");
        for (int i = 0; STOCKFISH_SEARCH_PATHS[i]; i++)
            fprintf(stderr, "%s ", STOCKFISH_SEARCH_PATHS[i]);
        fprintf(stderr, "\n");
        return NULL;
    }

    printf("Starting Stockfish engines...\n");
    printf("  Stockfish: %s\n", sf_path);
    printf("  Engines: %d | Depth: %d\n", num_threads, eval_depth);
    return engine_pool_create(sf_path, num_threads, eval_depth, num_threads);
}

static char *build_pgn_freq_manifest(int pgn_file_count, const char **pgn_files,
                                   const char *start_moves, int max_ply,
                                   int min_elo) {
    cJSON *root = cJSON_CreateObject();
    if (!root) return NULL;

    cJSON_AddNumberToObject(root, "format_version", PGN_FREQ_CACHE_FORMAT_VERSION);
    if (start_moves && start_moves[0])
        cJSON_AddStringToObject(root, "start_moves", start_moves);
    else
        cJSON_AddNullToObject(root, "start_moves");
    cJSON_AddNumberToObject(root, "max_ply", max_ply);
    cJSON_AddNumberToObject(root, "min_elo", min_elo);

    cJSON *files = cJSON_AddArrayToObject(root, "files");
    if (!files) {
        cJSON_Delete(root);
        return NULL;
    }

    for (int i = 0; i < pgn_file_count; i++) {
        struct stat st;
        if (stat(pgn_files[i], &st) != 0) {
            fprintf(stderr, "Error: cannot stat PGN file '%s': %s\n",
                    pgn_files[i], strerror(errno));
            cJSON_Delete(root);
            return NULL;
        }
        cJSON *f = cJSON_CreateObject();
        if (!f) {
            cJSON_Delete(root);
            return NULL;
        }
        cJSON_AddStringToObject(f, "path", pgn_files[i]);
        cJSON_AddNumberToObject(f, "size", (double)st.st_size);
        cJSON_AddNumberToObject(f, "mtime", (double)st.st_mtime);
        cJSON_AddItemToArray(files, f);
    }

    char *json = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return json;
}

typedef struct {
    const char **paths;
    int file_count;
    PgnFreqConfig cfg;
    PgnFreqMap **local_maps;
    int *local_games;
    int next_file;
    pthread_mutex_t lock;
    pthread_mutex_t print_lock;
} PgnParallelParseCtx;

static void *pgn_parse_worker(void *arg) {
    PgnParallelParseCtx *ctx = (PgnParallelParseCtx *)arg;

    for (;;) {
        int idx;
        pthread_mutex_lock(&ctx->lock);
        idx = ctx->next_file++;
        pthread_mutex_unlock(&ctx->lock);

        if (idx >= ctx->file_count || g_interrupted)
            break;

        PgnFreqMap *local = pgn_freq_map_create();
        int games = 0;
        if (local)
            games = pgn_freq_load_file(local, &ctx->cfg, ctx->paths[idx]);

        ctx->local_maps[idx] = local;
        ctx->local_games[idx] = games;

        pthread_mutex_lock(&ctx->print_lock);
        printf("  Parsed %s: %d games\n", ctx->paths[idx], games);
        pthread_mutex_unlock(&ctx->print_lock);
    }
    return NULL;
}

/** Parse PGN files into a new frequency map. Returns NULL on failure. */
static PgnFreqMap *parse_pgn_files_parallel(const char **paths, int file_count,
                                            const PgnFreqConfig *cfg,
                                            int num_threads, int *out_games) {
    PgnFreqMap *freq = pgn_freq_map_create();
    if (!freq) return NULL;

    if (file_count <= 0) {
        *out_games = 0;
        return freq;
    }

    if (file_count == 1) {
        int g = pgn_freq_load_file(freq, cfg, paths[0]);
        printf("  Parsed %s: %d games\n", paths[0], g);
        *out_games = g;
        return freq;
    }

    int workers = file_count < num_threads ? file_count : num_threads;
    if (workers < 1) workers = 1;

    PgnFreqMap **local_maps =
        (PgnFreqMap **)calloc((size_t)file_count, sizeof(PgnFreqMap *));
    int *local_games = (int *)calloc((size_t)file_count, sizeof(int));
    pthread_t *threads = (pthread_t *)calloc((size_t)workers, sizeof(pthread_t));
    if (!local_maps || !local_games || !threads) {
        free(local_maps);
        free(local_games);
        free(threads);
        pgn_freq_map_destroy(freq);
        return NULL;
    }

    PgnParallelParseCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.paths = paths;
    ctx.file_count = file_count;
    ctx.cfg = *cfg;
    ctx.local_maps = local_maps;
    ctx.local_games = local_games;
    pthread_mutex_init(&ctx.lock, NULL);
    pthread_mutex_init(&ctx.print_lock, NULL);

    for (int t = 0; t < workers; t++) {
        if (pthread_create(&threads[t], NULL, pgn_parse_worker, &ctx) != 0) {
            fprintf(stderr, "Error: failed to create PGN parse thread\n");
            g_interrupted = 1;
            break;
        }
    }

    for (int t = 0; t < workers; t++) {
        if (threads[t])
            pthread_join(threads[t], NULL);
        if (g_interrupted)
            break;
    }

    pthread_mutex_destroy(&ctx.lock);
    pthread_mutex_destroy(&ctx.print_lock);
    free(threads);

    int total_games = 0;
    bool merge_ok = !g_interrupted;

    for (int i = 0; i < file_count && merge_ok; i++) {
        if (!local_maps[i]) {
            merge_ok = false;
            break;
        }
        total_games += local_games[i];
        if (!pgn_freq_map_merge(freq, local_maps[i]))
            merge_ok = false;
        pgn_freq_map_destroy(local_maps[i]);
        local_maps[i] = NULL;
    }

    if (!merge_ok || g_interrupted) {
        for (int i = 0; i < file_count; i++) {
            if (local_maps[i])
                pgn_freq_map_destroy(local_maps[i]);
        }
        free(local_maps);
        free(local_games);
        pgn_freq_map_destroy(freq);
        *out_games = total_games;
        return NULL;
    }

    free(local_maps);
    free(local_games);

    *out_games = total_games;
    return freq;
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
    progress_line_init();

    /* Configuration with defaults */
    const char *start_fen = DEFAULT_FEN;
    const char *start_moves = NULL;
    char computed_fen[256] = {0};
    const char *base_name = NULL;
    char pgn_path[PATH_MAX] = {0};
    char tree_path[PATH_MAX] = {0};
    const char *db_path = NULL;
    const char *input_db_path = NULL;
    char db_path_buf[PATH_MAX] = {0};
    const char *stockfish_path = NULL;
    const char *load_tree_file = NULL;
    double min_probability = 0.0001;
    int max_depth = 20;
    int eval_depth = 16;
    int num_threads = default_thread_count();

    const char *ratings = "2000,2200,2500";
    const char *speeds = "blitz,rapid,classical";
    int min_games = 10;
    bool play_as_white = false;  /* No default - must be specified */
    bool color_specified = false;
    bool verbose = false;
    bool use_masters = false;
    bool skip_build = false;
    bool build_now = false;
    bool find_traps = false;
    bool find_traps_in_repertoire = false;
    const char *lichess_token = NULL;
    const char *repertoire_name = NULL;
    const char *maia_model_path = NULL;
    int maia_elo = 2200;
    double maia_min_prob = 0.05;
    bool maia_only = true;
    bool relative_eval = true;
    BuildMode build_mode = BUILD_MODE_STOCKFISH_EXPECTIMAX;
    const char *build_mode_str = NULL;
    const char *event_log_path = NULL;
    const char *lichess_eval_db_path = NULL;
    const char *chessdb_eval_db_path = NULL;
    bool chessdb_api_enabled = false;
    int chessdb_api_quota = 5000;
    int chessdb_api_concurrency = 2;
    bool ext_eval_subtree_skip = true;
#ifdef HAS_CDBDIRECT
    const char *cdbdirect_path = NULL;
    bool cdbdirect_read_ahead = false;
    bool batch_eval_lookups = false;
#endif
    const char *pgn_files[MAX_PGN_FILES];
    int pgn_file_count = 0;
    int db_min_games = 3;
    double db_min_prob = 0.05;
    int min_elo = 2100;
    bool no_freq_cache = false;

    /* Our-move overrides (-1 = use default) */
    int our_multipv_arg = -1;
    int max_eval_loss_arg = -1;

    /* Opponent-move overrides */
    int opp_max_children_arg = -1;
    double opp_mass_target_arg = -1.0;

    /* Frontier discipline overrides (-1 = use defaults) */
    int best_first_arg = -1;        /* 1 = best-first (default), 0 = FIFO BFS */
    double alt_discount_arg = -1.0;
    double maia_prior_arg = -1.0;

    /* Coverage / verification overrides (-1 = use defaults) */
    double cover_min_prob_arg = -1.0;
    int verify_arg = -1;            /* 1 = verify (default), 0 = skip */
    int verify_depth_arg = -1;      /* 0/unset = auto (eval_depth+6, min 20) */

    /* Preferred-setup overrides */
    const char *setup_moves_arg = NULL;
    int setup_tolerance_arg = -1;

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

    bool resume_flag = false;
    CliExplicit cli_exp = {0};
    CliLoadedStrings cli_loaded = {0};

    static struct option long_options[] = {
        {"fen",              required_argument, 0, 'f'},
        {"moves",            required_argument, 0, 1010},
        {"color",            required_argument, 0, 'c'},
        {"probability",      required_argument, 0, 'p'},
        {"ply",              required_argument, 0, 'd'},
        {"eval-depth",       required_argument, 0, 'e'},
        {"threads",          required_argument, 0, 't'},
        {"ratings",          required_argument, 0, 'r'},
        {"speeds",           required_argument, 0, 's'},
        {"min-games",        required_argument, 0, 'g'},
        {"stockfish",        required_argument, 0, 'S'},
        {"database",         required_argument, 0, 'D'},
        {"input-db",         required_argument, 0, 'I'},
        {"load",             required_argument, 0, 'L'},
        {"name",             required_argument, 0, 'n'},
        {"masters",          no_argument,       0, 'm'},
        {"skip-build",       no_argument,       0, 1001},
        {"build-now",        no_argument,       0, 1002},
        {"traps",            no_argument,       0, 1004},
        {"traps-in-repertoire", no_argument,    0, 1005},
        {"token",            required_argument, 0, 1006},
        /* Our-move */
        {"our-multipv",      required_argument, 0, 2001},
        {"max-eval-loss",    required_argument, 0, 2005},
        /* Opponent-move */
        {"opp-max-children", required_argument, 0, 2010},
        {"opp-mass",         required_argument, 0, 2011},
        /* Frontier discipline */
        {"best-first",       no_argument,       0, 2050},
        {"bfs",              no_argument,       0, 2051},
        {"alt-discount",     required_argument, 0, 2052},
        {"maia-prior",       required_argument, 0, 2053},
        {"cover-min-prob",   required_argument, 0, 2054},
        {"verify",           no_argument,       0, 2055},
        {"no-verify",        no_argument,       0, 2056},
        {"verify-depth",     required_argument, 0, 2057},
        {"setup",            required_argument, 0, 2058},
        {"setup-tolerance",  required_argument, 0, 2059},
        /* Eval window */
        {"min-eval",         required_argument, 0, 2020},
        {"max-eval",         required_argument, 0, 2021},
        {"absolute",         no_argument,       0, 2022},
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
        {"maia-only",        no_argument,       0, 3005},
        {"lichess",          no_argument,       0, 3006},
        {"build-mode",       required_argument, 0, 3007},
        {"pgn",              required_argument, 0, 5001},
        {"db-min-games",     required_argument, 0, 5002},
        {"db-min-prob",      required_argument, 0, 5003},
        {"no-freq-cache",    no_argument,       0, 5004},
        {"min-elo",          required_argument, 0, 5005},
        /* General */
        {"event-log",        required_argument, 0, 4001},
        {"lichess-eval-db",  required_argument, 0, 4002},
        {"chessdb-eval-db",  required_argument, 0, 4010},
        {"chessdb-api",      no_argument,       0, 4011},
        {"chessdb-api-quota", required_argument, 0, 4012},
        {"chessdb-api-concurrency", required_argument, 0, 4013},
        {"no-ext-eval-subtree-skip", no_argument, 0, 4014},
#ifdef HAS_CDBDIRECT
        {"cdbdirect-path",   required_argument, 0, 4020},
        {"cdbdirect-read-ahead", no_argument,   0, 4021},
        {"batch-eval-lookups", no_argument,     0, 4022},
#endif
        {"resume",           no_argument,       0, 1003},
        {"verbose",          no_argument,       0, 'v'},
        {"help",             no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt, option_index = 0;
    while ((opt = getopt_long(argc, argv, "f:c:p:d:e:t:r:s:g:S:D:I:L:n:mvh",
                              long_options, &option_index)) != -1) {
        switch (opt) {
            case 'f': start_fen = optarg; cli_exp.fen = true; break;
            case 1010: start_moves = optarg; cli_exp.moves = true; break;
            case 'c':
                play_as_white = (optarg[0] == 'w' || optarg[0] == 'W');
                color_specified = true;
                cli_exp.color = true;
                break;
            case 'p':
                if (!parse_double(optarg, "probability", &min_probability)) return 1;
                if (min_probability <= 0 || min_probability > 1) {
                    fprintf(stderr, "Error: probability must be in (0, 1]\n"); return 1;
                }
                cli_exp.probability = true;
                break;
            case 'd':
                if (!parse_int(optarg, "ply", &max_depth)) return 1;
                cli_exp.ply = true;
                break;
            case 'e':
                if (!parse_int(optarg, "eval-depth", &eval_depth)) return 1;
                cli_exp.eval_depth = true;
                break;
            case 't':
                if (!parse_int(optarg, "threads", &num_threads)) return 1;
                cli_exp.threads = true;
                break;
            case 'r': ratings = optarg; cli_exp.ratings = true; break;
            case 's': speeds = optarg; cli_exp.speeds = true; break;
            case 'g':
                if (!parse_int(optarg, "min-games", &min_games)) return 1;
                cli_exp.min_games = true;
                break;
            case 'S': stockfish_path = optarg; cli_exp.stockfish = true; break;
            case 'D': db_path = optarg; cli_exp.database = true; break;
            case 'I': input_db_path = optarg; break;
            case 'L': load_tree_file = optarg; break;
            case 'n': repertoire_name = optarg; cli_exp.name = true; break;
            case 'm': use_masters = true; cli_exp.masters = true; break;
            case 'v': verbose = true; cli_exp.verbose = true; break;
            case 'h': print_usage(argv[0]); return 0;
            case 1001: skip_build = true; cli_exp.skip_build = true; break;
            case 1002: build_now = true; skip_build = true; cli_exp.build_now = true; break;
            case 1003: resume_flag = true; break;
            case 1004: mode_id = 4; find_traps = true; cli_exp.traps = true; break;
            case 1005: find_traps_in_repertoire = true; cli_exp.traps_in_repertoire = true; break;
            case 1006: lichess_token = optarg; break;
            /* Our-move */
            case 2001:
                if (!parse_int(optarg, "our-multipv", &our_multipv_arg)) return 1;
                cli_exp.our_multipv = true;
                break;
            case 2005:
                if (!parse_int(optarg, "max-eval-loss", &max_eval_loss_arg)) return 1;
                user_max_eval_loss = true;
                cli_exp.max_eval_loss = true;
                break;
            /* Opponent-move */
            case 2010:
                if (!parse_int(optarg, "opp-max-children", &opp_max_children_arg)) return 1;
                cli_exp.opp_max_children = true;
                break;
            case 2011:
                if (!parse_double(optarg, "opp-mass", &opp_mass_target_arg)) return 1;
                cli_exp.opp_mass = true;
                break;
            /* Frontier discipline */
            case 2050: best_first_arg = 1; break;
            case 2051: best_first_arg = 0; break;
            case 2052:
                if (!parse_double(optarg, "alt-discount", &alt_discount_arg)) return 1;
                if (alt_discount_arg < 0 || alt_discount_arg > 1) {
                    fprintf(stderr, "Error: --alt-discount must be in [0, 1]\n");
                    return 1;
                }
                break;
            case 2053:
                if (!parse_double(optarg, "maia-prior", &maia_prior_arg)) return 1;
                if (maia_prior_arg < 0) {
                    fprintf(stderr, "Error: --maia-prior must be >= 0\n");
                    return 1;
                }
                break;
            /* Coverage / verification */
            case 2054:
                if (!parse_double(optarg, "cover-min-prob",
                                  &cover_min_prob_arg)) return 1;
                if (cover_min_prob_arg < 0 || cover_min_prob_arg > 1) {
                    fprintf(stderr,
                            "Error: --cover-min-prob must be in [0, 1]\n");
                    return 1;
                }
                break;
            case 2055: verify_arg = 1; break;
            case 2056: verify_arg = 0; break;
            case 2057:
                if (!parse_int(optarg, "verify-depth", &verify_depth_arg))
                    return 1;
                if (verify_depth_arg < 0 || verify_depth_arg > 60) {
                    fprintf(stderr,
                            "Error: --verify-depth must be in [0, 60]\n");
                    return 1;
                }
                break;
            /* Preferred setup */
            case 2058: setup_moves_arg = optarg; break;
            case 2059:
                if (!parse_int(optarg, "setup-tolerance",
                               &setup_tolerance_arg))
                    return 1;
                if (setup_tolerance_arg < 0 || setup_tolerance_arg > 500) {
                    fprintf(stderr,
                            "Error: --setup-tolerance must be in [0, 500]\n");
                    return 1;
                }
                break;
            /* Eval window */
            case 2020:
                if (!parse_int(optarg, "min-eval", &min_eval_arg)) return 1;
                user_min_eval = true;
                cli_exp.min_eval = true;
                break;
            case 2021:
                if (!parse_int(optarg, "max-eval", &max_eval_arg)) return 1;
                cli_exp.max_eval = true;
                break;
            case 2022: relative_eval = false; cli_exp.absolute = true; break;
            /* Expectimax scoring */
            case 2031:
                if (!parse_double(optarg, "leaf-confidence", &leaf_confidence_arg)) return 1;
                cli_exp.leaf_confidence = true;
                break;
            case 2034: {
                int nw;
                if (!parse_int(optarg, "novelty-weight", &nw)) return 1;
                if (nw < 0 || nw > 100) {
                    fprintf(stderr, "Error: --novelty-weight must be between 0 and 100\n");
                    return 1;
                }
                novelty_weight_arg = nw;
                user_novelty_weight = true;
                cli_exp.novelty_weight = true;
                break;
            }
            case 2040: mode_id = 1; cli_exp.preset = true; break;
            case 2041: mode_id = 2; cli_exp.preset = true; break;
            case 2042: mode_id = 3; cli_exp.preset = true; break;
            case 2044: mode_id = 5; cli_exp.preset = true; break;
            /* 2006 removed: --sf-threads folded into -t */
            /* Maia */
            case 3001: maia_model_path = optarg; cli_exp.maia_model = true; break;
            case 3002:
                if (!parse_int(optarg, "maia-elo", &maia_elo)) return 1;
                cli_exp.maia_elo = true;
                break;
            case 3004:
                if (!parse_double(optarg, "maia-min-prob", &maia_min_prob)) return 1;
                cli_exp.maia_min_prob = true;
                break;
            case 3005: maia_only = true; cli_exp.maia_only = true; break;
            case 3006: maia_only = false; cli_exp.lichess = true; break;
            case 3007: build_mode_str = optarg; cli_exp.build_mode = true; break;
            case 5001:
                if (pgn_file_count >= MAX_PGN_FILES) {
                    fprintf(stderr, "Error: at most %d --pgn files allowed\n",
                            MAX_PGN_FILES);
                    return 1;
                }
                pgn_files[pgn_file_count++] = optarg;
                cli_exp.pgn = true;
                break;
            case 5002:
                if (!parse_int(optarg, "db-min-games", &db_min_games)) return 1;
                cli_exp.db_min_games = true;
                break;
            case 5003:
                if (!parse_double(optarg, "db-min-prob", &db_min_prob)) return 1;
                cli_exp.db_min_prob = true;
                break;
            case 5004: no_freq_cache = true; cli_exp.no_freq_cache = true; break;
            case 5005:
                if (!parse_int(optarg, "min-elo", &min_elo)) return 1;
                cli_exp.min_elo = true;
                break;
            case 4001: event_log_path = optarg; cli_exp.event_log = true; break;
            case 4002: lichess_eval_db_path = optarg; cli_exp.lichess_eval_db = true; break;
            case 4010: chessdb_eval_db_path = optarg; cli_exp.chessdb_eval_db = true; break;
            case 4011: chessdb_api_enabled = true; cli_exp.chessdb_api = true; break;
            case 4012:
                if (!parse_int(optarg, "chessdb-api-quota", &chessdb_api_quota)) return 1;
                cli_exp.chessdb_api_quota = true;
                break;
            case 4013:
                if (!parse_int(optarg, "chessdb-api-concurrency",
                               &chessdb_api_concurrency)) return 1;
                cli_exp.chessdb_api_concurrency = true;
                break;
            case 4014: ext_eval_subtree_skip = false; cli_exp.no_ext_eval_subtree_skip = true; break;
#ifdef HAS_CDBDIRECT
            case 4020: cdbdirect_path = optarg; cli_exp.cdbdirect_path = true; break;
            case 4021: cdbdirect_read_ahead = true; cli_exp.cdbdirect_read_ahead = true; break;
            case 4022: batch_eval_lookups = true; cli_exp.batch_eval_lookups = true; break;
#endif
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

    if (!db_path) {
        snprintf(db_path_buf, sizeof(db_path_buf), "%s.db", base_name);
        db_path = db_path_buf;
    }

    snprintf(pgn_path, sizeof(pgn_path), "%s.pgn", base_name);
    snprintf(tree_path, sizeof(tree_path), "%s.tree.json", base_name);

    if (resume_flag) {
        if (!load_config_from_db(
                db_path, base_name, &cli_exp, &cli_loaded,
                &start_fen, &start_moves, &play_as_white, &color_specified,
                &min_probability, &max_depth, &eval_depth, &num_threads,
                &ratings, &speeds, &min_games, &stockfish_path,
                &use_masters, &skip_build, &build_now, &find_traps,
                &find_traps_in_repertoire, &repertoire_name, &maia_model_path,
                &maia_elo, &maia_min_prob, &maia_only, &relative_eval,
                &build_mode, &build_mode_str, &event_log_path,
                &lichess_eval_db_path, &chessdb_eval_db_path,
                &chessdb_api_enabled, &chessdb_api_quota,
                &chessdb_api_concurrency, &ext_eval_subtree_skip,
#ifdef HAS_CDBDIRECT
                &cdbdirect_path, &cdbdirect_read_ahead, &batch_eval_lookups,
#endif
                pgn_files, &pgn_file_count, &db_min_games, &db_min_prob,
                &no_freq_cache, &our_multipv_arg, &max_eval_loss_arg,
                &opp_max_children_arg, &opp_mass_target_arg, &min_eval_arg,
                &max_eval_arg, &novelty_weight_arg, &leaf_confidence_arg,
                &mode_name, &mode_id, &user_min_eval, &user_max_eval_loss,
                &user_novelty_weight, &verbose)) {
            return 1;
        }
        print_resume_banner(play_as_white, start_fen, max_depth, eval_depth,
                            num_threads, maia_only, ratings, speeds,
                            mode_name, db_path);
    }

    if (build_mode_str) {
        if (strcmp(build_mode_str, "stockfish-expectimax") == 0 ||
            strcmp(build_mode_str, "stockfishExpectimax") == 0)
            build_mode = BUILD_MODE_STOCKFISH_EXPECTIMAX;
        else if (strcmp(build_mode_str, "maia-db-explore") == 0 ||
                 strcmp(build_mode_str, "maiaDbExplore") == 0)
            build_mode = BUILD_MODE_MAIA_DB_EXPLORE;
        else if (strcmp(build_mode_str, "db-explorer") == 0 ||
                 strcmp(build_mode_str, "dbExplorer") == 0)
            build_mode = BUILD_MODE_DB_EXPLORER;
        else if (strcmp(build_mode_str, "trap-finder") == 0 ||
                 strcmp(build_mode_str, "trapFinder") == 0)
            build_mode = BUILD_MODE_TRAP_FINDER;
        else {
            fprintf(stderr, "Error: unknown build mode '%s'\n", build_mode_str);
            fprintf(stderr, "  Valid: stockfish-expectimax, maia-db-explore, "
                            "db-explorer, trap-finder\n");
            return 1;
        }
    }

    if (build_mode == BUILD_MODE_TRAP_FINDER) {
        fprintf(stderr, "Error: build mode '%s' is not yet implemented\n",
                build_mode_str ? build_mode_str : "?");
        return 1;
    }

    if (build_mode == BUILD_MODE_DB_EXPLORER && pgn_file_count == 0) {
        fprintf(stderr, "Error: --build-mode db-explorer requires at least one --pgn file\n");
        return 1;
    }

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
        fprintf(stderr, "Error: --color (-c) is required. Specify 'w' for white or 'b' for black,\n");
        fprintf(stderr, "       or use --resume to restore settings from a previous run.\n");
        fprintf(stderr, "Usage: %s --color <w|b> [options] <name>\n", argv[0]);
        return 1;
    }

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

    /* Signal handlers */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

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
    if (maia)
        printf("  Maia model:       %s (elo=%d)\n", resolved_maia, maia_elo);
    if (maia_only)
        printf("  Opponent source:  Maia-only\n");
    else if (maia)
        printf("  Opponent source:  %s (Maia optional for novelty)\n",
               use_masters ? "Masters DB" : "Lichess API");
    else
        printf("  Opponent source:  %s\n",
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

    bool db_file_existed = access(db_path, F_OK) == 0;
    bool db_has_data = false;
    bool tree_file_existed = access(tree_path, F_OK) == 0;
    if ((tree_file_existed || load_tree_file) && !db_file_existed) {
        fprintf(stderr,
                "Warning: tree file found but database %s does not exist.\n",
                db_path);
        fprintf(stderr,
                "  Explorer/eval cache will be rebuilt; node evals in the tree are kept inline.\n\n");
    }

    if (db_file_existed) {
        char schema_issues[512];
        if (!rdb_validate_schema(db_path, schema_issues, sizeof(schema_issues),
                                 &db_has_data) && db_has_data) {
            fprintf(stderr,
                    "Warning: database %s appears incompatible with this version.\n",
                    db_path);
            if (schema_issues[0]) {
                fprintf(stderr, "  Missing: %s\n", schema_issues);
            }
            if (!confirm_yes_interactive(
                    "  Continue anyway? Cached data may be ignored or cause errors. [y/N] ")) {
                fprintf(stderr,
                        "Aborted. Use a different base name or delete %s and retry.\n",
                        db_path);
                if (maia) maia_destroy(maia);
                return 1;
            }
            fprintf(stderr, "\n");
        }
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

    if (input_db_path) {
        if (strcmp(input_db_path, db_path) == 0) {
            fprintf(stderr,
                    "Error: --input-db must differ from the target -D database.\n");
            rdb_close(db);
            if (maia) maia_destroy(maia);
            return 1;
        }
        if (db_file_existed && db_has_data) {
            fprintf(stderr,
                    "Error: --input-db can only be used with a new/empty "
                    "target database.\n");
            fprintf(stderr,
                    "  '%s' already exists and contains data.\n", db_path);
            rdb_close(db);
            if (maia) maia_destroy(maia);
            return 1;
        }
        if (rdb_has_cache_data(db)) {
            fprintf(stderr,
                    "Error: --input-db can only be used with a new/empty "
                    "target database.\n");
            fprintf(stderr,
                    "  '%s' already contains cached rows.\n", db_path);
            rdb_close(db);
            if (maia) maia_destroy(maia);
            return 1;
        }
        char import_issues[512];
        bool import_has_data = false;
        if (!rdb_validate_schema(input_db_path, import_issues,
                                 sizeof(import_issues), &import_has_data)) {
            fprintf(stderr,
                    "Error: cannot use '%s' as --input-db", input_db_path);
            if (import_issues[0])
                fprintf(stderr, ": %s", import_issues);
            fprintf(stderr, "\n");
            rdb_close(db);
            if (maia) maia_destroy(maia);
            return 1;
        }
        RdbCacheImportCounts imported;
        if (!rdb_import_cache_from(db, input_db_path, &imported)) {
            fprintf(stderr,
                    "Error: failed to import cache from '%s'\n",
                    input_db_path);
            rdb_close(db);
            if (maia) maia_destroy(maia);
            return 1;
        }
        printf("  Imported cache from %s:\n", input_db_path);
        printf("    evaluations:        %d rows\n", imported.evaluations);
        printf("    explorer_positions: %d rows\n", imported.explorer_positions);
        printf("    explorer_moves:     %d rows\n", imported.explorer_moves);
        printf("    multipv_cache:      %d rows\n", imported.multipv_cache);
        printf("    maia_cache:         %d rows\n", imported.maia_cache);
        printf("\n");
    }

    if (resume_flag) {
        store_build_metadata(db, play_as_white, ratings, speeds, false);
    } else if (!check_build_metadata(db, db_path, argv[0], db_file_existed, db_has_data,
                              play_as_white, ratings, speeds)) {
        rdb_close(db);
        if (maia) maia_destroy(maia);
        return 1;
    }

    if (!save_config_to_db(
            db, play_as_white, ratings, speeds, start_fen, start_moves,
            min_probability, max_depth, eval_depth, num_threads, min_games,
            stockfish_path, use_masters, skip_build, build_now, find_traps,
            find_traps_in_repertoire, repertoire_name, maia_model_path, maia_elo, maia_min_prob, maia_only,
            relative_eval, build_mode, event_log_path, lichess_eval_db_path,
            chessdb_eval_db_path, chessdb_api_enabled, chessdb_api_quota,
            chessdb_api_concurrency, ext_eval_subtree_skip,
#ifdef HAS_CDBDIRECT
            cdbdirect_path, cdbdirect_read_ahead, batch_eval_lookups,
#endif
            pgn_files, pgn_file_count, db_min_games, db_min_prob, no_freq_cache,
            our_multipv_arg, max_eval_loss_arg, opp_max_children_arg,
            opp_mass_target_arg, min_eval_arg, max_eval_arg, novelty_weight_arg,
            leaf_confidence_arg, mode_name, verbose)) {
        fprintf(stderr, "Warning: failed to save CLI configuration to database\n");
    }

    /* Optional: open the read-only Lichess community eval DB. */
    LichessEvalDB *eval_db = NULL;
    ChessDBEvalDB *chessdb_eval_db = NULL;
    ChessDBAPI *chessdb_api = NULL;
#ifdef HAS_CDBDIRECT
    CdbDirectEval *cdbdirect = NULL;
#endif
    if (lichess_eval_db_path) {
        eval_db = lichess_eval_db_open(lichess_eval_db_path);
        if (eval_db) {
            long n = lichess_eval_db_count(eval_db);
            if (n >= 0)
                printf("  Lichess eval DB:  %s (%ld rows)\n",
                       lichess_eval_db_path, n);
            else
                printf("  Lichess eval DB:  %s\n", lichess_eval_db_path);
        } else {
            fprintf(stderr,
                "  Warning: --lichess-eval-db %s could not be opened; continuing without it.\n",
                lichess_eval_db_path);
        }
    }

    if (chessdb_eval_db_path) {
        chessdb_eval_db = chessdb_eval_db_open(chessdb_eval_db_path);
        if (chessdb_eval_db) {
            long n = chessdb_eval_db_count(chessdb_eval_db);
            if (n >= 0)
                printf("  ChessDB eval DB:  %s (%ld rows)\n",
                       chessdb_eval_db_path, n);
            else
                printf("  ChessDB eval DB:  %s\n", chessdb_eval_db_path);
        } else {
            fprintf(stderr,
                "  Warning: --chessdb-eval-db %s could not be opened; continuing without it.\n",
                chessdb_eval_db_path);
        }
    }

#ifdef HAS_CDBDIRECT
    if (cdbdirect_path) {
        const char *resolved = cdbdirect_path;
        char env_path[PATH_MAX];
        if (!resolved[0]) {
            const char *chessdb_env = getenv("CHESSDB_PATH");
            if (chessdb_env && chessdb_env[0]) {
                snprintf(env_path, sizeof(env_path), "%s", chessdb_env);
                resolved = env_path;
            }
        }
        cdbdirect = cdbdirect_eval_open(resolved, cdbdirect_read_ahead);
        if (cdbdirect) {
            long n = cdbdirect_eval_count(cdbdirect);
            if (n >= 0)
                printf("  cdbdirect:        %s (%ld positions)\n", resolved, n);
            else
                printf("  cdbdirect:        %s\n", resolved);
            if (batch_eval_lookups)
                printf("  cdbdirect batch:  enabled (HDD-optimized prefetch)\n");
        } else {
            fprintf(stderr,
                "  Warning: --cdbdirect-path %s could not be opened; continuing without it.\n",
                resolved);
        }
    }
#endif

    if (chessdb_api_enabled) {
        ChessDBAPIConfig api_cfg = chessdb_api_config_default();
        api_cfg.enabled = true;
        api_cfg.daily_quota = chessdb_api_quota;
        api_cfg.max_concurrency = chessdb_api_concurrency;
        char quota_path[PATH_MAX];
        snprintf(quota_path, sizeof(quota_path), "%s.chessdb_quota", db_path);
        api_cfg.quota_persist_path = quota_path;
        chessdb_api = chessdb_api_create(&api_cfg);
        if (chessdb_api) {
            printf("  ChessDB API:      enabled (quota %d/day, concurrency %d)\n",
                   chessdb_api_quota, chessdb_api_concurrency);
        } else {
            fprintf(stderr, "  Warning: ChessDB API init failed; continuing without it.\n");
        }
    }

    bool defer_engine_pool =
        (!skip_build && build_mode == BUILD_MODE_DB_EXPLORER);

    if (!skip_build) {
        if (build_mode != BUILD_MODE_MAIA_DB_EXPLORE) {
            if (defer_engine_pool) {
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
                printf("  Engines: %d | Depth: %d (start after PGN seed)\n",
                       num_threads, eval_depth);
            } else {
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

                engine_pool = engine_pool_create(sf_path, num_threads, eval_depth,
                                                 num_threads);
                if (!engine_pool) {
                    fprintf(stderr, "Error: Failed to create engine pool\n");
                    if (maia) maia_destroy(maia);
                    rdb_close(db);
                    return 1;
                }
                g_engine_pool = engine_pool;
            }
        } else {
            printf("  Build mode: maia-db-explore (no Stockfish)\n");
            if (!maia) {
                fprintf(stderr, "Error: Maia model required for maia-db-explore mode\n");
                rdb_close(db);
                return 1;
            }
        }
    } else if (build_mode != BUILD_MODE_MAIA_DB_EXPLORE) {
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
        g_engine_pool = engine_pool;
    }
    printf("\n");

    /* ================================================================
     *  STAGE 1: Build Opening Tree (interleaved Lichess + Stockfish)
     * ================================================================ */
    Tree *tree = NULL;
    bool needs_build = !skip_build;

    const char *tree_source = load_tree_file ? load_tree_file : tree_path;

    if (load_tree_file || build_now || (!skip_build && access(tree_path, F_OK) == 0)) {
        tree = tree_load(tree_source);
        if (tree) {
            if (tree->root && tree->root->fen[0] &&
                !fen_keys_match(tree->root->fen, start_fen)) {
                char tree_fen_key[128];
                char req_fen_key[128];
                snprintf(tree_fen_key, sizeof(tree_fen_key), "%s", tree->root->fen);
                snprintf(req_fen_key, sizeof(req_fen_key), "%s", start_fen);
                eval_canonicalize_fen(tree_fen_key);
                eval_canonicalize_fen(req_fen_key);

                fprintf(stderr,
                        "\nWarning: loaded tree root FEN differs from requested start FEN.\n");
                fprintf(stderr, "  Tree root:  %s\n", tree_fen_key);
                fprintf(stderr, "  Requested:  %s\n", req_fen_key);
                if (!confirm_yes_interactive(
                        "  Continue with the existing tree (ignore --fen/--moves)? [y/N] ")) {
                    fprintf(stderr,
                            "Aborted. Use a different base name, delete %s, or pass "
                            "matching --fen/--moves.\n",
                            tree_source);
                    tree_destroy(tree);
                    if (engine_pool) engine_pool_destroy(engine_pool);
                    if (maia) maia_destroy(maia);
                    rdb_close(db);
                    return 1;
                }
                fprintf(stderr, "\n");
            }

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
                printf("[1/4] Resuming tree build from %s (%zu nodes, depth %d, target %d)\n",
                       tree_source, tree->total_nodes,
                       tree->max_depth_reached, max_depth);
                printf("  Continuing from unexplored leaves...\n\n");
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
        printf("[1/4] Skipped tree building (%s)\n",
               build_now ? "--build-now" : "--skip-build");
        fprintf(stderr, "Error: No tree available. Run a build first.\n");
        if (engine_pool) engine_pool_destroy(engine_pool);
        if (maia) maia_destroy(maia);
        rdb_close(db);
        return 1;
    }

    if (needs_build) {
        struct timespec build_start, build_end;
        size_t nodes_before = 0;
        double build_time = 0.0;
        bool success = false;
        LichessExplorer *explorer = NULL;
        TreeConfig config = tree_config_default();
        BuildStats build_stats;
        FILE *event_log_fp = NULL;
        bool built_from_db = (build_mode == BUILD_MODE_DB_EXPLORER);

        if (built_from_db) {
            printf("[1/4] Building opening tree from PGN database (db-explorer)...\n");
            printf("  DB filters: min_games=%d, min_prob=%.2f, min_elo=%d\n",
                   db_min_games, db_min_prob, min_elo);

            if (!tree) {
                tree = tree_create();
                if (!tree) {
                    fprintf(stderr, "Error: Failed to create tree\n");
                    if (engine_pool) engine_pool_destroy(engine_pool);
                    if (maia) maia_destroy(maia);
                    rdb_close(db);
                    return 1;
                }
            }

            if (start_moves) {
                strncpy(tree->start_moves, start_moves,
                        sizeof(tree->start_moves) - 1);
                tree->start_moves[sizeof(tree->start_moves) - 1] = '\0';
            }

            g_tree = tree;

            char freq_cache_path[PATH_MAX];
            snprintf(freq_cache_path, sizeof(freq_cache_path),
                     "%s.freq.bin", base_name);

            /* Parse full games from startpos; match --moves/--fen by position. */
            bool pgn_custom_fen = strcmp(start_fen, DEFAULT_FEN) != 0;
            PgnFreqConfig pgn_cfg = {
                .start_fen = (start_moves == NULL && pgn_custom_fen)
                                  ? start_fen
                                  : NULL,
                .start_moves = start_moves,
                .max_ply = 0,
                .min_elo = min_elo,
            };

            char *manifest = build_pgn_freq_manifest(
                pgn_file_count, pgn_files, start_moves, pgn_cfg.max_ply,
                pgn_cfg.min_elo);
            if (!manifest) {
                tree_destroy(tree);
                if (engine_pool) engine_pool_destroy(engine_pool);
                if (maia) maia_destroy(maia);
                rdb_close(db);
                return 1;
            }

            PgnFreqMap *freq = NULL;
            int parsed_games = 0;
            bool loaded_from_cache = false;

            if (!no_freq_cache) {
                freq = pgn_freq_map_load(freq_cache_path, manifest);
                if (freq) {
                    size_t map_positions = 0;
                    uint64_t map_total_games = 0;
                    pgn_freq_stats(freq, &map_positions, &map_total_games);
                    parsed_games = (int)map_total_games;
                    loaded_from_cache = true;
                    printf("Loading cached frequency map from %s (%zu positions, %llu games)\n",
                           freq_cache_path, map_positions,
                           (unsigned long long)map_total_games);
                }
            }

            if (!freq) {
                printf("Frequency map cache invalid/missing, reparsing PGN files...\n");
                freq = parse_pgn_files_parallel(
                    (const char **)pgn_files, pgn_file_count, &pgn_cfg,
                    num_threads, &parsed_games);
            }

            if (g_interrupted) {
                fprintf(stderr,
                        "\n  [INTERRUPTED] Stopped during PGN parse (%d games loaded).\n",
                        parsed_games);
                if (freq) pgn_freq_map_destroy(freq);
                free(manifest);
                tree_destroy(tree);
                if (engine_pool) engine_pool_destroy(engine_pool);
                if (maia) maia_destroy(maia);
                rdb_close(db);
                goto cleanup;
            }
            if (!freq || parsed_games == 0) {
                fprintf(stderr, "Error: No games parsed from PGN files\n");
                if (freq) pgn_freq_map_destroy(freq);
                free(manifest);
                tree_destroy(tree);
                if (engine_pool) engine_pool_destroy(engine_pool);
                if (maia) maia_destroy(maia);
                rdb_close(db);
                return 1;
            }

            if (!loaded_from_cache && !g_interrupted) {
                if (!pgn_freq_map_save(freq, freq_cache_path, manifest))
                    fprintf(stderr,
                            "  Warning: could not save frequency map cache to %s\n",
                            freq_cache_path);
            }
            free(manifest);

            size_t map_positions = 0;
            uint64_t map_total_games = 0;
            pgn_freq_stats(freq, &map_positions, &map_total_games);
            if (!loaded_from_cache)
                printf("  Frequency map: %zu positions, %llu games parsed\n",
                       map_positions, (unsigned long long)map_total_games);

            DbBuildConfig db_cfg = {
                .start_fen = start_fen,
                .play_as_white = play_as_white,
                .max_depth = max_depth,
                .min_probability = min_probability,
                .db_min_games = db_min_games,
                .db_min_prob = db_min_prob,
                .max_nodes = 0,
                .best_first = best_first_arg != 0,
                .maia = maia,
                .maia_elo = maia_elo,
                .maia_prior_games =
                    maia_prior_arg >= 0.0 ? maia_prior_arg : 30.0,
                .cover_min_prob =
                    cover_min_prob_arg >= 0.0 ? cover_min_prob_arg : 0.05,
            };

            clock_gettime(CLOCK_MONOTONIC, &build_start);
            nodes_before = tree->total_nodes;
            success = tree_build_from_freqmap(tree, freq, &db_cfg);
            clock_gettime(CLOCK_MONOTONIC, &build_end);
            build_time = (build_end.tv_sec - build_start.tv_sec) +
                         (build_end.tv_nsec - build_start.tv_nsec) / 1e9;

            pgn_freq_map_destroy(freq);

            if (!engine_pool) {
                engine_pool = create_stockfish_engine_pool(
                    stockfish_path, num_threads, eval_depth);
                if (!engine_pool) {
                    fprintf(stderr, "Error: Failed to create engine pool\n");
                    tree_destroy(tree);
                    if (maia) maia_destroy(maia);
                    rdb_close(db);
                    return 1;
                }
                g_engine_pool = engine_pool;
            }

            config.play_as_white = play_as_white;
            config.build_mode = build_mode;
            tree_config_set_color_defaults(&config);
            config.min_probability = min_probability;
            config.max_depth = max_depth;
            config.engine_pool = engine_pool;
            config.db = db;
            config.eval_depth = eval_depth;
            config.lichess_eval_db = eval_db;
            config.chessdb_eval_db = chessdb_eval_db;
            config.chessdb_api = chessdb_api;
#ifdef HAS_CDBDIRECT
            config.cdbdirect = cdbdirect;
            config.cdbdirect_read_ahead = cdbdirect_read_ahead;
            config.batch_eval_lookups = batch_eval_lookups;
#endif
            config.ext_eval_subtree_skip = ext_eval_subtree_skip;
            if (our_multipv_arg > 0) config.our_multipv = our_multipv_arg;
            if (max_eval_loss_arg >= 0) config.max_eval_loss_cp = max_eval_loss_arg;
            if (min_eval_arg != -99999) config.min_eval_cp = min_eval_arg;
            if (max_eval_arg != -99999) config.max_eval_cp = max_eval_arg;
            config.relative_eval = relative_eval;
            if (cover_min_prob_arg >= 0.0)
                config.cover_min_prob = cover_min_prob_arg;
            memset(&build_stats, 0, sizeof(build_stats));
            config.stats = &build_stats;
            tree->config = config;

            progress_line_clear();

            if (!success && !g_interrupted) {
                fprintf(stderr, "Error: DB tree building failed\n");
                tree_destroy(tree);
                if (engine_pool) engine_pool_destroy(engine_pool);
                if (maia) maia_destroy(maia);
                rdb_close(db);
                return 1;
            }
            if (g_interrupted) goto cleanup;

            printf("  DB tree built: %zu nodes in %.2fs (max depth %d, %d PGN games)\n",
                   tree->total_nodes, build_time, tree->max_depth_reached,
                   parsed_games);

            printf("  Enriching engine evaluations...\n");
            EvalEnrichStats enrich_stats;
            bool enrich_ok = tree_enrich_evals(tree, &config, &enrich_stats);
            printf("  Eval enrichment: %d cache hits, %d external, %d Stockfish, "
                   "%d failed (of %d nodes)\n",
                   enrich_stats.cache_hits, enrich_stats.ext_hits,
                   enrich_stats.sf_evals, enrich_stats.failed,
                   enrich_stats.total_nodes);
            if (!enrich_ok && enrich_stats.failed > 0) {
                double fail_rate = enrich_stats.total_nodes > 0
                    ? (double)enrich_stats.failed /
                      (double)enrich_stats.total_nodes
                    : 1.0;
                fprintf(stderr,
                        "\n*** WARNING: %d of %d nodes (%d%%) lack engine evals "
                        "after enrichment — expectimax/export may be misleading ***\n",
                        enrich_stats.failed, enrich_stats.total_nodes,
                        (int)(fail_rate * 100.0 + 0.5));
                if (fail_rate > 0.5) {
                    fprintf(stderr,
                            "Error: more than 50%% of nodes failed eval enrichment; "
                            "aborting.\n");
                    tree_destroy(tree);
                    if (engine_pool) engine_pool_destroy(engine_pool);
                    if (maia) maia_destroy(maia);
                    rdb_close(db);
                    return 1;
                }
            }

            /* No-silent-holes guarantee: with evals enriched and the
             * engine available, answer dangling our-turn leaves
             * (positions where the PGN games ran out) or remove them. */
            if (!g_interrupted)
                tree_coverage_sweep(tree, &config, NULL);

            tree_recalculate_probabilities(tree);
        } else {
        if (!tree) printf("[1/4] Building opening tree (%s)...\n",
                          maia_only ? "Maia-only" : "Lichess-backed");
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
        config = tree_config_default();
        config.play_as_white = play_as_white;
        config.build_mode = build_mode;
        tree_config_set_color_defaults(&config);
        config.min_probability = min_probability;
        config.max_depth = max_depth;
        config.engine_pool = engine_pool;
        config.db = db;
        config.lichess_eval_db = eval_db;
        config.chessdb_eval_db = chessdb_eval_db;
        config.chessdb_api = chessdb_api;
#ifdef HAS_CDBDIRECT
        config.cdbdirect = cdbdirect;
        config.cdbdirect_read_ahead = cdbdirect_read_ahead;
        config.batch_eval_lookups = batch_eval_lookups;
#endif
        config.ext_eval_subtree_skip = ext_eval_subtree_skip;
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

        config.maia_only = maia_only;
        if (maia) {
            config.maia = maia;
            config.maia_elo = maia_elo;
            config.maia_min_prob = maia_min_prob;
        }

        /* Frontier discipline */
        if (best_first_arg >= 0) config.best_first = best_first_arg != 0;
        if (alt_discount_arg >= 0.0) config.our_alt_discount = alt_discount_arg;
        if (maia_prior_arg >= 0.0) config.maia_prior_games = maia_prior_arg;
        if (cover_min_prob_arg >= 0.0) config.cover_min_prob = cover_min_prob_arg;
        if (setup_moves_arg)
            snprintf(config.setup_moves, sizeof(config.setup_moves), "%s",
                     setup_moves_arg);
        if (setup_tolerance_arg >= 0)
            config.setup_tolerance_cp = setup_tolerance_arg;

        /* Only run Maia at our-move nodes for novelty scoring if we're
         * actually going to use it.  With novelty_weight == 0 and no
         * trap-hunting, `maia_frequency` would be written and never
         * read — one ONNX inference per our-move node wasted. */
        int planned_novelty = novelty_weight_arg >= 0 ? novelty_weight_arg : 0;
        config.populate_maia_frequency = (planned_novelty > 0) || find_traps
                                        || find_traps_in_repertoire;

        config.progress_callback = progress_callback;  /* Always show progress */

        {
            int root_multipv = config.our_multipv < 10 ? 10 : config.our_multipv;
            if (root_multipv == config.our_multipv) {
                printf("  Our moves:  MultiPV %d, %dcp loss max\n",
                       config.our_multipv, config.max_eval_loss_cp);
            } else {
                printf("  Our moves:  root MultiPV %d, others %d, %dcp loss max\n",
                       root_multipv, config.our_multipv, config.max_eval_loss_cp);
            }
        }
        printf("  Opponent:   max %d children, mass target %.0f%%\n",
               config.opp_max_children,
               config.opp_mass_target * 100.0);
        printf("  Eval window: [%+d, %+d] cp%s\n",
               config.min_eval_cp, config.max_eval_cp,
               relative_eval ? " (relative to root)" : " (absolute)");

        memset(&build_stats, 0, sizeof(build_stats));
        config.stats = &build_stats;

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

        clock_gettime(CLOCK_MONOTONIC, &build_start);

        nodes_before = tree->total_nodes;
        success = tree_build(tree, start_fen, &config, explorer);

        clock_gettime(CLOCK_MONOTONIC, &build_end);
        build_time = (build_end.tv_sec - build_start.tv_sec) +
                     (build_end.tv_nsec - build_start.tv_nsec) / 1e9;

        progress_line_clear();

        if (!success && !g_interrupted) {
            fprintf(stderr, "Error: Tree building failed\n");
            tree_destroy(tree);
            lichess_explorer_destroy(explorer);
            if (engine_pool) engine_pool_destroy(engine_pool);
            if (maia) maia_destroy(maia);
            rdb_close(db);
            return 1;
        }
        } /* end standard build path */

        size_t new_nodes = tree->total_nodes - nodes_before;

        tree->build_time_seconds = build_time;
        tree->nodes_per_minute = (build_time > 0)
            ? tree->total_nodes / (build_time / 60.0) : 0;
        tree->branching_factor = (tree->max_depth_reached > 0)
            ? pow((double)tree->total_nodes, 1.0 / tree->max_depth_reached) : 1.0;
        tree->build_threads = num_threads;
        tree->build_eval_depth = eval_depth;

        if (!built_from_db && nodes_before > 1)
            printf("  Resumed: %zu new nodes (total %zu) in %.1fs (max depth %d)\n",
                   new_nodes, tree->total_nodes, build_time,
                   tree->max_depth_reached);

        /* Post-build: remove nodes where eval is too bad for us */
        size_t pruned = tree_prune_eval_too_low(tree);
        if (pruned > 0)
            printf("  Pruned %zu nodes (eval below %+dcp)\n",
                   pruned, config.min_eval_cp);

        if (!built_from_db) {
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
            int lichess_db_total = build_stats.lichess_eval_db_hits
                                 + build_stats.lichess_eval_db_misses
                                 + build_stats.lichess_eval_db_shallow;
            if (eval_db || lichess_db_total > 0) {
                printf("    Lichess DB:     %d/%d hits",
                       build_stats.lichess_eval_db_hits, lichess_db_total);
                if (lichess_db_total > 0)
                    printf(" (%d%%)",
                           build_stats.lichess_eval_db_hits * 100 / lichess_db_total);
                if (build_stats.lichess_eval_db_shallow > 0)
                    printf(" | %d shallow (depth < %d)",
                           build_stats.lichess_eval_db_shallow, eval_depth);
                printf("\n");
            }
            {
                int cdb_total = build_stats.chessdb_local_hits
                              + build_stats.chessdb_local_misses
                              + build_stats.chessdb_local_shallow;
                if (chessdb_eval_db || cdb_total > 0) {
                    printf("    ChessDB local:  %d/%d hits",
                           build_stats.chessdb_local_hits, cdb_total);
                    if (cdb_total > 0)
                        printf(" (%d%%)",
                               build_stats.chessdb_local_hits * 100 / cdb_total);
                    if (build_stats.chessdb_local_shallow > 0)
                        printf(" | %d shallow", build_stats.chessdb_local_shallow);
                    printf("\n");
                }
            }
#ifdef HAS_CDBDIRECT
            {
                int cd_total = build_stats.cdbdirect_hits
                             + build_stats.cdbdirect_misses
                             + build_stats.cdbdirect_shallow;
                if (cdbdirect || cd_total > 0) {
                    printf("    cdbdirect:      %d/%d hits",
                           build_stats.cdbdirect_hits, cd_total);
                    if (cd_total > 0)
                        printf(" (%d%%)",
                               build_stats.cdbdirect_hits * 100 / cd_total);
                    if (build_stats.cdbdirect_shallow > 0)
                        printf(" | %d shallow", build_stats.cdbdirect_shallow);
                    printf("\n");
                }
            }
#endif
            if (chessdb_api) {
                int api_total = build_stats.chessdb_api_hits
                              + build_stats.chessdb_api_misses;
                printf("    ChessDB API:    %d hits", build_stats.chessdb_api_hits);
                if (api_total > 0)
                    printf(" / %d queries", api_total);
                if (build_stats.chessdb_api_quota_exhausted > 0)
                    printf(" | quota exhausted %d times",
                           build_stats.chessdb_api_quota_exhausted);
                printf(" (used %d today)\n", chessdb_api_quota_used(chessdb_api));
            }
            if (build_stats.ext_eval_skipped > 0)
                printf("    Ext eval skip:  %d nodes (off-book subtree heuristic)\n",
                       build_stats.ext_eval_skipped);
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
        } /* !built_from_db timing breakdown */

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
    /* Eval window: tree_build() converts relative thresholds to absolute
     * in tree->config; generate_repertoire() applies the root offset once
     * when relative_eval is true.  Use the original relative window here,
     * not the already-adjusted tree->config values. */
    if (relative_eval) {
        TreeConfig color_defaults = tree_config_default();
        color_defaults.play_as_white = play_as_white;
        tree_config_set_color_defaults(&color_defaults);
        rep_config.min_eval_cp = (min_eval_arg != -99999)
                                 ? min_eval_arg : color_defaults.min_eval_cp;
        rep_config.max_eval_cp = (max_eval_arg != -99999)
                                 ? max_eval_arg : color_defaults.max_eval_cp;
    } else {
        rep_config.min_eval_cp = tree->config.min_eval_cp;
        rep_config.max_eval_cp = tree->config.max_eval_cp;
        if (min_eval_arg != -99999) rep_config.min_eval_cp = min_eval_arg;
        if (max_eval_arg != -99999) rep_config.max_eval_cp = max_eval_arg;
    }
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
    rep_config.verbose_search = verbose;
    if (novelty_weight_arg >= 0) rep_config.novelty_weight = novelty_weight_arg;
    if (leaf_confidence_arg >= 0.0) rep_config.leaf_confidence = leaf_confidence_arg;
    if (max_eval_loss_arg >= 0) rep_config.max_eval_loss_cp = max_eval_loss_arg;
    if (opp_max_children_arg >= 0) rep_config.max_candidates_per_position = opp_max_children_arg;
    rep_config.relative_eval = relative_eval;
    if (cover_min_prob_arg >= 0.0)
        rep_config.cover_min_prob = cover_min_prob_arg;
    else if (tree->config.cover_min_prob > 0.0)
        rep_config.cover_min_prob = tree->config.cover_min_prob;
    /* else: keep repertoire_config_default() (freqmap trees don't fill
     * tree->config) */
    if (setup_moves_arg)
        snprintf(rep_config.setup_moves, sizeof(rep_config.setup_moves),
                 "%s", setup_moves_arg);
    else
        snprintf(rep_config.setup_moves, sizeof(rep_config.setup_moves),
                 "%s", tree->config.setup_moves);
    if (setup_tolerance_arg >= 0)
        rep_config.setup_tolerance_cp = setup_tolerance_arg;
    if (repertoire_name)
        strncpy(rep_config.name, repertoire_name, sizeof(rep_config.name) - 1);

    result = generate_repertoire(
        tree, db, engine_pool, &rep_config,
        verbose ? pipeline_progress : NULL
    );

    if (verbose) progress_line_clear();

    /* Final verification: deep re-check of every selected move (opt-out
     * via --no-verify).  Demotions update node evals in place, so
     * re-running generate_repertoire selects around them; the new spine
     * is then re-verified, up to 3 passes. */
    if (result && verify_arg != 0 && engine_pool && !g_interrupted) {
        int verify_depth = verify_depth_arg > 0
            ? verify_depth_arg
            : (eval_depth + 6 < 20 ? 20 : eval_depth + 6);
        printf("  Verifying repertoire at depth %d...\n", verify_depth);
        int total_demotions = 0;
        int total_evals = 0;
        for (int pass = 1; pass <= 3 && !g_interrupted; pass++) {
            int evals = 0;
            int demoted = repertoire_verify(tree, engine_pool, &rep_config,
                                            verify_depth, &evals);
            total_evals += evals;
            if (demoted < 0) {
                fprintf(stderr, "  Warning: verification unavailable\n");
                break;
            }
            if (demoted == 0) {
                printf("  Verification pass %d: all %s moves within "
                       "%dcp at depth %d (%d evals)\n",
                       pass, pass == 1 ? "selected" : "re-selected",
                       rep_config.max_eval_loss_cp, verify_depth,
                       total_evals);
                break;
            }
            total_demotions += demoted;
            printf("  Verification pass %d: %d demotion(s) — "
                   "re-selecting...\n", pass, demoted);
            repertoire_result_free(result);
            result = generate_repertoire(
                tree, db, engine_pool, &rep_config,
                verbose ? pipeline_progress : NULL
            );
            if (verbose) progress_line_clear();
            if (!result) break;
        }
        if (total_demotions > 0)
            printf("  Verification: %d move(s) demoted and replaced\n",
                   total_demotions);
    }

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
    rep_config.build_max_depth    = tree->max_depth_reached;

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

    if (!g_interrupted) {
        char last_run[32];
        format_iso_timestamp(last_run, sizeof(last_run));
        rdb_set_metadata(db, "last_run_at", last_run);
    }

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
    if (engine_pool) {
        engine_pool_destroy(engine_pool);
        g_engine_pool = NULL;
    }
    if (maia) maia_destroy(maia);
    if (tree) tree_destroy(tree);
    if (eval_db) lichess_eval_db_close(eval_db);
    if (chessdb_eval_db) chessdb_eval_db_close(chessdb_eval_db);
#ifdef HAS_CDBDIRECT
    if (cdbdirect) cdbdirect_eval_close(cdbdirect);
#endif
    if (chessdb_api) {
        chessdb_api_flush_quota(chessdb_api);
        chessdb_api_destroy(chessdb_api);
    }
    if (db) rdb_close(db);
    free(token_buf);

    return g_interrupted ? 130 : 0;
}
