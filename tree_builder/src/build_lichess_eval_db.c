/**
 * build_lichess_eval_db.c
 *
 * Standalone ETL: stream the Lichess eval JSONL dump into a slim SQLite DB
 * that the tree builder can use as a fast eval source for opponent nodes.
 *
 * Schema:
 *   lichess_evals(fen TEXT PRIMARY KEY, move TEXT, cp INT, mate INT, depth INT)
 *
 * For each position we keep only the deepest eval's PV1 — the PVs/multiPV
 * data we drop is ~95% of line size and not useful for single-PV lookups.
 *
 * FENs are canonicalized to 4 fields (pieces, side-to-move, castling,
 * en passant) — same form Lichess uses, and the form lookups must use.
 *
 * Usage:
 *   build_lichess_eval_db <input.jsonl | -> <output.db>
 *
 * Examples:
 *   build_lichess_eval_db lichess_db_eval.jsonl lichess_evals.db
 *   zstd -dc lichess_db_eval.jsonl.zst | build_lichess_eval_db - lichess_evals.db
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>

#include "sqlite3.h"
#include "cJSON.h"

static const char *SCHEMA =
    "CREATE TABLE IF NOT EXISTS lichess_evals ("
    "  fen   TEXT PRIMARY KEY,"
    "  move  TEXT,"
    "  cp    INTEGER,"
    "  mate  INTEGER,"
    "  depth INTEGER NOT NULL"
    ") WITHOUT ROWID;";

/* Aggressive load-time pragmas — rebuilt in one shot, never partial. */
static const char *PRAGMAS_LOAD =
    "PRAGMA journal_mode = OFF;"
    "PRAGMA synchronous = OFF;"
    "PRAGMA temp_store = MEMORY;"
    "PRAGMA cache_size = -200000;"
    "PRAGMA locking_mode = EXCLUSIVE;";

/* Final-pass pragmas to make the shipped DB small and read-friendly. */
static const char *PRAGMAS_FINALIZE =
    "PRAGMA journal_mode = DELETE;"
    "PRAGMA synchronous = NORMAL;";

static void canonicalize_fen(char *fen) {
    int spaces = 0;
    for (char *p = fen; *p; p++) {
        if (*p == ' ' && ++spaces == 4) { *p = '\0'; return; }
    }
}

