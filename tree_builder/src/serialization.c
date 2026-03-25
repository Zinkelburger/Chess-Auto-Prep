/**
 * serialization.c - Tree Serialization Implementation
 * 
 * Provides JSON and binary serialization for tree export/import.
 */

#include "serialization.h"
#include "cJSON.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>


SerializationOptions serialization_options_default(void) {
    SerializationOptions opts = {
        .format = FORMAT_JSON,
        .include_fen = true,
        .include_engine_eval = true,
        .include_ease = true,
        .include_eca = true,
        .include_lichess_stats = true,
        .json_indent = 2
    };
    return opts;
}


/**
 * Recursively convert a node to cJSON object
 */
static cJSON* node_to_cjson(const TreeNode *node, const SerializationOptions *opts) {
    if (!node) return NULL;
    
    cJSON *obj = cJSON_CreateObject();
    if (!obj) return NULL;
    
    /* Always include these */
    cJSON_AddNumberToObject(obj, "id", (double)node->node_id);
    cJSON_AddNumberToObject(obj, "depth", node->depth);
    
    if (node->move_san[0]) {
        cJSON_AddStringToObject(obj, "move_san", node->move_san);
    }
    if (node->move_uci[0]) {
        cJSON_AddStringToObject(obj, "move_uci", node->move_uci);
    }
    
    /* Probabilities */
    cJSON_AddNumberToObject(obj, "move_probability", node->move_probability);
    cJSON_AddNumberToObject(obj, "cumulative_probability", node->cumulative_probability);
    
    /* Optional FEN */
    if (opts->include_fen && node->fen[0]) {
        cJSON_AddStringToObject(obj, "fen", node->fen);
    }
    
    /* Optional engine eval */
    if (opts->include_engine_eval && node->has_engine_eval) {
        cJSON_AddNumberToObject(obj, "engine_eval_cp", node->engine_eval_cp);
    }
    
    /* Optional ease */
    if (opts->include_ease && node->has_ease) {
        cJSON_AddNumberToObject(obj, "ease", node->ease);
    }
    
    /* Optional ECA (win-probability-delta units) */
    if (opts->include_eca && node->has_eca) {
        cJSON_AddNumberToObject(obj, "local_cpl", node->local_cpl);
        cJSON_AddNumberToObject(obj, "accumulated_eca", node->accumulated_eca);
    }
    
    /* Optional Lichess stats */
    if (opts->include_lichess_stats && node->total_games > 0) {
        cJSON_AddNumberToObject(obj, "white_wins", (double)node->white_wins);
        cJSON_AddNumberToObject(obj, "black_wins", (double)node->black_wins);
        cJSON_AddNumberToObject(obj, "draws", (double)node->draws);
        cJSON_AddNumberToObject(obj, "total_games", (double)node->total_games);
    }
    
    cJSON_AddBoolToObject(obj, "is_white_to_move", node->is_white_to_move);
    if (node->explored) {
        cJSON_AddBoolToObject(obj, "explored", true);
    }

    /* Children */
    if (node->children_count > 0) {
        cJSON *children = cJSON_CreateArray();
        if (children) {
            for (size_t i = 0; i < node->children_count; i++) {
                cJSON *child_obj = node_to_cjson(node->children[i], opts);
                if (child_obj) {
                    cJSON_AddItemToArray(children, child_obj);
                }
            }
            cJSON_AddItemToObject(obj, "children", children);
        }
    }
    
    return obj;
}


/**
 * Create tree JSON
 */
static char* tree_to_json_internal(const Tree *tree, const SerializationOptions *opts) {
    if (!tree) return NULL;
    
    cJSON *root = cJSON_CreateObject();
    if (!root) return NULL;
    
    /* Tree metadata */
    cJSON_AddStringToObject(root, "format", "opening_tree");
    cJSON_AddNumberToObject(root, "version", 2.0);
    cJSON_AddStringToObject(root, "eca_units", "wp_delta");
    cJSON_AddNumberToObject(root, "total_nodes", (double)tree->total_nodes);
    cJSON_AddNumberToObject(root, "max_depth", tree->max_depth_reached);
    cJSON_AddBoolToObject(root, "build_complete", tree->build_complete);
    
    /* Config */
    cJSON *config = cJSON_CreateObject();
    if (config) {
        cJSON_AddNumberToObject(config, "min_probability", tree->config.min_probability);
        cJSON_AddNumberToObject(config, "max_depth", tree->config.max_depth);
        if (tree->config.rating_range) {
            cJSON_AddStringToObject(config, "rating_range", tree->config.rating_range);
        }
        if (tree->config.speeds) {
            cJSON_AddStringToObject(config, "speeds", tree->config.speeds);
        }
        cJSON_AddNumberToObject(config, "min_games", tree->config.min_games);
        cJSON_AddItemToObject(root, "config", config);
    }
    
    /* Tree structure */
    if (tree->root) {
        cJSON *tree_obj = node_to_cjson(tree->root, opts);
        if (tree_obj) {
            cJSON_AddItemToObject(root, "tree", tree_obj);
        }
    }
    
    /* Convert to string */
    char *json_str;
    if (opts->json_indent > 0) {
        json_str = cJSON_Print(root);
    } else {
        json_str = cJSON_PrintUnformatted(root);
    }
    
    cJSON_Delete(root);
    
    return json_str;
}


