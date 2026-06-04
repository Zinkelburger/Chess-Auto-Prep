/**
 * chessdb_api.c - see chessdb_api.h
 */

#include "chessdb_api.h"
#include "sqlite3.h"

#include <curl/curl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHESSDB_BASE_URL "http://www.chessdb.cn/cdb.php"

typedef struct {
    char *data;
    size_t size;
    size_t capacity;
} ResponseBuffer;

struct ChessDBAPI {
    ChessDBAPIConfig config;
    CURL            *curl;
    pthread_mutex_t  mutex;
    pthread_cond_t   slot_cond;
    int              in_flight;
    int              quota_used;
    int              quota_day;     /* YYYYMMDD UTC */
    sqlite3         *quota_db;
    ChessDBHTTPDoFn  http_hook;
    void            *http_hook_ctx;
};

ChessDBAPIConfig chessdb_api_config_default(void) {
    ChessDBAPIConfig c = {
        .enabled = false,
        .daily_quota = 5000,
        .max_concurrency = 2,
        .quota_persist_path = NULL,
    };
    return c;
}

static int today_utc_yyyymmdd(void) {
    time_t now = time(NULL);
    struct tm tm;
    gmtime_r(&now, &tm);
    return (tm.tm_year + 1900) * 10000 + (tm.tm_mon + 1) * 100 + tm.tm_mday;
}

static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t realsize = size * nmemb;
    ResponseBuffer *buf = (ResponseBuffer *)userp;
    if (buf->size + realsize + 1 > buf->capacity) {
        size_t new_cap = buf->capacity ? buf->capacity * 2 : 256;
        if (new_cap < buf->size + realsize + 1)
            new_cap = buf->size + realsize + 1;
        char *nd = realloc(buf->data, new_cap);
        if (!nd) return 0;
        buf->data = nd;
        buf->capacity = new_cap;
    }
    memcpy(buf->data + buf->size, contents, realsize);
    buf->size += realsize;
    buf->data[buf->size] = '\0';
    return realsize;
}

static void quota_load(ChessDBAPI *api) {
    api->quota_day = today_utc_yyyymmdd();
    api->quota_used = 0;
    if (!api->quota_db) return;

    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(api->quota_db,
            "SELECT day, used FROM chessdb_api_quota WHERE id = 1;",
            -1, &s, NULL) != SQLITE_OK)
        return;
    if (sqlite3_step(s) == SQLITE_ROW) {
        int day = sqlite3_column_int(s, 0);
        int used = sqlite3_column_int(s, 1);
        if (day == api->quota_day)
            api->quota_used = used;
    }
    sqlite3_finalize(s);
}

static void quota_save(ChessDBAPI *api) {
    if (!api->quota_db) return;
    sqlite3_exec(api->quota_db,
        "CREATE TABLE IF NOT EXISTS chessdb_api_quota ("
        "  id INTEGER PRIMARY KEY CHECK (id = 1),"
        "  day INTEGER NOT NULL,"
        "  used INTEGER NOT NULL"
        ");", NULL, NULL, NULL);
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(api->quota_db,
            "INSERT INTO chessdb_api_quota (id, day, used) VALUES (1, ?, ?)"
            " ON CONFLICT(id) DO UPDATE SET day = excluded.day, used = excluded.used;",
            -1, &s, NULL) != SQLITE_OK)
        return;
    sqlite3_bind_int(s, 1, api->quota_day);
    sqlite3_bind_int(s, 2, api->quota_used);
    sqlite3_step(s);
    sqlite3_finalize(s);
}

static bool quota_consume(ChessDBAPI *api) {
    int today = today_utc_yyyymmdd();
    if (today != api->quota_day) {
        api->quota_day = today;
        api->quota_used = 0;
    }
    if (api->quota_used >= api->config.daily_quota)
        return false;
    api->quota_used++;
    quota_save(api);
    return true;
}

bool chessdb_map_api_score(int raw_score, int *out_eval_cp, int *out_mate) {
    if (abs(raw_score) > 10000) {
        int ply = 30000 - abs(raw_score);
        if (ply <= 0) return false;
        if (out_mate) *out_mate = ply;
        if (out_eval_cp)
            *out_eval_cp = raw_score > 0 ? (10000 - ply) : (-10000 - ply);
        return true;
    }
    if (out_mate) *out_mate = 0;
    if (out_eval_cp) *out_eval_cp = raw_score;
    return true;
}

bool chessdb_parse_queryscore_body(const char *body, int *out_eval_cp,
                                   int *out_depth, bool *out_unknown) {
    if (out_unknown) *out_unknown = false;
    if (!body || !body[0]) return false;

    if (strstr(body, "unknown") || strstr(body, "invalid board"))
        { if (out_unknown) *out_unknown = true; return false; }

    if (strstr(body, "rate limit") || strstr(body, "quota"))
        return false;

    const char *p = strstr(body, "eval:");
    if (!p) {
        /* json=1 style: "eval":NUMBER */
        p = strstr(body, "\"eval\"");
        if (p) {
            p = strchr(p, ':');
            if (p) {
                int raw = atoi(p + 1);
                if (out_depth) *out_depth = 0;
                return chessdb_map_api_score(raw, out_eval_cp, NULL);
            }
        }
        return false;
    }

    int raw = atoi(p + 5);
    if (out_depth) *out_depth = 0;
    return chessdb_map_api_score(raw, out_eval_cp, NULL);
}

