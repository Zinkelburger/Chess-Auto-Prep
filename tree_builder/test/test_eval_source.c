/**
 * test_eval_source.c - Unit tests for EvalSource / eval chain / ChessDB backends.
 *
 * Build: make test-eval-source
 * Run:   ./bin/test_eval_source
 */

#include "eval_source.h"
#include "eval_chain.h"
#include "chessdb_eval_db.h"
#include "chessdb_api.h"
#include "cdbdirect_eval.h"
#include "lichess_eval_db.h"
#include "node.h"
#include "tree.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int tests_run = 0;
static int tests_failed = 0;

#define ASSERT(msg, cond) do { \
    tests_run++; \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
        tests_failed++; \
    } else { \
        printf("  ok: %s\n", msg); \
    } \
} while (0)

static const char *FIXTURE =
    "test/fixtures/tiny_chessdb.db";

/* ---- Mock EvalSource ---- */

typedef struct {
    const char *fen;
    int eval_cp;
    int depth;
    bool shallow;
    bool hard_miss;
} MockRow;

typedef struct {
    const MockRow *rows;
    size_t count;
} MockCtx;

static void mock_lookup(void *ctx, const char *fen, int min_depth,
                        EvalLookupResult *out) {
    MockCtx *m = (MockCtx *)ctx;
    eval_lookup_result_clear(out);
    char key[128];
    snprintf(key, sizeof(key), "%s", fen);
    eval_canonicalize_fen(key);
    for (size_t i = 0; i < m->count; i++) {
        char row_key[128];
        snprintf(row_key, sizeof(row_key), "%s", m->rows[i].fen);
        eval_canonicalize_fen(row_key);
        if (strcmp(row_key, key) != 0) continue;
        if (m->rows[i].hard_miss) {
            out->hard_miss = true;
            return;
        }
        out->found = true;
        out->eval_cp = m->rows[i].eval_cp;
        out->depth = m->rows[i].depth;
        if (m->rows[i].shallow || out->depth < min_depth)
            out->shallow = true;
        return;
    }
    out->hard_miss = true;
}

static void mock_close(void *ctx) { (void)ctx; }

