/**
 * eval_source.c - see eval_source.h
 */

#include "eval_source.h"

#include <stdlib.h>
#include <string.h>

void eval_lookup_result_clear(EvalLookupResult *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
}

void eval_source_destroy(EvalSource *src) {
    if (!src) return;
    if (src->close_fn) src->close_fn(src->ctx);
    free(src);
}

void eval_canonicalize_fen(char *fen) {
    if (!fen) return;
    int spaces = 0;
    for (char *p = fen; *p; p++) {
        if (*p == ' ' && ++spaces == 4) {
            *p = '\0';
            return;
        }
    }
}

bool eval_map_sqlite_score(int cp_val, int cp_null, int mate_val, int mate_null,
                           int *out_eval_cp, int *out_mate) {
    if (!mate_null) {
        if (out_mate) *out_mate = mate_val;
        if (out_eval_cp)
            *out_eval_cp = mate_val > 0 ? (10000 - mate_val) : (-10000 - mate_val);
        return true;
    }
    if (!cp_null) {
        if (out_mate) *out_mate = 0;
        if (out_eval_cp) *out_eval_cp = cp_val;
        return true;
    }
    return false;
}
