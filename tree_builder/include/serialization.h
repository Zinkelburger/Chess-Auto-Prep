/**
 * serialization.h - Tree Serialization
 * 
 * Provides functions to save and load trees in various formats.
 * Primary format is JSON for interoperability with Python/Flutter/JS.
 * Also supports a compact binary format for fast loading.
 */

#ifndef SERIALIZATION_H
#define SERIALIZATION_H

#include "tree.h"
#include <stdbool.h>
#include <stdio.h>

/**
 * SerializationFormat - Available output formats
 */
typedef enum SerializationFormat {
    FORMAT_JSON,            /* Human-readable JSON */
    FORMAT_JSON_COMPACT,    /* Minified JSON */
    FORMAT_BINARY,          /* Compact binary format */
} SerializationFormat;


/**
 * SerializationOptions - Options for serialization
 */
typedef struct SerializationOptions {
    SerializationFormat format;
    bool include_fen;               /* Include FEN strings (adds size but useful) */
    bool include_engine_eval;       /* Include engine evaluations */
    bool include_ease;              /* Include ease scores */
    bool include_eca;               /* Include ECA (Expected Centipawn Advantage) */
    bool include_lichess_stats;     /* Include detailed Lichess stats */
    int json_indent;                /* JSON indentation (0 = compact) */
} SerializationOptions;


/**
 * Get default serialization options
 * 
 * @return SerializationOptions with sensible defaults
 */
SerializationOptions serialization_options_default(void);

/**
 * Save tree to file
 * 
 * @param tree The tree to save
 * @param filename Output filename
 * @param options Serialization options
 * @return true on success, false on failure
 */
bool tree_save(const Tree *tree, const char *filename, 
               const SerializationOptions *options);

/**
 * Save tree to file handle
 * 
 * @param tree The tree to save
 * @param file Output file handle
 * @param options Serialization options
 * @return true on success, false on failure
 */
bool tree_save_fp(const Tree *tree, FILE *file,
                  const SerializationOptions *options);

/**
 * Save tree to memory buffer
 * 
 * @param tree The tree to save
 * @param out_buffer Output buffer (allocated by function, caller frees)
 * @param out_size Output buffer size
 * @param options Serialization options
 * @return true on success, false on failure
 */
bool tree_save_to_buffer(const Tree *tree, char **out_buffer, size_t *out_size,
                         const SerializationOptions *options);

/**
 * Load tree from file
 * 
 * @param filename Input filename
 * @return Newly allocated Tree, or NULL on failure
 */
Tree* tree_load(const char *filename);

/**
 * Load tree from file handle
 * 
 * @param file Input file handle
 * @return Newly allocated Tree, or NULL on failure
 */
Tree* tree_load_fp(FILE *file);

/**
 * Load tree from memory buffer
 * 
 * @param buffer Input buffer
 * @param size Buffer size
 * @return Newly allocated Tree, or NULL on failure
 */
Tree* tree_load_from_buffer(const char *buffer, size_t size);

/**
 * Export tree to JSON string
 * 
 * Convenience function for getting JSON output.
 * 
 * @param tree The tree to export
 * @param pretty Whether to pretty-print (indent)
 * @return Newly allocated JSON string (caller frees), or NULL on failure
 */
char* tree_to_json(const Tree *tree, bool pretty);

/**
 * Export single node to JSON
 * 
 * @param node The node to export
 * @param include_children Whether to include child nodes recursively
 * @param pretty Whether to pretty-print
 * @return Newly allocated JSON string (caller frees), or NULL on failure
 */
char* node_to_json(const TreeNode *node, bool include_children, bool pretty);

/**
 * Export tree structure as DOT graph (for visualization with Graphviz)
 * 
 * @param tree The tree to export
 * @param filename Output filename (.dot)
 * @param max_depth Maximum depth to include (-1 for all)
 * @return true on success, false on failure
 */
bool tree_export_dot(const Tree *tree, const char *filename, int max_depth);

/**
 * Export tree to PGN format (all lines)
 * 
 * @param tree The tree to export
 * @param filename Output filename (.pgn)
 * @param include_variations Whether to include as nested variations
 * @return true on success, false on failure
 */
bool tree_export_pgn(const Tree *tree, const char *filename, bool include_variations);

#endif /* SERIALIZATION_H */