static void first_uci_move(const char *line, char *out, size_t cap) {
    size_t i = 0;
    while (line[i] && line[i] != ' ' && i + 1 < cap) {
        out[i] = line[i];
        i++;
    }
    out[i] = '\0';
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr,
            "Usage: %s <input.jsonl | -> <output.db>\n"
            "\n"
            "Streams Lichess eval JSONL into a slim SQLite database.\n"
            "Use '-' to read from stdin, e.g.\n"
            "  zstd -dc lichess_db_eval.jsonl.zst | %s - lichess_evals.db\n",
            argv[0], argv[0]);
        return 1;
    }

    FILE *in = (strcmp(argv[1], "-") == 0) ? stdin : fopen(argv[1], "r");
    if (!in) {
        fprintf(stderr, "Cannot open input: %s\n", argv[1]);
        return 1;
    }

    sqlite3 *db = NULL;
    if (sqlite3_open(argv[2], &db) != SQLITE_OK) {
        fprintf(stderr, "Cannot open DB %s: %s\n", argv[2], sqlite3_errmsg(db));
        return 1;
    }

    char *err = NULL;
    if (sqlite3_exec(db, PRAGMAS_LOAD, NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "pragma load: %s\n", err);
        sqlite3_free(err);
        return 1;
    }
    if (sqlite3_exec(db, SCHEMA, NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "schema: %s\n", err);
        sqlite3_free(err);
        return 1;
    }

    sqlite3_stmt *stmt;
    const char *SQL =
        "INSERT OR REPLACE INTO lichess_evals (fen, move, cp, mate, depth) "
        "VALUES (?, ?, ?, ?, ?);";
    if (sqlite3_prepare_v2(db, SQL, -1, &stmt, NULL) != SQLITE_OK) {
        fprintf(stderr, "prepare: %s\n", sqlite3_errmsg(db));
        return 1;
    }

    sqlite3_exec(db, "BEGIN;", NULL, NULL, NULL);

    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    long records = 0, inserted = 0, skipped = 0;
    const time_t t0 = time(NULL);
    time_t tlast = t0;
    long records_last = 0;
    const long COMMIT_EVERY = 500000;

    while ((len = getline(&line, &cap, in)) != -1) {
        records++;
        if (len <= 2) { skipped++; goto maybe_commit; }

        cJSON *root = cJSON_Parse(line);
        if (!root) { skipped++; goto maybe_commit; }

        cJSON *fen_node = cJSON_GetObjectItem(root, "fen");
        cJSON *evals    = cJSON_GetObjectItem(root, "evals");
        if (!cJSON_IsString(fen_node) || !cJSON_IsArray(evals) ||
            cJSON_GetArraySize(evals) == 0) {
            skipped++; cJSON_Delete(root); goto maybe_commit;
        }

        cJSON *best = NULL;
        int best_depth = -1;
        cJSON *e;
        cJSON_ArrayForEach(e, evals) {
            cJSON *d = cJSON_GetObjectItem(e, "depth");
            if (cJSON_IsNumber(d) && d->valueint > best_depth) {
                best = e;
                best_depth = d->valueint;
            }
        }
        if (!best) { skipped++; cJSON_Delete(root); goto maybe_commit; }

        cJSON *pvs = cJSON_GetObjectItem(best, "pvs");
        if (!cJSON_IsArray(pvs) || cJSON_GetArraySize(pvs) == 0) {
            skipped++; cJSON_Delete(root); goto maybe_commit;
        }
        cJSON *pv0       = cJSON_GetArrayItem(pvs, 0);
        cJSON *cp_node   = cJSON_GetObjectItem(pv0, "cp");
        cJSON *mate_node = cJSON_GetObjectItem(pv0, "mate");
        cJSON *line_node = cJSON_GetObjectItem(pv0, "line");

        char fen_buf[128];
        snprintf(fen_buf, sizeof(fen_buf), "%s", fen_node->valuestring);
        canonicalize_fen(fen_buf);

        char move_buf[16] = "";
        if (cJSON_IsString(line_node))
            first_uci_move(line_node->valuestring, move_buf, sizeof(move_buf));

        sqlite3_bind_text(stmt, 1, fen_buf, -1, SQLITE_TRANSIENT);
        if (move_buf[0]) sqlite3_bind_text(stmt, 2, move_buf, -1, SQLITE_TRANSIENT);
        else             sqlite3_bind_null(stmt, 2);
        if (cJSON_IsNumber(cp_node))   sqlite3_bind_int(stmt, 3, cp_node->valueint);
        else                           sqlite3_bind_null(stmt, 3);
        if (cJSON_IsNumber(mate_node)) sqlite3_bind_int(stmt, 4, mate_node->valueint);
        else                           sqlite3_bind_null(stmt, 4);
        sqlite3_bind_int(stmt, 5, best_depth);

        if (sqlite3_step(stmt) == SQLITE_DONE) inserted++;
        else skipped++;
        sqlite3_reset(stmt);

        cJSON_Delete(root);

    maybe_commit:
        if (records % COMMIT_EVERY == 0) {
            sqlite3_exec(db, "COMMIT; BEGIN;", NULL, NULL, NULL);
            time_t now = time(NULL);
            long dt = (long)(now - tlast);
            long drec = records - records_last;
            double rate = dt > 0 ? (double)drec / (double)dt : 0.0;
            fprintf(stderr,
                "[%6lds] records=%8ld inserted=%8ld skipped=%ld  rate=%.0fk/s\n",
                (long)(now - t0), records, inserted, skipped, rate / 1000.0);
            tlast = now;
            records_last = records;
        }
    }

    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_finalize(stmt);

    fprintf(stderr, "\nFinalizing DB…\n");
    if (sqlite3_exec(db, PRAGMAS_FINALIZE, NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "pragma finalize: %s\n", err);
        sqlite3_free(err);
    }
    sqlite3_close(db);

    free(line);
    if (in != stdin) fclose(in);

    time_t t1 = time(NULL);
    fprintf(stderr,
        "\nDone.\n"
        "  records  : %ld\n"
        "  inserted : %ld\n"
        "  skipped  : %ld\n"
        "  elapsed  : %lds\n",
        records, inserted, skipped, (long)(t1 - t0));
    return 0;
}
