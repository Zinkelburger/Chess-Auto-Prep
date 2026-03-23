/**
 * database.c - SQLite3 Persistent Storage Implementation
 * 
 * Uses WAL mode for concurrent read/write performance.
 * All FENs are stored normalized (without move counters) for deduplication.
 */

#include "database.h"
#include "sqlite3.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

struct RepertoireDB {
    sqlite3 *db;
    
    /* Prepared statements (for performance) */
    sqlite3_stmt *stmt_get_explorer;
    sqlite3_stmt *stmt_put_explorer;
    sqlite3_stmt *stmt_get_explorer_moves;
    sqlite3_stmt *stmt_put_explorer_move;
    sqlite3_stmt *stmt_get_eval;
    sqlite3_stmt *stmt_put_eval;
    sqlite3_stmt *stmt_get_ease;
    sqlite3_stmt *stmt_put_ease;
    sqlite3_stmt *stmt_save_rep_move;
};


/* ========== Schema ========== */

static const char *SCHEMA_SQL = 
    /* Lichess explorer cache - position level */
    "CREATE TABLE IF NOT EXISTS explorer_positions ("
    "  fen TEXT PRIMARY KEY,"
    "  total_games INTEGER DEFAULT 0,"
    "  opening_eco TEXT,"
    "  opening_name TEXT,"
    "  cached_at INTEGER"
    ");"
    
    /* Lichess explorer cache - move level */
    "CREATE TABLE IF NOT EXISTS explorer_moves ("
    "  fen TEXT NOT NULL,"
    "  uci TEXT NOT NULL,"
    "  san TEXT,"
    "  white_wins INTEGER DEFAULT 0,"
    "  black_wins INTEGER DEFAULT 0,"
    "  draws INTEGER DEFAULT 0,"
    "  probability REAL DEFAULT 0,"
    "  PRIMARY KEY (fen, uci)"
    ");"
    
    /* Engine evaluations */
    "CREATE TABLE IF NOT EXISTS evaluations ("
    "  fen TEXT PRIMARY KEY,"
    "  eval_cp INTEGER,"
    "  depth INTEGER,"
    "  bestmove TEXT,"
    "  pv TEXT,"
    "  is_mate INTEGER DEFAULT 0,"
    "  mate_in INTEGER,"
    "  evaluated_at INTEGER"
    ");"
    
    /* Ease scores */
    "CREATE TABLE IF NOT EXISTS ease_scores ("
    "  fen TEXT PRIMARY KEY,"
    "  ease REAL,"
    "  calculated_at INTEGER"
    ");"
    
    /* Repertoire move selections */
    "CREATE TABLE IF NOT EXISTS repertoire_moves ("
    "  fen TEXT NOT NULL,"
    "  move_san TEXT NOT NULL,"
    "  move_uci TEXT NOT NULL,"
    "  score REAL DEFAULT 0,"
    "  is_selected INTEGER DEFAULT 0,"
    "  created_at INTEGER,"
    "  PRIMARY KEY (fen, move_uci)"
    ");"
    
    
    /* Indexes for performance */
    "CREATE INDEX IF NOT EXISTS idx_explorer_moves_fen ON explorer_moves(fen);"
    "CREATE INDEX IF NOT EXISTS idx_repertoire_fen ON repertoire_moves(fen);"
;


/* ========== Initialization ========== */

static bool execute_sql(sqlite3 *db, const char *sql) {
    char *err_msg = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &err_msg);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "SQL error: %s\n", err_msg);
        sqlite3_free(err_msg);
        return false;
    }
    return true;
}


