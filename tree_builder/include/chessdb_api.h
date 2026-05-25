/**
 * chessdb_api.h - ChessDB cloud API client (queryscore / querypv).
 *
 * HTTP endpoint: http://www.chessdb.cn/cdb.php?action=queryscore&board=[FEN]
 *
 * Daily quota is tracked in-memory with optional SQLite persistence.
 */

#ifndef CHESSDB_API_H
#define CHESSDB_API_H

#include "eval_source.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ChessDBAPI ChessDBAPI;

typedef struct ChessDBAPIConfig {
    bool        enabled;
    int         daily_quota;       /* default 5000 */
    int         max_concurrency;   /* default 2 */
    const char *quota_persist_path;/* optional SQLite for quota counter */
} ChessDBAPIConfig;

ChessDBAPIConfig chessdb_api_config_default(void);

ChessDBAPI *chessdb_api_create(const ChessDBAPIConfig *config);
void chessdb_api_destroy(ChessDBAPI *api);

/** Look up eval via queryscore. Returns false on miss/quota/error. */
bool chessdb_api_query_score(ChessDBAPI *api, const char *fen,
                             int *out_eval_cp, int *out_depth);

/** Look up PV line via querypv (best-effort parse of move list). */
bool chessdb_api_query_pv(ChessDBAPI *api, const char *fen,
                          char *out_pv, size_t out_pv_len,
                          int *out_eval_cp);

bool chessdb_api_quota_remaining(const ChessDBAPI *api);
bool chessdb_api_is_enabled(const ChessDBAPI *api);
int  chessdb_api_quota_used(const ChessDBAPI *api);
void chessdb_api_flush_quota(ChessDBAPI *api);

EvalSource *chessdb_api_as_source(ChessDBAPI *api);

/** Test hooks: inject HTTP response body without network. */
typedef size_t (*ChessDBHTTPDoFn)(void *ctx, const char *url,
                                  char *body, size_t body_cap,
                                  long *out_http_code);
void chessdb_api_set_http_hook(ChessDBAPI *api, ChessDBHTTPDoFn fn, void *ctx);

/** Parse helpers (unit-testable). */
bool chessdb_parse_queryscore_body(const char *body, int *out_eval_cp,
                                   int *out_depth, bool *out_unknown);
bool chessdb_map_api_score(int raw_score, int *out_eval_cp, int *out_mate);

#endif /* CHESSDB_API_H */