static bool url_encode_fen(const char *fen, char *out, size_t out_len) {
    if (!fen || !out || out_len == 0) return false;
    CURL *curl = curl_easy_init();
    if (!curl) {
        /* fallback: copy if no spaces */
        if (strchr(fen, ' ')) return false;
        snprintf(out, out_len, "%s", fen);
        return true;
    }
    char *enc = curl_easy_escape(curl, fen, (int)strlen(fen));
    curl_easy_cleanup(curl);
    if (!enc) return false;
    snprintf(out, out_len, "%s", enc);
    curl_free(enc);
    return true;
}

static bool http_get(ChessDBAPI *api, const char *url,
                     char *body, size_t body_cap, long *out_http_code) {
    if (api->http_hook) {
        size_t n = api->http_hook(api->http_hook_ctx, url, body, body_cap, out_http_code);
        return n > 0;
    }

    ResponseBuffer buf = {0};
    curl_easy_reset(api->curl);
    curl_easy_setopt(api->curl, CURLOPT_URL, url);
    curl_easy_setopt(api->curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(api->curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(api->curl, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(api->curl, CURLOPT_FOLLOWLOCATION, 1L);

    CURLcode res = curl_easy_perform(api->curl);
    long code = 0;
    curl_easy_getinfo(api->curl, CURLINFO_RESPONSE_CODE, &code);
    if (out_http_code) *out_http_code = code;

    bool ok = (res == CURLE_OK && code == 200 && buf.data && buf.size > 0);
    if (ok) {
        snprintf(body, body_cap, "%s", buf.data);
    }
    free(buf.data);
    return ok;
}

static bool acquire_slot(ChessDBAPI *api) {
    pthread_mutex_lock(&api->mutex);
    while (api->in_flight >= api->config.max_concurrency)
        pthread_cond_wait(&api->slot_cond, &api->mutex);
    api->in_flight++;
    pthread_mutex_unlock(&api->mutex);
    return true;
}

static void release_slot(ChessDBAPI *api) {
    pthread_mutex_lock(&api->mutex);
    api->in_flight--;
    pthread_cond_signal(&api->slot_cond);
    pthread_mutex_unlock(&api->mutex);
}

static pthread_once_t curl_global_once = PTHREAD_ONCE_INIT;

static void curl_global_init_once(void) {
    curl_global_init(CURL_GLOBAL_ALL);
}

ChessDBAPI *chessdb_api_create(const ChessDBAPIConfig *config) {
    pthread_once(&curl_global_once, curl_global_init_once);

    ChessDBAPI *api = calloc(1, sizeof(*api));
    if (!api) return NULL;

    api->config = config ? *config : chessdb_api_config_default();
    api->curl = curl_easy_init();
    if (!api->curl) { free(api); return NULL; }

    pthread_mutex_init(&api->mutex, NULL);
    pthread_cond_init(&api->slot_cond, NULL);

    if (api->config.quota_persist_path && api->config.quota_persist_path[0]) {
        if (sqlite3_open(api->config.quota_persist_path, &api->quota_db) != SQLITE_OK) {
            fprintf(stderr, "chessdb_api: quota DB open failed: %s\n",
                    api->config.quota_persist_path);
            if (api->quota_db) { sqlite3_close(api->quota_db); api->quota_db = NULL; }
        }
    }

    quota_load(api);
    return api;
}

void chessdb_api_destroy(ChessDBAPI *api) {
    if (!api) return;
    quota_save(api);
    if (api->curl) curl_easy_cleanup(api->curl);
    if (api->quota_db) sqlite3_close(api->quota_db);
    pthread_mutex_destroy(&api->mutex);
    pthread_cond_destroy(&api->slot_cond);
    free(api);
}

bool chessdb_api_quota_remaining(const ChessDBAPI *api) {
    if (!api || !api->config.enabled) return false;
    int today = today_utc_yyyymmdd();
    int used = api->quota_used;
    if (today != api->quota_day) used = 0;
    return used < api->config.daily_quota;
}

bool chessdb_api_is_enabled(const ChessDBAPI *api) {
    return api && api->config.enabled;
}

int chessdb_api_quota_used(const ChessDBAPI *api) {
    if (!api) return 0;
    if (today_utc_yyyymmdd() != api->quota_day) return 0;
    return api->quota_used;
}

void chessdb_api_flush_quota(ChessDBAPI *api) {
    if (api) quota_save(api);
}

bool chessdb_api_query_score(ChessDBAPI *api, const char *fen,
                             int *out_eval_cp, int *out_depth) {
    if (!api || !api->config.enabled || !fen) return false;

    pthread_mutex_lock(&api->mutex);
    bool have_quota = chessdb_api_quota_remaining(api);
    pthread_mutex_unlock(&api->mutex);
    if (!have_quota) return false;

    char fen4[128];
    snprintf(fen4, sizeof(fen4), "%s", fen);
    eval_canonicalize_fen(fen4);

    char enc[512];
    if (!url_encode_fen(fen4, enc, sizeof(enc))) return false;

    char url[1024];
    snprintf(url, sizeof(url),
             "%s?action=queryscore&board=%s&learn=0", CHESSDB_BASE_URL, enc);

    acquire_slot(api);
    char body[4096];
    long http_code = 0;
    bool ok = http_get(api, url, body, sizeof(body), &http_code);
    release_slot(api);

    if (!ok) return false;
    if (http_code == 429) return false;

    bool unknown = false;
    int cp = 0, depth = 0;
    if (!chessdb_parse_queryscore_body(body, &cp, &depth, &unknown))
        return false;

    pthread_mutex_lock(&api->mutex);
    if (!quota_consume(api)) {
        pthread_mutex_unlock(&api->mutex);
        return false;
    }
    pthread_mutex_unlock(&api->mutex);

    if (out_eval_cp) *out_eval_cp = cp;
    if (out_depth) *out_depth = depth;
    return true;
}

static void chessdb_api_source_lookup(void *ctx, const char *fen, int min_depth,
                                      EvalLookupResult *out) {
    ChessDBAPI *api = (ChessDBAPI *)ctx;
    eval_lookup_result_clear(out);
    (void)min_depth;

    int cp = 0, depth = 0;
    if (chessdb_api_query_score(api, fen, &cp, &depth)) {
        out->found = true;
        out->eval_cp = cp;
        out->depth = depth;
    }
}

static void chessdb_api_source_close(void *ctx) {
    (void)ctx;
}

EvalSource *chessdb_api_as_source(ChessDBAPI *api) {
    if (!api) return NULL;
    EvalSource *src = calloc(1, sizeof(*src));
    if (!src) return NULL;
    src->ctx = api;
    src->lookup = chessdb_api_source_lookup;
    src->close_fn = chessdb_api_source_close;
    return src;
}

static bool chessdb_api_fetch(ChessDBAPI *api, const char *action,
                              const char *fen4, char *body, size_t body_cap,
                              long *out_http_code) {
    char enc[512];
    if (!url_encode_fen(fen4, enc, sizeof(enc))) return false;

    char url[1024];
    snprintf(url, sizeof(url),
             "%s?action=%s&board=%s&learn=0", CHESSDB_BASE_URL, action, enc);

    acquire_slot(api);
    bool ok = http_get(api, url, body, body_cap, out_http_code);
    release_slot(api);
    return ok;
}

bool chessdb_api_query_pv(ChessDBAPI *api, const char *fen,
                          char *out_pv, size_t out_pv_len,
                          int *out_eval_cp) {
    if (!api || !api->config.enabled || !fen || !out_pv || out_pv_len == 0)
        return false;

    pthread_mutex_lock(&api->mutex);
    bool have_quota = chessdb_api_quota_remaining(api);
    pthread_mutex_unlock(&api->mutex);
    if (!have_quota) return false;

    char fen4[128];
    snprintf(fen4, sizeof(fen4), "%s", fen);
    eval_canonicalize_fen(fen4);

    char body[8192];
    long http_code = 0;
    if (!chessdb_api_fetch(api, "querypv", fen4, body, sizeof(body), &http_code))
        return false;
    if (http_code == 429) return false;
    if (strstr(body, "unknown") || strstr(body, "invalid board"))
        return false;

    const char *pv = strstr(body, "pv:");
    if (!pv) return false;

    pv += 3;
    size_t i = 0;
    while (*pv && *pv != '\n' && *pv != ' ' && i + 1 < out_pv_len) {
        if (*pv == ',') { out_pv[i++] = ' '; pv++; continue; }
        out_pv[i++] = *pv++;
    }
    out_pv[i] = '\0';

    if (out_eval_cp) {
        int depth = 0;
        bool unk = false;
        if (!chessdb_parse_queryscore_body(body, out_eval_cp, &depth, &unk)) {
            const char *ev = strstr(body, "score:");
            if (ev) *out_eval_cp = atoi(ev + 6);
        }
    }

    pthread_mutex_lock(&api->mutex);
    if (!quota_consume(api)) {
        pthread_mutex_unlock(&api->mutex);
        return false;
    }
    pthread_mutex_unlock(&api->mutex);
    return out_pv[0] != '\0';
}

void chessdb_api_set_http_hook(ChessDBAPI *api, ChessDBHTTPDoFn fn, void *ctx) {
    if (!api) return;
    api->http_hook = fn;
    api->http_hook_ctx = ctx;
}
