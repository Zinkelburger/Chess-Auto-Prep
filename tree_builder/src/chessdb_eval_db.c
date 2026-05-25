/**
 * chessdb_eval_db.c - see chessdb_eval_db.h
 */

#include "chessdb_eval_db.h"
#include "sqlite3.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct ChessDBEvalDB {
    sqlite3      *db;
    sqlite3_stmt *stmt_lookup;
};

static void chessdb_source_lookup(void *ctx, const char *fen, int min_depth,
                                  EvalLookupResult *out) {
    ChessDBEvalDB *h = (ChessDBEvalDB *)ctx;
    eval_lookup_result_clear(out);
    if (!h || !fen) return;

    char buf[128];
    snprintf(buf, sizeof(buf), "%s", fen);
    eval_canonicalize_fen(buf);

    sqlite3_reset(h->stmt_lookup);
    sqlite3_clear_bindings(h->stmt_lookup);
    sqlite3_bind_text(h->stmt_lookup, 1, buf, -1, SQLITE_TRANSIENT);

    int rc = sqlite3_step(h->stmt_lookup);
    if (rc != SQLITE_ROW) {
        out->hard_miss = true;
        return;
    }

    int cp_val    = sqlite3_column_int(h->stmt_lookup, 0);
    int cp_null   = sqlite3_column_type(h->stmt_lookup, 0) == SQLITE_NULL;
    int mate_val  = sqlite3_column_int(h->stmt_lookup, 1);
    int mate_null = sqlite3_column_type(h->stmt_lookup, 1) == SQLITE_NULL;
    int depth     = sqlite3_column_int(h->stmt_lookup, 2);

    out->depth = depth;
    if (!eval_map_sqlite_score(cp_val, cp_null, mate_val, mate_null,
                               &out->eval_cp, &out->mate)) {
        out->hard_miss = true;
        return;
    }

    out->found = true;
    if (depth < min_depth)
        out->shallow = true;
}

/* Non-owning: tree/main keep the ChessDBEvalDB handle. */
static void chessdb_source_close(void *ctx) {
    (void)ctx;
}

ChessDBEvalDB *chessdb_eval_db_open(const char *path) {
    if (!path || !path[0]) return NULL;

    sqlite3 *raw = NULL;
    int rc = sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "chessdb_eval_db: cannot open %s: %s\n",
                path, sqlite3_errmsg(raw));
        if (raw) sqlite3_close(raw);
        return NULL;
    }

    sqlite3_exec(raw, "PRAGMA mmap_size = 30000000000;", NULL, NULL, NULL);
    sqlite3_exec(raw, "PRAGMA query_only = 1;",          NULL, NULL, NULL);
    sqlite3_exec(raw, "PRAGMA cache_size = -8000;",      NULL, NULL, NULL);

    ChessDBEvalDB *h = calloc(1, sizeof(*h));
    if (!h) { sqlite3_close(raw); return NULL; }
    h->db = raw;

    const char *SQL =
        "SELECT cp, mate, depth FROM chessdb_evals WHERE fen = ?;";
    if (sqlite3_prepare_v2(raw, SQL, -1, &h->stmt_lookup, NULL) != SQLITE_OK) {
        fprintf(stderr, "chessdb_eval_db: prepare failed: %s\n",
                sqlite3_errmsg(raw));
        sqlite3_close(raw);
        free(h);
        return NULL;
    }

    return h;
}

void chessdb_eval_db_close(ChessDBEvalDB *h) {
    if (!h) return;
    if (h->stmt_lookup) sqlite3_finalize(h->stmt_lookup);
    if (h->db)          sqlite3_close(h->db);
    free(h);
}

bool chessdb_eval_db_lookup(ChessDBEvalDB *h, const char *fen,
                            int *out_eval_cp, int *out_depth) {
    EvalLookupResult r;
    chessdb_eval_db_lookup_result(h, fen, 0, &r);
    if (!r.found) return false;
    if (out_eval_cp) *out_eval_cp = r.eval_cp;
    if (out_depth)   *out_depth   = r.depth;
    return true;
}

void chessdb_eval_db_lookup_result(ChessDBEvalDB *db, const char *fen,
                                   int min_depth, EvalLookupResult *out) {
    chessdb_source_lookup(db, fen, min_depth, out);
}

long chessdb_eval_db_count(ChessDBEvalDB *h) {
    if (!h || !h->db) return -1;
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(h->db, "SELECT COUNT(*) FROM chessdb_evals;",
                           -1, &s, NULL) != SQLITE_OK)
        return -1;
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW)
        n = (long)sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}

EvalSource *chessdb_eval_db_as_source(ChessDBEvalDB *db) {
    if (!db) return NULL;
    EvalSource *src = calloc(1, sizeof(*src));
    if (!src) return NULL;
    src->ctx = db;
    src->lookup = chessdb_source_lookup;
    src->close_fn = chessdb_source_close;
    return src;
}
