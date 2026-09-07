#ifndef PURE_SEARCH_H
#define PURE_SEARCH_H
#include "repertoire.h"
#include "tree.h"
#define PURE_MAX_MOVES 256
typedef struct {
    char uci[16], san[16], fen[128];
} PureMove;
/* Returns legal count, -1 on invalid input; terminal: -1 ongoing, 0 draw,
 * 1 White win, 2 Black win. Includes immediate move-count draw claims. */
int pure_legal(const char *fen, PureMove *moves, int *terminal);
bool pure_position_key(const char *fen, char key[128]);
bool pure_tree_build(Tree *tree, const char *fen, const TreeConfig *config,
                     struct LichessExplorer *explorer);
size_t pure_backup(Tree *tree, const RepertoireConfig *config);
bool pure_commit_window(TreeNode *, const RepertoireConfig *, int horizon);
int pure_pick(TreeNode *node, const RepertoireConfig *config, ScoredChild *out);
#endif