bool tree_save(const Tree *tree, const char *filename, 
               const SerializationOptions *options) {
    if (!tree || !filename) return false;
    
    FILE *file = fopen(filename, "w");
    if (!file) {
        fprintf(stderr, "Error: Cannot open file for writing: %s\n", filename);
        return false;
    }
    
    bool result = tree_save_fp(tree, file, options);
    
    fclose(file);
    return result;
}


bool tree_save_fp(const Tree *tree, FILE *file,
                  const SerializationOptions *options) {
    if (!tree || !file) return false;
    
    SerializationOptions opts = options ? *options : serialization_options_default();
    
    if (opts.format == FORMAT_JSON || opts.format == FORMAT_JSON_COMPACT) {
        if (opts.format == FORMAT_JSON_COMPACT) {
            opts.json_indent = 0;
        }
        
        char *json = tree_to_json_internal(tree, &opts);
        if (!json) return false;
        
        size_t len = strlen(json);
        size_t written = fwrite(json, 1, len, file);
        
        free(json);
        
        return written == len;
    }
    else if (opts.format == FORMAT_BINARY) {
        /* Binary format - TODO: Implement */
        fprintf(stderr, "Binary format not yet implemented\n");
        return false;
    }
    
    return false;
}


bool tree_save_to_buffer(const Tree *tree, char **out_buffer, size_t *out_size,
                         const SerializationOptions *options) {
    if (!tree || !out_buffer || !out_size) return false;
    
    SerializationOptions opts = options ? *options : serialization_options_default();
    
    if (opts.format == FORMAT_JSON_COMPACT) {
        opts.json_indent = 0;
    }
    
    char *json = tree_to_json_internal(tree, &opts);
    if (!json) return false;
    
    *out_buffer = json;
    *out_size = strlen(json);
    
    return true;
}


/**
 * Recursively parse cJSON into TreeNode
 */
static TreeNode* cjson_to_node(cJSON *obj, TreeNode *parent) {
    if (!obj) return NULL;
    
    /* Get FEN and moves */
    cJSON *fen_item = cJSON_GetObjectItem(obj, "fen");
    cJSON *san_item = cJSON_GetObjectItem(obj, "move_san");
    cJSON *uci_item = cJSON_GetObjectItem(obj, "move_uci");
    
    const char *fen = fen_item && cJSON_IsString(fen_item) ? fen_item->valuestring : "";
    const char *san = san_item && cJSON_IsString(san_item) ? san_item->valuestring : NULL;
    const char *uci = uci_item && cJSON_IsString(uci_item) ? uci_item->valuestring : NULL;
    
    TreeNode *node = node_create(fen, san, uci, parent);
    if (!node) return NULL;
    
    /* Parse probabilities */
    cJSON *prob = cJSON_GetObjectItem(obj, "move_probability");
    if (prob && cJSON_IsNumber(prob)) {
        node->move_probability = prob->valuedouble;
    }
    
    cJSON *cumul = cJSON_GetObjectItem(obj, "cumulative_probability");
    if (cumul && cJSON_IsNumber(cumul)) {
        node->cumulative_probability = cumul->valuedouble;
    }
    
    /* Parse engine eval */
    cJSON *eval = cJSON_GetObjectItem(obj, "engine_eval_cp");
    if (eval && cJSON_IsNumber(eval)) {
        node_set_eval(node, (int)eval->valuedouble);
    }
    
    /* Parse ease */
    cJSON *ease = cJSON_GetObjectItem(obj, "ease");
    if (ease && cJSON_IsNumber(ease)) {
        node_set_ease(node, ease->valuedouble);
    }
    
    /* Parse ECA fields (v2: wp-delta only; v1 backward compat: ignore Q-loss) */
    cJSON *lcpl = cJSON_GetObjectItem(obj, "local_cpl");
    cJSON *aeca = cJSON_GetObjectItem(obj, "accumulated_eca");
    if (lcpl && aeca) {
        node_set_eca(node, lcpl->valuedouble, aeca->valuedouble);
    }
    
    /* Parse Lichess stats */
    cJSON *ww = cJSON_GetObjectItem(obj, "white_wins");
    cJSON *bw = cJSON_GetObjectItem(obj, "black_wins");
    cJSON *dr = cJSON_GetObjectItem(obj, "draws");
    
    if (ww && bw && dr) {
        node_set_lichess_stats(node, 
                               (uint64_t)ww->valuedouble,
                               (uint64_t)bw->valuedouble,
                               (uint64_t)dr->valuedouble);
    }
    
    /* Parse is_white_to_move */
    cJSON *wtm = cJSON_GetObjectItem(obj, "is_white_to_move");
    if (wtm) {
        node->is_white_to_move = cJSON_IsTrue(wtm);
    }

    /* Parse explored flag (backward compat: infer from children) */
    cJSON *expl = cJSON_GetObjectItem(obj, "explored");
    if (expl) {
        node->explored = cJSON_IsTrue(expl);
    } else {
        node->explored = (node->children_count > 0);
    }

    /* Parse node ID */
    cJSON *id = cJSON_GetObjectItem(obj, "id");
    if (id && cJSON_IsNumber(id)) {
        node->node_id = (uint64_t)id->valuedouble;
    }
    
    /* Parse children */
    cJSON *children = cJSON_GetObjectItem(obj, "children");
    if (children && cJSON_IsArray(children)) {
        cJSON *child_item;
        cJSON_ArrayForEach(child_item, children) {
            TreeNode *child = cjson_to_node(child_item, node);
            if (child) {
                node_add_child(node, child);
            }
        }
    }
    
    return node;
}


