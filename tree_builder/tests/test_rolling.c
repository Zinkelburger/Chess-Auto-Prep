#include "cJSON.h"
#include "pure_search.h"
#include "maia.h"
#include "serialization.h"
#include <assert.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
volatile sig_atomic_t g_interrupted = 0;
static TreeNode *find(TreeNode *n, int id) {
    if (n->node_id == (uint64_t)id)
        return n;
    for (size_t i = 0; i < n->children_count; i++) {
        TreeNode *found = find(n->children[i], id);
        if (found)
            return found;
    }
    return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    MaiaContext *maia = maia_create("../assets/maia3_simplified.onnx");
    assert(maia);
    MaiaResponse first = {0}, again = {0};
    const char *repeat_fen = "8/8/8/8/P7/3k4/8/4K3 b - - 0 2";
    assert(maia_evaluate(maia, repeat_fen, 2200, &first) && first.success);
    for (int i = 0; i < 3; i++) {
        assert(maia_evaluate(maia, repeat_fen, 2200, &again) && again.success);
        assert(first.move_count == again.move_count);
        for (int j = 0; j < first.move_count; j++) {
            assert(!strcmp(first.moves[j].uci, again.moves[j].uci));
            assert(first.moves[j].probability == again.moves[j].probability);
        }
    }
    maia_destroy(maia);
    /* Probability and decision-value persistence must not drift on reload. */
    double exact = 0.5439807132251868;
    cJSON *number = cJSON_CreateNumber(exact);
    for (int i = 0; i < 100; i++) {
        char *encoded = cJSON_PrintUnformatted(number);
        cJSON_Delete(number);
        number = cJSON_Parse(encoded);
        free(encoded);
        assert(number && number->valuedouble == exact);
    }
    cJSON_Delete(number);

    FILE *f = fopen(argv[1], "rb");
    assert(f);
    fseek(f, 0, SEEK_END);
    long length = ftell(f);
    rewind(f);
    char *buffer = calloc((size_t)length + 1, 1);
    assert(buffer);
    assert(fread(buffer, 1, (size_t)length, f) == (size_t)length);
    fclose(f);
    cJSON *cases = cJSON_Parse(buffer);
    free(buffer);
    assert(cases);
    cJSON *j;
    int count = 0, worse = 0;
    cJSON_ArrayForEach(j, cases) {
        char *json = cJSON_PrintUnformatted(j);
        Tree *tree = tree_load_from_buffer(json, strlen(json));
        free(json);
        assert(tree);
        assert(tree->config.rolling_search);
        RepertoireConfig cfg = repertoire_config_default();
        cfg.play_as_white = tree->config.play_as_white;
        cfg.max_depth = 8;
        cfg.max_eval_loss_cp = 20000;
        cfg.rolling_search = true;
        cJSON *decisions = cJSON_GetObjectItem(j, "decisions"), *d;
        cJSON_ArrayForEach(d, decisions) {
            TreeNode *node = find(tree->root, cJSON_GetObjectItem(d, "id")->valueint);
            assert(node);
            assert(pure_commit_window(node, &cfg, cJSON_GetObjectItem(d, "horizon")->valueint));
            assert(!strcmp(node->committed_move_uci, cJSON_GetObjectItem(d, "uci")->valuestring));
            assert(fabs(node->decision_value - cJSON_GetObjectItem(d, "value")->valuedouble) <
                   1e-12);
        }
        assert(pure_backup(tree, &cfg));
        double expected = cJSON_GetObjectItem(j, "policy_value")->valuedouble;
        assert(fabs(tree->root->expectimax_value - expected) < 1e-12);
        assert(tree->root->value_lower == tree->root->value_upper);
        if (cJSON_GetObjectItem(j, "full_value")->valuedouble > expected + 1e-6)
            worse++;
        SerializationOptions opts = serialization_options_default();
        char *saved = NULL;
        size_t len = 0;
        assert(tree_save_to_buffer(tree, &saved, &len, &opts));
        Tree *restored = tree_load_from_buffer(saved, len);
        free(saved);
        assert(restored);
        assert(restored->config.rolling_search && pure_backup(restored, &cfg));
        assert(fabs(restored->root->expectimax_value - expected) < 1e-12);
        tree_destroy(restored);
        tree_destroy(tree);
        count++;
    }
    assert(worse > 0);
    cJSON_Delete(cases);
    EnginePool *pool = engine_pool_create("tests/fake_uci.py", 1, 1, 1);
    assert(pool);
    TreeConfig cfg = tree_config_default();
    cfg.engine_pool = pool;
    cfg.eval_depth = 2;
    cfg.play_as_white = true;
    cfg.max_depth = 1;
    cfg.rolling_search = true;
    cfg.max_eval_loss_cp = 20000;
    Tree *tree = tree_create();
    const char *fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    cfg.max_nodes = 10;
    assert(pure_tree_build(tree, fen, &cfg, NULL));
    assert(!tree->build_complete && !tree->root->committed_move_uci[0]);
    cfg.max_nodes = 0;
    assert(pure_tree_build(tree, fen, &cfg, NULL));
    assert(tree->build_complete && tree->root->children_count == 20);
    assert(!strcmp(tree->root->committed_move_uci, "a2a3"));
    assert(tree->root->decision_horizon == 1);
    cfg.rolling_search = false;
    assert(!pure_tree_build(tree, fen, &cfg, NULL));
    cfg.rolling_search = true;
    snprintf(tree->config.pure_book_source, sizeof(tree->config.pure_book_source), "lichess-masters");
    assert(!pure_tree_build(tree, fen, &cfg, NULL));
    snprintf(tree->config.pure_book_source, sizeof(tree->config.pure_book_source), "none");
    tree->config.maia_policy_version = 0;
    assert(!pure_tree_build(tree, fen, &cfg, NULL));
    tree_destroy(tree);
    engine_pool_destroy(pool);
    printf("Rolling: %d independent eight-ply policies, horizon failures, serialization and "
           "builder checks passed.\n",
           count);
}