static void test_mock_eval_source(void) {
    printf("\n== Mock EvalSource ==\n");
    MockRow rows[] = {
        {"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 15, 25, false, false},
    };
    MockCtx ctx = { rows, 1 };
    EvalSource src = { &ctx, mock_lookup, mock_close };

    EvalLookupResult r;
    src.lookup(src.ctx, rows[0].fen, 20, &r);
    ASSERT("mock hit", r.found && !r.shallow && r.eval_cp == 15);

    src.lookup(src.ctx, "missing fen w KQkq - 0 1", 20, &r);
    ASSERT("mock hard miss", r.hard_miss && !r.found);
}

static void test_chessdb_sqlite(void) {
    printf("\n== ChessDB SQLite fixture ==\n");
    ChessDBEvalDB *db = chessdb_eval_db_open(FIXTURE);
    ASSERT("fixture opens", db != NULL);

    EvalLookupResult r;
    chessdb_eval_db_lookup_result(db,
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 20, &r);
    ASSERT("startpos hit", r.found && !r.shallow && r.eval_cp == 15);

    chessdb_eval_db_lookup_result(db,
        "rnbqkbnr/pppppppp/8/8/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 0 2", 20, &r);
    ASSERT("absent FEN hard miss", r.hard_miss && !r.found);

    chessdb_eval_db_lookup_result(db,
        "rnbqkb1r/pppppppp/5n2/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2", 20, &r);
    ASSERT("shallow row flagged", r.found && r.shallow && !r.hard_miss);

    chessdb_eval_db_lookup_result(db,
        "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", 20, &r);
    ASSERT("mate mapped", r.found && r.eval_cp == (10000 - 3));

    /* EP canonicalization: DB key uses 4-field with e3 */
    chessdb_eval_db_lookup_result(db,
        "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", 20, &r);
    ASSERT("EP canonical hit (1.e4)", r.found && r.eval_cp == 25);

    chessdb_eval_db_lookup_result(db,
        "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1", 20, &r);
    ASSERT("1.d4 hit", r.found && r.eval_cp == 18);

    chessdb_eval_db_lookup_result(db,
        "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 1", 20, &r);
    ASSERT("Sicilian hit", r.found && r.eval_cp == 30);

    chessdb_eval_db_lookup_result(db,
        "rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", 20, &r);
    ASSERT("deep sideline hit", r.found && r.eval_cp == -10);

    chessdb_eval_db_close(db);
}

static void test_skip_flag_inheritance(void) {
    printf("\n== Skip flag inheritance ==\n");
    ChessDBEvalDB *db = chessdb_eval_db_open(FIXTURE);
    BuildStats stats;
    memset(&stats, 0, sizeof(stats));

    EvalChainContext ctx = {
        .chessdb_eval_db = db,
        .lichess_eval_db = NULL,
        .chessdb_api = NULL,
        .eval_depth = 20,
        .ext_eval_subtree_skip = true,
        .stats = &stats,
    };

    TreeNode *parent = node_create(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        NULL, NULL, NULL);
    TreeNode *child = node_create(
        "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
        "e4", "e2e4", parent);
    child->skip_ext_eval = parent->skip_ext_eval;

    int cp = 0, depth = 0;
    bool hit = eval_chain_try_external(child, &ctx, &cp, &depth, NULL);
    ASSERT("child on-book hit", hit);

    TreeNode *offbook = node_create(
        "8/8/8/8/8/8/8/8 w - - 0 1", "x", "a1a2", parent);
    offbook->skip_ext_eval = parent->skip_ext_eval;
    hit = eval_chain_try_external(offbook, &ctx, &cp, &depth, NULL);
    ASSERT("off-book miss", !hit);
    ASSERT("skip flag set on miss node", offbook->skip_ext_eval);

    TreeNode *grandchild = node_create(
        "8/8/8/8/8/8/8/4K3 b - - 0 1", "y", "a2a3", offbook);
    grandchild->skip_ext_eval = offbook->skip_ext_eval;
    hit = eval_chain_try_external(grandchild, &ctx, &cp, &depth, NULL);
    ASSERT("grandchild skips external", !hit);
    ASSERT("ext_eval_skipped counted", stats.ext_eval_skipped >= 1);

    node_destroy(parent);
    chessdb_eval_db_close(db);
}

static size_t mock_http(void *ctx, const char *url, char *body, size_t cap,
                        long *out_code) {
    (void)ctx;
    (void)url;
    if (out_code) *out_code = 200;
    snprintf(body, cap, "eval:42");
    return strlen(body);
}

static size_t mock_http_unknown(void *ctx, const char *url, char *body,
                                size_t cap, long *out_code) {
    (void)ctx;
    (void)url;
    if (out_code) *out_code = 200;
    snprintf(body, cap, "unknown");
    return strlen(body);
}

static void test_cdbdirect_parse(void) {
    printf("\n== cdbdirect response parsing ==\n");
    int cp = 0, depth = 0;
    char move[8];

    ASSERT("verbose format",
           cdbdirect_parse_response(
               "move:e2e4,score:30,rank:0,note:,winrate:0.515|move:d2d4,score:25,rank:1",
               &cp, &depth, move, sizeof(move))
           && cp == 30 && strcmp(move, "e2e4") == 0);

    ASSERT("simple format",
           cdbdirect_parse_response("e2e4:30|d2d4:25", &cp, &depth, move, sizeof(move))
           && cp == 30);

    ASSERT("eval only",
           cdbdirect_parse_response("eval:42", &cp, &depth, NULL, 0) && cp == 42);

    ASSERT("NULL miss", !cdbdirect_parse_response(NULL, &cp, &depth, NULL, 0));
    ASSERT("empty miss", !cdbdirect_parse_response("", &cp, &depth, NULL, 0));
    ASSERT("unknown miss",
           !cdbdirect_parse_response("unknown", &cp, &depth, NULL, 0));

    ASSERT("validate mock dir",
           cdbdirect_validate_data_dir("test/fixtures/cdbdirect_mock"));
    ASSERT("validate missing dir",
           !cdbdirect_validate_data_dir("test/fixtures/no_such_dir"));
}

#ifdef HAS_CDBDIRECT
static const char *CDB_MOCK_PATH = "test/fixtures/cdbdirect_mock";

static void test_cdbdirect_mock_chain(void) {
    printf("\n== cdbdirect mock EvalSource ==\n");
    CdbDirectEval *cdb = cdbdirect_eval_open(CDB_MOCK_PATH, false);
    ASSERT("mock opens", cdb != NULL);

    EvalLookupResult r;
    cdbdirect_eval_lookup_result(cdb,
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 20, &r);
    ASSERT("startpos hit", r.found && !r.shallow && r.eval_cp == 30);

    cdbdirect_eval_lookup_result(cdb,
        "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", 20, &r);
    ASSERT("1.e4 hit", r.found && r.eval_cp == 25);

    cdbdirect_eval_lookup_result(cdb,
        "8/8/8/8/8/8/8/8 w - - 0 1", 20, &r);
    ASSERT("off-book hard miss", r.hard_miss && !r.found);

    BuildStats stats;
    memset(&stats, 0, sizeof(stats));
    EvalChainContext ctx = {
        .cdbdirect = cdb,
        .chessdb_eval_db = NULL,
        .lichess_eval_db = NULL,
        .chessdb_api = NULL,
        .eval_depth = 20,
        .ext_eval_subtree_skip = true,
        .stats = &stats,
    };

    TreeNode *node = node_create(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        NULL, NULL, NULL);
    int cp = 0;
    const char *src = NULL;
    ASSERT("chain cdbdirect first",
           eval_chain_try_external(node, &ctx, &cp, NULL, &src)
           && cp == 30 && src && strcmp(src, "cdbdirect") == 0);

    TreeNode *offbook = node_create(
        "8/8/8/8/8/8/8/8 w - - 0 1", "x", "a1a2", node);
    offbook->skip_ext_eval = node->skip_ext_eval;
    bool hit = eval_chain_try_external(offbook, &ctx, &cp, NULL, NULL);
    ASSERT("off-book miss sets skip", !hit && offbook->skip_ext_eval);

    node_destroy(node);
    cdbdirect_eval_close(cdb);
}

static void test_cdbdirect_prefetch(void) {
    printf("\n== cdbdirect batch prefetch ==\n");
    CdbDirectEval *cdb = cdbdirect_eval_open(CDB_MOCK_PATH, false);
    ASSERT("prefetch opens", cdb != NULL);

    const char *fens[] = {
        "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1",
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 1",
    };
    cdbdirect_eval_prefetch(cdb, fens, 3);

    EvalLookupResult r;
    cdbdirect_eval_lookup_result(cdb, fens[0], 20, &r);
    ASSERT("prefetched hit", r.found && r.eval_cp == 18);

    cdbdirect_eval_close(cdb);
}
#endif /* HAS_CDBDIRECT */

static void test_chessdb_api_mock(void) {
    printf("\n== ChessDB API (mock HTTP) ==\n");
    ChessDBAPIConfig cfg = chessdb_api_config_default();
    cfg.enabled = true;
    cfg.daily_quota = 3;
    ChessDBAPI *api = chessdb_api_create(&cfg);
    chessdb_api_set_http_hook(api, mock_http, NULL);

    int cp = 0, depth = 0;
    ASSERT("api mock hit", chessdb_api_query_score(api,
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        &cp, &depth) && cp == 42);
    ASSERT("quota used 1", chessdb_api_quota_used(api) == 1);

    chessdb_api_set_http_hook(api, mock_http_unknown, NULL);
    ASSERT("api unknown miss",
           !chessdb_api_query_score(api,
               "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
               &cp, &depth));
    ASSERT("quota unchanged on miss", chessdb_api_quota_used(api) == 1);

    chessdb_api_destroy(api);

    int mate_cp = 0, mate_raw = 0;
    ASSERT("mate score map",
           chessdb_map_api_score(29996, &mate_cp, &mate_raw)
           && mate_cp == 9996 && mate_raw == 4);
}

static void test_eval_chain_api_phase(void) {
    printf("\n== Eval chain API phase ==\n");
    ChessDBAPIConfig cfg = chessdb_api_config_default();
    cfg.enabled = true;
    cfg.daily_quota = 10;
    ChessDBAPI *api = chessdb_api_create(&cfg);
    chessdb_api_set_http_hook(api, mock_http, NULL);

    BuildStats stats;
    memset(&stats, 0, sizeof(stats));
    EvalChainContext ctx = {
        .chessdb_eval_db = NULL,
        .lichess_eval_db = NULL,
        .chessdb_api = api,
        .eval_depth = 20,
        .ext_eval_subtree_skip = true,
        .stats = &stats,
    };

    TreeNode *node = node_create(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        NULL, NULL, NULL);
    int cp = 0;
    const char *src = NULL;
    ASSERT("chain api hit",
           eval_chain_try_external(node, &ctx, &cp, NULL, &src)
           && cp == 42 && src && strcmp(src, "chessdb_api") == 0);

    node_destroy(node);
    chessdb_api_destroy(api);
}

int main(void) {
    printf("=== test_eval_source ===\n");
    test_mock_eval_source();
    test_cdbdirect_parse();
    test_chessdb_sqlite();
    test_skip_flag_inheritance();
    test_chessdb_api_mock();
    test_eval_chain_api_phase();
#ifdef HAS_CDBDIRECT
    test_cdbdirect_mock_chain();
    test_cdbdirect_prefetch();
#endif

    printf("\n%d tests, %d failed\n", tests_run, tests_failed);
    return tests_failed ? 1 : 0;
}