Tree* tree_load(const char *filename) {
    if (!filename) return NULL;
    
    FILE *file = fopen(filename, "r");
    if (!file) {
        fprintf(stderr, "Error: Cannot open file for reading: %s\n", filename);
        return NULL;
    }
    
    Tree *result = tree_load_fp(file);
    
    fclose(file);
    return result;
}


Tree* tree_load_fp(FILE *file) {
    if (!file) return NULL;
    
    /* Read entire file */
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    if (size <= 0) return NULL;
    
    char *buffer = (char *)malloc(size + 1);
    if (!buffer) return NULL;
    
    size_t read = fread(buffer, 1, size, file);
    buffer[read] = '\0';
    
    Tree *tree = tree_load_from_buffer(buffer, read);
    
    free(buffer);
    return tree;
}


Tree* tree_load_from_buffer(const char *buffer, size_t size) {
    if (!buffer || size == 0) return NULL;
    
    (void)size;  /* Buffer is null-terminated, size not needed for JSON */
    
    cJSON *root = cJSON_Parse(buffer);
    if (!root) {
        fprintf(stderr, "Error: Failed to parse JSON\n");
        return NULL;
    }
    
    Tree *tree = tree_create();
    if (!tree) {
        cJSON_Delete(root);
        return NULL;
    }
    
    /* Parse metadata */
    cJSON *total = cJSON_GetObjectItem(root, "total_nodes");
    if (total && cJSON_IsNumber(total)) {
        tree->total_nodes = (size_t)total->valuedouble;
    }
    
    cJSON *max_d = cJSON_GetObjectItem(root, "max_depth");
    if (max_d && cJSON_IsNumber(max_d)) {
        tree->max_depth_reached = (int)max_d->valuedouble;
    }
    
    cJSON *bc = cJSON_GetObjectItem(root, "build_complete");
    /* Trees from older versions lack this field — assume complete */
    tree->build_complete = bc ? cJSON_IsTrue(bc) : true;

    /* Parse config */
    cJSON *config = cJSON_GetObjectItem(root, "config");
    if (config) {
        cJSON *min_prob = cJSON_GetObjectItem(config, "min_probability");
        if (min_prob && cJSON_IsNumber(min_prob)) {
            tree->config.min_probability = min_prob->valuedouble;
        }
        
        cJSON *cfg_max_d = cJSON_GetObjectItem(config, "max_depth");
        if (cfg_max_d && cJSON_IsNumber(cfg_max_d)) {
            tree->config.max_depth = (int)cfg_max_d->valuedouble;
        }
        
        cJSON *min_g = cJSON_GetObjectItem(config, "min_games");
        if (min_g && cJSON_IsNumber(min_g)) {
            tree->config.min_games = (int)min_g->valuedouble;
        }
    }
    
    /* Parse tree */
    cJSON *tree_obj = cJSON_GetObjectItem(root, "tree");
    if (tree_obj) {
        tree->root = cjson_to_node(tree_obj, NULL);
        
        /* Recalculate total nodes */
        if (tree->root) {
            tree->total_nodes = node_count_subtree(tree->root);
        }
    }
    
    cJSON_Delete(root);
    return tree;
}


