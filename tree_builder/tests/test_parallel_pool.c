#include "database.h"
#include "engine_pool.h"
#include "sqlite3.h"
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
volatile sig_atomic_t g_interrupted = 0;

int main(void) {
    const char *fen = "8/8/8/8/8/4k3/P7/4K3 w - - 0 1";
    EnginePool *pool = engine_pool_create("tests/fake_uci.py", 2, 2, 2);
    assert(pool);
    EvalJob jobs[2] = {0};
    for (int i = 0; i < 2; i++) snprintf(jobs[i].fen, sizeof(jobs[i].fen), "%s", fen);
    assert(engine_pool_evaluate_batch(pool, jobs, 2, NULL, NULL) == 2);
    g_interrupted = 1;
    assert(engine_pool_evaluate_batch(pool, jobs, 2, NULL, NULL) == 0);
    assert(!jobs[0].success && !jobs[1].success);
    g_interrupted = 0;
    assert(engine_pool_evaluate_batch_single_thread(pool, jobs, 2) == 2);
    engine_pool_destroy(pool);

    char path[] = "/tmp/parallel-cache-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);
    RepertoireDB *src = rdb_open(path), *dst = rdb_open(":memory:");
    assert(src && dst);
    CachedMaiaMove move = {.uci = "e1f1", .probability = 1}, found;
    rdb_put_maia(src, fen, 2200, &move, 1);
    rdb_put_eval(src, fen, 37, 16);
    assert(rdb_set_metadata(src, "maia_policy_version", "0"));
    RdbCacheImportCounts counts;
    assert(rdb_import_cache_from(dst, path, &counts));
    assert(counts.evaluations == 1 && counts.maia_cache == 0);
    int cp, depth, n;
    assert(rdb_set_metadata(src, "maia_policy_version", "1"));
    assert(rdb_import_cache_from(dst, path, &counts) && counts.maia_cache == 1);
    rdb_close(src);
    // Old schema-valid import files may not have metadata at all.
    sqlite3 *raw;
    assert(sqlite3_open(path, &raw) == SQLITE_OK);
    assert(sqlite3_exec(raw, "DROP TABLE build_metadata", NULL, NULL, NULL) == SQLITE_OK);
    sqlite3_close(raw);
    assert(rdb_import_cache_from(dst, path, &counts) && counts.maia_cache == 0);
    assert(rdb_get_eval(dst, fen, &cp, &depth) && cp == 37 && depth == 16);
    assert(rdb_get_maia(dst, fen, 2200, &found, 1, &n) && n == 1);
    rdb_close(dst);
    unlink(path);
    puts("Parallel pool: reused jobs reset; cache imports preserve evals and reject stale Maia.");
}
