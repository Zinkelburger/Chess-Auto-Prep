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
/* Cut normalized reply shares p[0..n) to the likeliest until they cover
 * mass (0 = no mass limit), at most most (0 = no cap), always keeping one;
 * dropped shares become 0 and kept ones are renormalized to sum to one.
 * Equal shares rank by UCI. Mirrors likeliestReplies in
 * lib/chess/generation/sources.dart. Returns how many were kept. */
int pure_cut_replies(const PureMove *moves, int n, double *p, double mass, int most);
bool pure_tree_build(Tree *tree, const char *fen, const TreeConfig *config,
                     struct LichessExplorer *explorer);
size_t pure_backup(Tree *tree, const RepertoireConfig *config);
bool pure_commit_window(TreeNode *, const RepertoireConfig *, int horizon);
int pure_pick(TreeNode *node, const RepertoireConfig *config, ScoredChild *out);
#endif