char* tree_to_json(const Tree *tree, bool pretty) {
    SerializationOptions opts = serialization_options_default();
    opts.json_indent = pretty ? 2 : 0;
    return tree_to_json_internal(tree, &opts);
}


char* node_to_json(const TreeNode *node, bool include_children, bool pretty) {
    if (!node) return NULL;
    
    SerializationOptions opts = serialization_options_default();
    opts.json_indent = pretty ? 2 : 0;
    
    /* Temporarily clear children if not including them */
    size_t saved_count = node->children_count;
    if (!include_children) {
        ((TreeNode *)node)->children_count = 0;  /* Cast away const temporarily */
    }
    
    cJSON *obj = node_to_cjson(node, &opts);
    
    /* Restore children count */
    ((TreeNode *)node)->children_count = saved_count;
    
    if (!obj) return NULL;
    
    char *json;
    if (pretty) {
        json = cJSON_Print(obj);
    } else {
        json = cJSON_PrintUnformatted(obj);
    }
    
    cJSON_Delete(obj);
    return json;
}


bool tree_export_dot(const Tree *tree, const char *filename, int max_depth) {
    if (!tree || !tree->root || !filename) return false;
    
    FILE *file = fopen(filename, "w");
    if (!file) return false;
    
    fprintf(file, "digraph OpeningTree {\n");
    fprintf(file, "  rankdir=TB;\n");
    fprintf(file, "  node [shape=box, fontname=\"Helvetica\"];\n\n");
    
    /* BFS to write nodes */
    /* Simple implementation - would need proper queue for large trees */
    TreeNode *queue[10000];
    size_t head = 0, tail = 0;
    
    queue[tail++] = tree->root;
    
    while (head < tail) {
        TreeNode *node = queue[head++];
        
        if (max_depth >= 0 && node->depth > max_depth) continue;
        
        /* Node label */
        const char *move = node->move_san[0] ? node->move_san : "Start";
        fprintf(file, "  n%lu [label=\"%s\\n%.2f%%\"];\n",
                (unsigned long)node->node_id, move,
                node->cumulative_probability * 100.0);
        
        /* Edges to children */
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            fprintf(file, "  n%lu -> n%lu;\n",
                    (unsigned long)node->node_id,
                    (unsigned long)child->node_id);
            
            if (tail < 10000) {
                queue[tail++] = child;
            }
        }
    }
    
    fprintf(file, "}\n");
    fclose(file);
    
    return true;
}


/**
 * Internal recursive PGN line collection
 */
static void collect_pgn_lines(TreeNode *node, char *current_line, size_t line_len,
                               FILE *file, int move_num, bool is_white) {
    if (!node) return;
    
    char new_line[4096];
    
    if (node->move_san[0]) {
        if (is_white) {
            snprintf(new_line, sizeof(new_line), "%s%d. %s ", 
                     current_line, move_num, node->move_san);
        } else {
            snprintf(new_line, sizeof(new_line), "%s%s ", 
                     current_line, node->move_san);
        }
    } else {
        strncpy(new_line, current_line, sizeof(new_line) - 1);
    }
    
    if (node->children_count == 0) {
        /* Leaf node - write line */
        fprintf(file, "%s*\n\n", new_line);
    } else {
        /* Continue down tree */
        int next_move_num = is_white ? move_num : move_num + 1;
        
        for (size_t i = 0; i < node->children_count; i++) {
            collect_pgn_lines(node->children[i], new_line, strlen(new_line),
                              file, next_move_num, !is_white);
        }
    }
}


bool tree_export_pgn(const Tree *tree, const char *filename, bool include_variations) {
    if (!tree || !tree->root || !filename) return false;
    
    (void)include_variations;  /* TODO: Implement nested variations */
    
    FILE *file = fopen(filename, "w");
    if (!file) return false;
    
    /* Write PGN headers */
    fprintf(file, "[Event \"Opening Tree\"]\n");
    fprintf(file, "[Site \"tree_builder\"]\n");
    fprintf(file, "[Date \"????.??.??\"]\n");
    fprintf(file, "[Round \"?\"]\n");
    fprintf(file, "[White \"?\"]\n");
    fprintf(file, "[Black \"?\"]\n");
    fprintf(file, "[Result \"*\"]\n");
    
    /* Add FEN if not starting position */
    const char *starting_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    if (tree->root->fen[0] && strcmp(tree->root->fen, starting_fen) != 0) {
        fprintf(file, "[FEN \"%s\"]\n", tree->root->fen);
        fprintf(file, "[SetUp \"1\"]\n");
    }
    fprintf(file, "\n");
    
    /* Collect and write all lines */
    char line[4096] = "";
    collect_pgn_lines(tree->root, line, 0, file, 1, tree->root->is_white_to_move);
    
    fclose(file);
    return true;
}