static bool prepare_statements(RepertoireDB *rdb) {
    sqlite3 *db = rdb->db;
    
    /* Explorer cache statements */
    sqlite3_prepare_v2(db,
        "SELECT total_games, opening_eco, opening_name FROM explorer_positions WHERE fen = ?",
        -1, &rdb->stmt_get_explorer, NULL);
    
    sqlite3_prepare_v2(db,
        "INSERT OR REPLACE INTO explorer_positions (fen, total_games, opening_eco, opening_name, cached_at) "
        "VALUES (?, ?, ?, ?, ?)",
        -1, &rdb->stmt_put_explorer, NULL);
    
    sqlite3_prepare_v2(db,
        "SELECT uci, san, white_wins, black_wins, draws, probability "
        "FROM explorer_moves WHERE fen = ? ORDER BY probability DESC",
        -1, &rdb->stmt_get_explorer_moves, NULL);
    
    sqlite3_prepare_v2(db,
        "INSERT OR REPLACE INTO explorer_moves (fen, uci, san, white_wins, black_wins, draws, probability) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        -1, &rdb->stmt_put_explorer_move, NULL);
    
    /* Evaluation statements */
    sqlite3_prepare_v2(db,
        "SELECT eval_cp, depth FROM evaluations WHERE fen = ?",
        -1, &rdb->stmt_get_eval, NULL);
    
    sqlite3_prepare_v2(db,
        "INSERT OR REPLACE INTO evaluations (fen, eval_cp, depth, evaluated_at) VALUES (?, ?, ?, ?)",
        -1, &rdb->stmt_put_eval, NULL);
    
    /* Ease statements */
    sqlite3_prepare_v2(db,
        "SELECT ease FROM ease_scores WHERE fen = ?",
        -1, &rdb->stmt_get_ease, NULL);
    
    sqlite3_prepare_v2(db,
        "INSERT OR REPLACE INTO ease_scores (fen, ease, calculated_at) VALUES (?, ?, ?)",
        -1, &rdb->stmt_put_ease, NULL);
    
    /* Repertoire statements */
    sqlite3_prepare_v2(db,
        "INSERT OR REPLACE INTO repertoire_moves (fen, move_san, move_uci, score, is_selected, created_at) "
        "VALUES (?, ?, ?, ?, 1, ?)",
        -1, &rdb->stmt_save_rep_move, NULL);
    
    return true;
}


RepertoireDB* rdb_open(const char *path) {
    if (!path) return NULL;
    
    RepertoireDB *rdb = (RepertoireDB *)calloc(1, sizeof(RepertoireDB));
    if (!rdb) return NULL;
    
    int rc = sqlite3_open(path, &rdb->db);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "Cannot open database: %s\n", sqlite3_errmsg(rdb->db));
        free(rdb);
        return NULL;
    }
    
    /* Enable WAL mode for better concurrent performance */
    execute_sql(rdb->db, "PRAGMA journal_mode=WAL;");
    execute_sql(rdb->db, "PRAGMA synchronous=NORMAL;");
    execute_sql(rdb->db, "PRAGMA cache_size=-64000;");  /* 64MB cache */
    execute_sql(rdb->db, "PRAGMA temp_store=MEMORY;");
    
    /* Create schema */
    if (!execute_sql(rdb->db, SCHEMA_SQL)) {
        sqlite3_close(rdb->db);
        free(rdb);
        return NULL;
    }
    
    /* Prepare statements */
    if (!prepare_statements(rdb)) {
        sqlite3_close(rdb->db);
        free(rdb);
        return NULL;
    }
    
    return rdb;
}


void rdb_close(RepertoireDB *db) {
    if (!db) return;
    
    /* Finalize prepared statements */
    sqlite3_finalize(db->stmt_get_explorer);
    sqlite3_finalize(db->stmt_put_explorer);
    sqlite3_finalize(db->stmt_get_explorer_moves);
    sqlite3_finalize(db->stmt_put_explorer_move);
    sqlite3_finalize(db->stmt_get_eval);
    sqlite3_finalize(db->stmt_put_eval);
    sqlite3_finalize(db->stmt_get_ease);
    sqlite3_finalize(db->stmt_put_ease);
    sqlite3_finalize(db->stmt_save_rep_move);
    
    sqlite3_close(db->db);
    free(db);
}


void rdb_begin_transaction(RepertoireDB *db) {
    if (db) execute_sql(db->db, "BEGIN TRANSACTION;");
}

void rdb_commit_transaction(RepertoireDB *db) {
    if (db) execute_sql(db->db, "COMMIT;");
}


/* ========== Lichess Explorer Cache ========== */

