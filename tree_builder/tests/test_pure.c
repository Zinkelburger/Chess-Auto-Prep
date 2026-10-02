#include "cJSON.h"
#include "pure_search.h"
#include "serialization.h"
#include <assert.h>
#include <signal.h>
volatile sig_atomic_t g_interrupted = 0;
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void check(TreeNode *n, cJSON *j, RepertoireConfig *cfg) {
    double expected = cJSON_GetObjectItem(j, "expected_value")->valuedouble;
    assert(fabs(n->expectimax_value - expected) < 1e-12);
    assert(fabs(n->value_lower - expected) < 1e-12);
    assert(fabs(n->value_upper - expected) < 1e-12);
    cJSON *pick = cJSON_GetObjectItem(j, "expected_pick");
    if (pick) {
        ScoredChild out;
        assert(pure_pick(n, cfg, &out));
        assert(out.child->node_id == (uint64_t)pick->valueint);
    }
    cJSON *children = cJSON_GetObjectItem(j, "children");
    for (size_t i = 0; i < n->children_count; i++)
        check(n->children[i], cJSON_GetArrayItem(children, (int)i), cfg);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    FILE *f = fopen(argv[1], "rb");
    assert(f);
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    rewind(f);
    char *buf = calloc((size_t)len + 1, 1);
    assert(fread(buf, 1, (size_t)len, f) == (size_t)len);
    fclose(f);
    cJSON *cases = cJSON_Parse(buf);
    assert(cases);
    free(buf);
    cJSON *j;
    int count = 0;
    cJSON_ArrayForEach(j, cases) {
        char *s = cJSON_PrintUnformatted(j);
        Tree *tree = tree_load_from_buffer(s, strlen(s));
        free(s);
        assert(tree);
        RepertoireConfig cfg = repertoire_config_default();
        cfg.play_as_white = tree->config.play_as_white;
        cfg.max_depth = 4;
        cfg.max_eval_loss_cp = 200;
        assert(pure_backup(tree, &cfg) > 0);
        check(tree->root, cJSON_GetObjectItem(j, "tree"), &cfg);
        tree_destroy(tree);
        count++;
    }
    cJSON_Delete(cases);
    PureMove moves[PURE_MAX_MOVES];
    int outcome;
    const char *start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    int n = pure_legal(start, moves, &outcome);
    assert(n == 20 && outcome == -1);
    int perft2 = 0;
    for (int i = 0; i < n; i++) {
        PureMove next[PURE_MAX_MOVES];
        perft2 += pure_legal(moves[i].fen, next, &outcome);
    }
    assert(perft2 == 400);
    n = pure_legal("4k3/P7/8/8/8/8/8/4K3 w - - 0 1", moves, &outcome);
    int promotions = 0;
    for (int i = 0; i < n; i++)
        if (strncmp(moves[i].uci, "a7a8", 4) == 0)
            promotions++;
    assert(promotions == 4);
    pure_legal("7k/6Q1/5K2/8/8/8/8/8 b - - 100 1", moves, &outcome);
    assert(outcome == 1);
    pure_legal("7k/5Q2/5K2/8/8/8/8/8 b - - 0 1", moves, &outcome);
    assert(outcome == 0);
    char a[128], b[128];
    assert(pure_position_key("4k3/8/8/8/4P3/8/8/4K3 b - e3 0 1", a));
    assert(pure_position_key("4k3/8/8/8/4P3/8/8/4K3 b - - 0 1", b));
    assert(strcmp(a, b) == 0);
    n = pure_legal("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 98 1", moves, &outcome);
    for (int i = 0; i < n; i++)
        if (strcmp(moves[i].uci, "e1g1") == 0)
            assert(strstr(moves[i].fen, " 99 1") != NULL);
    EnginePool *pool = engine_pool_create("tests/fake_uci.py", 1, 1, 1);
    assert(pool);
    TreeConfig cfg = tree_config_default();
    cfg.play_as_white = true;
    cfg.max_depth = 1;
    cfg.eval_depth = 2;
    cfg.engine_pool = pool;
    cfg.max_eval_loss_cp = 20000;
    Tree *built = tree_create();
    cfg.max_nodes = 10;
    assert(pure_tree_build(built, start, &cfg, NULL));
    assert(!built->build_complete && built->root->children_count == 0);
    cfg.max_nodes = 0;
    assert(pure_tree_build(built, start, &cfg, NULL));
    assert(built->build_complete && built->root->children_count == 20);
    RepertoireConfig rep = repertoire_config_default();
    rep.play_as_white = true;
    rep.max_depth = 1;
    rep.max_eval_loss_cp = 20000;
    assert(pure_backup(built, &rep) == 21);
    assert(built->root->expectimax_value == .5);
    RepertoireDB *db = rdb_open(":memory:");
    assert(db);
    RepertoireResult *result = generate_repertoire(built, db, pool, &rep, NULL);
    assert(result);
    assert(result->num_moves == 1 && result->num_lines == 1);
    char *saved = NULL;
    size_t saved_size = 0;
    SerializationOptions opts = serialization_options_default();
    assert(tree_save_to_buffer(built, &saved, &saved_size, &opts));
    Tree *restored = tree_load_from_buffer(saved, saved_size);
    assert(restored);
    free(saved);
    int selected = 0;
    for (size_t i = 0; i < restored->root->children_count; i++)
        selected += restored->root->children[i]->is_repertoire_move;
    assert(selected == 1);
    assert(restored->config.eval_depth == cfg.eval_depth);
    assert(restored->config.max_eval_loss_cp == cfg.max_eval_loss_cp);
    tree_destroy(restored);
    repertoire_result_free(result);
    rdb_close(db);
    cfg.eval_depth = 3;
    assert(!pure_tree_build(built, start, &cfg, NULL));
    /* The reply cut is part of a tree's identity: no other cut resumes it,
     * and it survives a save. */
    cfg.eval_depth = 2;
    cfg.reply_mass = 0.9;
    cfg.max_replies = 5;
    assert(!pure_tree_build(built, start, &cfg, NULL));
    built->config.reply_mass = 0.9;
    built->config.max_replies = 5;
    assert(tree_save_to_buffer(built, &saved, &saved_size, &opts));
    assert(strstr(saved, "\"v2_reply_mass\":0.9") && strstr(saved, "\"v2_max_replies\":5"));
    restored = tree_load_from_buffer(saved, saved_size);
    free(saved);
    assert(restored && restored->config.reply_mass == 0.9 && restored->config.max_replies == 5);
    tree_destroy(restored);
    cfg.max_replies = 4;
    assert(!pure_tree_build(built, start, &cfg, NULL));
    cfg.max_replies = 5;
    assert(pure_tree_build(built, start, &cfg, NULL));
    tree_destroy(built);
    /* likeliestReplies in lib/chess/generation/sources.dart, same cases as
     * test/chess/generation/reply_cut_test.dart. */
    PureMove spread[5] = {{"e8d8"}, {"e8f8"}, {"e8d7"}, {"e8e7"}, {"e8f7"}};
    double shares[5] = {0.5, 0.3, 0.1, 0.06, 0.04};
    assert(pure_cut_replies(spread, 5, shares, 0.9, 0) == 3);
    assert(fabs(shares[0] - 0.5 / 0.9) < 1e-12 && shares[3] == 0 && shares[4] == 0);
    assert(fabs(shares[0] + shares[1] + shares[2] - 1) < 1e-12);
    double capped[5] = {0.5, 0.3, 0.1, 0.06, 0.04};
    assert(pure_cut_replies(spread, 5, capped, 0.9, 2) == 2);
    assert(fabs(capped[0] - 0.625) < 1e-12 && fabs(capped[1] - 0.375) < 1e-12 && capped[2] == 0);
    double one[2] = {0.05, 0.95};
    assert(pure_cut_replies(spread, 2, one, 0.1, 0) == 1 && one[0] == 0 && one[1] == 1);
    double all[5] = {0.5, 0.3, 0.1, 0.06, 0.04};
    assert(pure_cut_replies(spread, 5, all, 0, 0) == 5 && all[4] == 0.04);
    PureMove tied[3] = {{"b"}, {"a"}, {"c"}};
    double ties[3] = {0.25, 0.25, 0.5};
    assert(pure_cut_replies(tied, 3, ties, 0, 2) == 2);
    assert(ties[0] == 0 && fabs(ties[1] - 1 / 3.0) < 1e-12 && fabs(ties[2] - 2 / 3.0) < 1e-12);
    double zero[3] = {0, 0.6, 0.4};
    assert(pure_cut_replies(tied, 3, zero, 0, 5) == 2 && zero[0] == 0);
    engine_pool_destroy(pool);
    printf("Pure: %d oracle trees and chess rule fixtures passed.\n", count);
    return 0;
}
