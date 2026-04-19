/**
 * lichess_eval_db.c - see lichess_eval_db.h
 */

#include "lichess_eval_db.h"
#include "sqlite3.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct LichessEvalDB {
    sqlite3      *db;
    sqlite3_stmt *stmt_lookup;
};

LichessEvalDB* lichess_eval_db_open(const char *path) {
    if (!path || !path[0]) return NULL;

    sqlite3 *raw = NULL;
    int rc = sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "lichess_eval_db: cannot open %s: %s\n",
                path, sqlite3_errmsg(raw));
        if (raw) sqlite3_close(raw);
        return NULL;
    }

    /* mmap the whole DB; the OS paging layer handles the working set. */
    sqlite3_exec(raw, "PRAGMA mmap_size = 30000000000;", NULL, NULL, NULL);
    sqlite3_exec(raw, "PRAGMA query_only = 1;",          NULL, NULL, NULL);
    sqlite3_exec(raw, "PRAGMA cache_size = -8000;",      NULL, NULL, NULL);

    LichessEvalDB *h = calloc(1, sizeof(*h));
    if (!h) { sqlite3_close(raw); return NULL; }
    h->db = raw;

    const char *SQL =
        "SELECT cp, mate, depth FROM lichess_evals WHERE fen = ?;";
    if (sqlite3_prepare_v2(raw, SQL, -1, &h->stmt_lookup, NULL) != SQLITE_OK) {
        fprintf(stderr, "lichess_eval_db: prepare failed: %s\n",
                sqlite3_errmsg(raw));
        sqlite3_close(raw);
        free(h);
        return NULL;
    }

    return h;
}

void lichess_eval_db_close(LichessEvalDB *h) {
    if (!h) return;
    if (h->stmt_lookup) sqlite3_finalize(h->stmt_lookup);
    if (h->db)          sqlite3_close(h->db);
    free(h);
}

/* Truncate to first 4 space-separated fields in-place. */
static void canonicalize_fen(char *fen) {
    int spaces = 0;
    for (char *p = fen; *p; p++) {
        if (*p == ' ' && ++spaces == 4) { *p = '\0'; return; }
    }
}

bool lichess_eval_db_lookup(LichessEvalDB *h, const char *fen,
                             int *out_eval_cp, int *out_depth) {
    if (!h || !fen) return false;

    char buf[128];
    snprintf(buf, sizeof(buf), "%s", fen);
    canonicalize_fen(buf);

    sqlite3_reset(h->stmt_lookup);
    sqlite3_clear_bindings(h->stmt_lookup);
    sqlite3_bind_text(h->stmt_lookup, 1, buf, -1, SQLITE_TRANSIENT);

    int rc = sqlite3_step(h->stmt_lookup);
    if (rc != SQLITE_ROW) return false;

    int cp_val    = sqlite3_column_int(h->stmt_lookup, 0);
    int cp_null   = sqlite3_column_type(h->stmt_lookup, 0) == SQLITE_NULL;
    int mate_val  = sqlite3_column_int(h->stmt_lookup, 1);
    int mate_null = sqlite3_column_type(h->stmt_lookup, 1) == SQLITE_NULL;
    int depth     = sqlite3_column_int(h->stmt_lookup, 2);

    int eval_cp;
    if (!mate_null) {
        /* Match engine_pool's mate-to-cp mapping. */
        eval_cp = mate_val > 0 ? (10000 - mate_val) : (-10000 - mate_val);
    } else if (!cp_null) {
        eval_cp = cp_val;
    } else {
        return false;  /* row present but no score — shouldn't happen */
    }

    if (out_eval_cp) *out_eval_cp = eval_cp;
    if (out_depth)   *out_depth   = depth;
    return true;
}

long lichess_eval_db_count(LichessEvalDB *h) {
    if (!h || !h->db) return -1;
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(h->db, "SELECT COUNT(*) FROM lichess_evals;",
                           -1, &s, NULL) != SQLITE_OK)
        return -1;
    long n = -1;
    if (sqlite3_step(s) == SQLITE_ROW)
        n = (long)sqlite3_column_int64(s, 0);
    sqlite3_finalize(s);
    return n;
}