bool rdb_get_explorer_cache(RepertoireDB *db, const char *fen, 
                             CachedExplorerResponse *out) {
    if (!db || !fen || !out) return false;
    
    memset(out, 0, sizeof(CachedExplorerResponse));
    out->found = false;
    
    /* Get position-level data */
    sqlite3_reset(db->stmt_get_explorer);
    sqlite3_bind_text(db->stmt_get_explorer, 1, fen, -1, SQLITE_STATIC);
    
    if (sqlite3_step(db->stmt_get_explorer) != SQLITE_ROW) {
        return false;
    }
    
    out->total_games = (uint64_t)sqlite3_column_int64(db->stmt_get_explorer, 0);
    
    const char *eco = (const char *)sqlite3_column_text(db->stmt_get_explorer, 1);
    if (eco) strncpy(out->opening_eco, eco, sizeof(out->opening_eco) - 1);
    
    const char *name = (const char *)sqlite3_column_text(db->stmt_get_explorer, 2);
    if (name) strncpy(out->opening_name, name, sizeof(out->opening_name) - 1);
    
    /* Get moves */
    sqlite3_reset(db->stmt_get_explorer_moves);
    sqlite3_bind_text(db->stmt_get_explorer_moves, 1, fen, -1, SQLITE_STATIC);
    
    out->move_count = 0;
    while (sqlite3_step(db->stmt_get_explorer_moves) == SQLITE_ROW && out->move_count < 64) {
        CachedExplorerMove *m = &out->moves[out->move_count];
        
        const char *uci = (const char *)sqlite3_column_text(db->stmt_get_explorer_moves, 0);
        const char *san = (const char *)sqlite3_column_text(db->stmt_get_explorer_moves, 1);
        
        if (uci) strncpy(m->uci, uci, sizeof(m->uci) - 1);
        if (san) strncpy(m->san, san, sizeof(m->san) - 1);
        
        m->white_wins = (uint64_t)sqlite3_column_int64(db->stmt_get_explorer_moves, 2);
        m->black_wins = (uint64_t)sqlite3_column_int64(db->stmt_get_explorer_moves, 3);
        m->draws      = (uint64_t)sqlite3_column_int64(db->stmt_get_explorer_moves, 4);
        m->probability = sqlite3_column_double(db->stmt_get_explorer_moves, 5);
        
        out->move_count++;
    }
    
    out->found = true;
    return true;
}


void rdb_put_explorer_cache(RepertoireDB *db, const char *fen,
                             const CachedExplorerMove *moves, size_t move_count,
                             uint64_t total_games,
                             const char *opening_eco, const char *opening_name) {
    if (!db || !fen) return;
    
    time_t now = time(NULL);
    
    /* Insert position */
    sqlite3_reset(db->stmt_put_explorer);
    sqlite3_bind_text(db->stmt_put_explorer, 1, fen, -1, SQLITE_STATIC);
    sqlite3_bind_int64(db->stmt_put_explorer, 2, (sqlite3_int64)total_games);
    sqlite3_bind_text(db->stmt_put_explorer, 3, opening_eco ? opening_eco : "", -1, SQLITE_STATIC);
    sqlite3_bind_text(db->stmt_put_explorer, 4, opening_name ? opening_name : "", -1, SQLITE_STATIC);
    sqlite3_bind_int64(db->stmt_put_explorer, 5, (sqlite3_int64)now);
    sqlite3_step(db->stmt_put_explorer);
    
    /* Insert moves */
    for (size_t i = 0; i < move_count; i++) {
        const CachedExplorerMove *m = &moves[i];
        
        sqlite3_reset(db->stmt_put_explorer_move);
        sqlite3_bind_text(db->stmt_put_explorer_move, 1, fen, -1, SQLITE_STATIC);
        sqlite3_bind_text(db->stmt_put_explorer_move, 2, m->uci, -1, SQLITE_STATIC);
        sqlite3_bind_text(db->stmt_put_explorer_move, 3, m->san, -1, SQLITE_STATIC);
        sqlite3_bind_int64(db->stmt_put_explorer_move, 4, (sqlite3_int64)m->white_wins);
        sqlite3_bind_int64(db->stmt_put_explorer_move, 5, (sqlite3_int64)m->black_wins);
        sqlite3_bind_int64(db->stmt_put_explorer_move, 6, (sqlite3_int64)m->draws);
        sqlite3_bind_double(db->stmt_put_explorer_move, 7, m->probability);
        sqlite3_step(db->stmt_put_explorer_move);
    }
}


/* ========== Engine Evaluations ========== */

bool rdb_get_eval(RepertoireDB *db, const char *fen, int *eval_cp, int *depth) {
    if (!db || !fen) return false;
    
    sqlite3_reset(db->stmt_get_eval);
    sqlite3_bind_text(db->stmt_get_eval, 1, fen, -1, SQLITE_STATIC);
    
    if (sqlite3_step(db->stmt_get_eval) != SQLITE_ROW) {
        return false;
    }
    
    if (eval_cp) *eval_cp = sqlite3_column_int(db->stmt_get_eval, 0);
    if (depth)   *depth   = sqlite3_column_int(db->stmt_get_eval, 1);
    
    return true;
}


void rdb_put_eval(RepertoireDB *db, const char *fen, int eval_cp, int depth) {
    if (!db || !fen) return;
    
    time_t now = time(NULL);
    
    sqlite3_reset(db->stmt_put_eval);
    sqlite3_bind_text(db->stmt_put_eval, 1, fen, -1, SQLITE_STATIC);
    sqlite3_bind_int(db->stmt_put_eval, 2, eval_cp);
    sqlite3_bind_int(db->stmt_put_eval, 3, depth);
    sqlite3_bind_int64(db->stmt_put_eval, 4, (sqlite3_int64)now);
    sqlite3_step(db->stmt_put_eval);
}


/* ========== Ease Scores ========== */

bool rdb_get_ease(RepertoireDB *db, const char *fen, double *ease) {
    if (!db || !fen) return false;
    
    sqlite3_reset(db->stmt_get_ease);
    sqlite3_bind_text(db->stmt_get_ease, 1, fen, -1, SQLITE_STATIC);
    
    if (sqlite3_step(db->stmt_get_ease) != SQLITE_ROW) {
        return false;
    }
    
    if (ease) *ease = sqlite3_column_double(db->stmt_get_ease, 0);
    
    return true;
}


void rdb_put_ease(RepertoireDB *db, const char *fen, double ease) {
    if (!db || !fen) return;
    
    time_t now = time(NULL);
    
    sqlite3_reset(db->stmt_put_ease);
    sqlite3_bind_text(db->stmt_put_ease, 1, fen, -1, SQLITE_STATIC);
    sqlite3_bind_double(db->stmt_put_ease, 2, ease);
    sqlite3_bind_int64(db->stmt_put_ease, 3, (sqlite3_int64)now);
    sqlite3_step(db->stmt_put_ease);
}


/* ========== Repertoire Selections ========== */

void rdb_save_repertoire_move(RepertoireDB *db, const char *fen,
                               const char *move_san, const char *move_uci,
                               double score) {
    if (!db || !fen || !move_san || !move_uci) return;
    
    time_t now = time(NULL);
    
    sqlite3_reset(db->stmt_save_rep_move);
    sqlite3_bind_text(db->stmt_save_rep_move, 1, fen, -1, SQLITE_STATIC);
    sqlite3_bind_text(db->stmt_save_rep_move, 2, move_san, -1, SQLITE_STATIC);
    sqlite3_bind_text(db->stmt_save_rep_move, 3, move_uci, -1, SQLITE_STATIC);
    sqlite3_bind_double(db->stmt_save_rep_move, 4, score);
    sqlite3_bind_int64(db->stmt_save_rep_move, 5, (sqlite3_int64)now);
    sqlite3_step(db->stmt_save_rep_move);
}


void rdb_get_repertoire_moves(RepertoireDB *db,
                               void (*callback)(const char *fen, const char *move_san,
                                                const char *move_uci, double score,
                                                void *user_data),
                               void *user_data) {
    if (!db || !callback) return;
    
    sqlite3_stmt *stmt;
    sqlite3_prepare_v2(db->db,
        "SELECT fen, move_san, move_uci, score FROM repertoire_moves WHERE is_selected = 1 ORDER BY fen",
        -1, &stmt, NULL);
    
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *fen = (const char *)sqlite3_column_text(stmt, 0);
        const char *san = (const char *)sqlite3_column_text(stmt, 1);
        const char *uci = (const char *)sqlite3_column_text(stmt, 2);
        double score = sqlite3_column_double(stmt, 3);
        
        callback(fen, san, uci, score, user_data);
    }
    
    sqlite3_finalize(stmt);
}


/* ========== Statistics ========== */

void rdb_get_stats(RepertoireDB *db, int *explorer_cached, 
                    int *evals_cached, int *ease_cached) {
    if (!db) return;
    
    sqlite3_stmt *stmt;
    
    if (explorer_cached) {
        sqlite3_prepare_v2(db->db, "SELECT COUNT(*) FROM explorer_positions", -1, &stmt, NULL);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            *explorer_cached = sqlite3_column_int(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    
    if (evals_cached) {
        sqlite3_prepare_v2(db->db, "SELECT COUNT(*) FROM evaluations", -1, &stmt, NULL);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            *evals_cached = sqlite3_column_int(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    
    if (ease_cached) {
        sqlite3_prepare_v2(db->db, "SELECT COUNT(*) FROM ease_scores", -1, &stmt, NULL);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            *ease_cached = sqlite3_column_int(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
}
