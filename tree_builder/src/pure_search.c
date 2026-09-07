/* Exhaustive finite-horizon reference search. Full path histories; no
 * transposition value borrowing, arbitrary popularity pruning or bonuses. */
#include "pure_search.h"
#include "engine_pool.h"
#include "lichess_api.h"
#include "maia.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool terminal_node(TreeNode *node, bool white, int outcome) {
    if (outcome < 0) {
        char key[128], other[128];
        int count = 0;
        if (!pure_position_key(node->fen, key))
            return false;
        for (TreeNode *p = node; p; p = p->parent) {
            if (pure_position_key(p->fen, other) && strcmp(key, other) == 0 && ++count >= 3) {
                outcome = 0;
                break;
            }
        }
    }
    if (outcome < 0)
        return false;
    node->terminal_known = true;
    node->terminal_value = outcome == 0 ? 0.5 : ((outcome == 1) == white ? 1 : 0);
    int cp = node->terminal_value == 0.5 ? 0 : node->terminal_value == 1 ? 10000 : -10000;
    node->engine_eval_cp = node->is_white_to_move == white ? cp : -cp;
    node->has_engine_eval = true;
    return true;
}
static bool evaluate(TreeNode *node, const TreeConfig *cfg) {
    if (node->has_engine_eval)
        return true;
    EvalJob job = {0};
    if (!engine_pool_evaluate_full(cfg->engine_pool, node->fen, &job) || !job.success ||
        (!job.is_mate && job.depth_reached < cfg->eval_depth))
        return false;
    node->engine_eval_cp = job.is_mate ? (job.mate_in > 0 ? 10000 : -10000) : job.eval_cp;
    node->has_engine_eval = true;
    if (cfg->stats)
        cfg->stats->sf_single_calls++;
    return true;
}
static bool policy(TreeNode *node, const TreeConfig *cfg,
                   PureMove *moves, int n, double *p) {
    double mass = 0;
    MaiaResponse response = {0};
    if (!cfg->maia || !maia_evaluate(cfg->maia, node->fen, cfg->maia_elo, &response) ||
        !response.success)
        return false;
    for (int j = 0; j < response.move_count; j++)
        for (int i = 0; i < n; i++)
            if (strcmp(moves[i].uci, response.moves[j].uci) == 0) {
                double prob = response.moves[j].probability;
                if (!isfinite(prob) || prob < 0)
                    return false;
                p[i] += prob;
                mass += prob;
            }
    if (!(mass > 0) || !isfinite(mass))
        return false;
    for (int i = 0; i < n; i++)
        p[i] /= mass;
    return true;
}
static bool search_window(Tree *, TreeNode *, const TreeConfig *, LichessExplorer *, int);
static bool rolling_build(Tree *, const TreeConfig *, LichessExplorer *);

bool pure_tree_build(Tree *tree, const char *fen, const TreeConfig *cfg,
                     LichessExplorer *explorer) {
    if (!tree || !cfg || !cfg->engine_pool || cfg->eval_depth < 1 || cfg->max_depth < 1 ||
        cfg->max_depth > 64 || cfg->max_eval_loss_cp < 0)
        return false;
    if (tree->root && tree->root->children_count && !tree->root->history_aware) {
        fprintf(stderr, "Legacy search tree: start a new Pure build.\n");
        return false;
    }
    const char *source = "none";
    if (tree->root && tree->root->children_count &&
        (strcmp(tree->config.pure_book_source, source) != 0))
        return false;
    if (tree->root && tree->root->children_count &&
        (tree->config.rolling_search != cfg->rolling_search ||
         tree->config.play_as_white != cfg->play_as_white ||
         tree->config.eval_depth != cfg->eval_depth ||
         tree->config.max_eval_loss_cp != cfg->max_eval_loss_cp ||
         tree->config.maia_elo != cfg->maia_elo ||
         tree->config.max_depth > cfg->max_depth || strcmp(tree->root->fen, fen) != 0)) {
        fprintf(stderr,
                "Pure resume requires the same position and model; horizon may only increase.\n");
        return false;
    }
    engine_pool_set_depth(cfg->engine_pool, cfg->eval_depth);
    tree->config = *cfg;
    tree->config.use_masters = false;
    tree->config.maia_only = true;
    snprintf(tree->config.pure_book_source, sizeof(tree->config.pure_book_source), "%s", source);
    if (!tree->root) {
        tree->root = node_create(fen, NULL, NULL, NULL);
        tree->total_nodes = 1;
    }
    if (!tree->root)
        return false;
    tree->is_building = true;
    tree->build_complete = false;
    tree->pure_failed = false;
    bool ok = cfg->rolling_search ? rolling_build(tree, cfg, explorer)
                                  : search_window(tree, tree->root, cfg, explorer, cfg->max_depth);
    tree->build_complete = ok && tree->is_building;
    tree->is_building = false;
    return !tree->pure_failed;
}

static bool search_window(Tree *tree, TreeNode *root, const TreeConfig *cfg,
                          LichessExplorer *explorer, int horizon) {
    size_t head = 0, tail = 1, cap = 1024;
    TreeNode **queue = malloc(cap * sizeof(*queue));
    if (!queue) {
        tree->pure_failed = true;
        return false;
    }
    queue[0] = root;
    bool ok = true;
    while (head < tail && tree->is_building) {
        TreeNode *node = queue[head++];
        node->history_aware = true;
        PureMove moves[PURE_MAX_MOVES];
        int outcome;
        int n = pure_legal(node->fen, moves, &outcome);
        if (n < 0) {
            ok = false;
            break;
        }
        if (terminal_node(node, cfg->play_as_white, outcome)) {
            node->explored = true;
            continue;
        }
        if (node->depth >= horizon) {
            if (!evaluate(node, cfg)) {
                ok = false;
                break;
            }
            node->explored = true;
            continue;
        }
        if (!(node->explored && node->children_count)) {
            bool ours = node->is_white_to_move == cfg->play_as_white;
            double probs[PURE_MAX_MOVES] = {0};
            if (!ours && !policy(node, cfg, moves, n, probs)) {
                fprintf(stderr, "Opponent policy unavailable at %s\n", node->fen);
                ok = false;
                break;
            }
            int count = 0;
            for (int i = 0; i < n; i++)
                if (ours || probs[i] > 0)
                    count++;
            if (cfg->max_nodes > 0 && tree->total_nodes + count > (size_t)cfg->max_nodes) {
                head--;
                break;
            }
            TreeNode *children[PURE_MAX_MOVES] = {0};
            int nc = 0, best = -1000000;
            for (int i = 0; i < n; i++) {
                if (!ours && probs[i] <= 0)
                    continue;
                TreeNode *child = node_create(moves[i].fen, moves[i].san, moves[i].uci, node);
                if (!child) {
                    ok = false;
                    break;
                }
                children[nc++] = child;
                child->history_aware = true;

                child->move_probability = ours ? 1 : probs[i];
                child->cumulative_probability =
                    node->cumulative_probability * child->move_probability;
                PureMove ignored[PURE_MAX_MOVES];
                int end;
                if (pure_legal(child->fen, ignored, &end) < 0) {
                    ok = false;
                    break;
                }
                terminal_node(child, cfg->play_as_white, end);
                if (ours && !evaluate(child, cfg)) {
                    ok = false;
                    break;
                }
                int cp = node_eval_for_us(child, cfg->play_as_white);
                if (ours && cp > best)
                    best = cp;
                if (!tree->is_building) {
                    ok = false;
                    break;
                }
            }
            if (!ok) {
                for (int i = 0; i < nc; i++)
                    node_destroy_single(children[i]);
                break;
            }
            /* Reserve before attaching anything: allocation failure must not
             * leave a partial action set that a later resume could duplicate. */
            if (node->children_count) {
                for (int i = 0; i < nc; i++)
                    node_destroy_single(children[i]);
                ok = false;
                break;
            }
            if (node->children_capacity < (size_t)nc) {
                TreeNode **reserved = realloc(node->children, (size_t)nc * sizeof(*reserved));
                if (!reserved) {
                    for (int i = 0; i < nc; i++)
                        node_destroy_single(children[i]);
                    ok = false;
                    break;
                }
                node->children = reserved;
                node->children_capacity = (size_t)nc;
            }
            /* Preserve the fixed-depth eval used by the parent safety constraint. */
            for (int i = 0; i < nc; i++) {
                TreeNode *child = children[i];
                if (ours &&
                    node_eval_for_us(child, cfg->play_as_white) < best - cfg->max_eval_loss_cp) {
                    node_destroy_single(child);
                    continue;
                }
                if (!node_add_child(node, child)) {
                    node_destroy_single(child);
                    ok = false;
                    continue;
                }
                tree->total_nodes++;
                if (child->depth > tree->max_depth_reached)
                    tree->max_depth_reached = child->depth;
            }
            node->explored = ok;
            if (!ok)
                break;
        }
        while (tail + node->children_count > cap) {
            cap *= 2;
            TreeNode **grown = realloc(queue, cap * sizeof(*queue));
            if (!grown) {
                ok = false;
                break;
            }
            queue = grown;
        }
        if (!ok)
            break;
        for (size_t i = 0; i < node->children_count; i++)
            queue[tail++] = node->children[i];
        tree->build_active_depth = node->depth;
        tree->build_queue_pending = tail - head;
        if (cfg->progress_callback) {
            BuildProgressInfo info = {0};
            info.total_nodes = (int)tree->total_nodes;
            info.current_depth = node->depth;
            info.max_depth_config = cfg->max_depth;
            info.remaining_at_depth = (int)(tail - head);
            info.eta_depth_seconds = -1;
            cfg->progress_callback(&info);
        }
    }
    bool complete = ok && tree->is_building && head == tail;
    if (!ok && tree->is_building)
        tree->pure_failed = true;
    free(queue);
    return complete;
}

int pure_pick(TreeNode *node, const RepertoireConfig *cfg, ScoredChild *out) {
    out->child = NULL;
    out->expectimax_value = -1;
    if (cfg->rolling_search) {
        if (!node->committed_move_uci[0])
            return 0;
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *c = node->children[i];
            if (!strcmp(c->move_uci, node->committed_move_uci) && c->has_expectimax) {
                out->child = c;
                out->expectimax_value = c->expectimax_value;
                return 1;
            }
        }
        return 0;
    }
    int best = -1000000;
    bool evaluated = false;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *c = node->children[i];
        if (c->has_expectimax && c->has_engine_eval) {
            evaluated = true;
            int cp = node_eval_for_us(c, cfg->play_as_white);
            if (cp > best)
                best = cp;
        }
    }
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *c = node->children[i];
        if (!c->has_expectimax ||
            (evaluated && (!c->has_engine_eval ||
                           node_eval_for_us(c, cfg->play_as_white) < best - cfg->max_eval_loss_cp)))
            continue;
        TreeNode *b = out->child;
        int cp = node_eval_for_us(c, cfg->play_as_white),
            bcp = b ? node_eval_for_us(b, cfg->play_as_white) : 0;
        if (!b || c->expectimax_value > b->expectimax_value ||
            (c->expectimax_value == b->expectimax_value &&
             (cp > bcp || (cp == bcp && (strcmp(c->move_uci, b->move_uci) < 0 ||
                                         (strcmp(c->move_uci, b->move_uci) == 0 &&
                                          strcmp(c->move_san, b->move_san) < 0)))))) {
            out->child = c;
            out->expectimax_value = c->expectimax_value;
        }
    }
    return out->child != NULL;
}
static void reset_visit(TreeNode *n) {
    n->value_visit = 0;
    n->has_expectimax = false;
    for (size_t i = 0; i < n->children_count; i++)
        reset_visit(n->children[i]);
}
static double leaf(TreeNode *n, const RepertoireConfig *cfg) {
    if (n->terminal_known)
        return n->terminal_value;
    if (!n->has_engine_eval)
        return 0.5;
    int cp = node_eval_for_us(n, cfg->play_as_white);
    return abs(cp) > 9000 ? (cp > 0 ? 1 : 0) : 1 / (1 + exp(-0.00368208 * cp));
}
static bool backup(TreeNode *n, const RepertoireConfig *cfg, size_t *count) {
    if (n->value_visit == 2)
        return true;
    if (n->value_visit == 1) {
        fprintf(stderr, "cycle %llu\n", (unsigned long long)n->node_id);
        return false;
    }
    if (n->terminal_known &&
        (!isfinite(n->terminal_value) || n->terminal_value < 0 || n->terminal_value > 1))
        return false;
    n->value_visit = 1;
    if (!n->history_aware && !n->children_count && n->next_equivalent) {
        TreeNode *e = n->next_equivalent;
        while (e && e != n) {
            if (e->children_count) {
                if (!backup(e, cfg, count))
                    return false;
                n->expectimax_value = e->expectimax_value;
                n->value_lower = e->value_lower;
                n->value_upper = e->value_upper;
                n->subtree_depth = e->subtree_depth;
                n->subtree_opp_plies = e->subtree_opp_plies;
                goto done;
            }
            e = e->next_equivalent;
        }
    }
    bool ours = n->is_white_to_move == cfg->play_as_white;
    n->subtree_depth = 0;
    n->subtree_opp_plies = 0;
    bool at_horizon = n->history_aware && n->depth >= cfg->max_depth;
    for (size_t i = 0; !at_horizon && !n->terminal_known && i < n->children_count; i++) {
        TreeNode *c = n->children[i];
        if (!backup(c, cfg, count))
            return false;
        if (c->subtree_depth + 1 > n->subtree_depth)
            n->subtree_depth = c->subtree_depth + 1;
        if (c->subtree_opp_plies + !ours > n->subtree_opp_plies)
            n->subtree_opp_plies = c->subtree_opp_plies + !ours;
    }
    if (n->terminal_known || !n->children_count || at_horizon ||
        (cfg->rolling_search && ours && !n->committed_move_uci[0])) {
        n->expectimax_value = leaf(n, cfg);
        bool exact = n->terminal_known ||
                     (n->has_engine_eval && (!n->history_aware || n->depth >= cfg->max_depth));
        n->value_lower = exact ? n->expectimax_value : 0;
        n->value_upper = exact ? n->expectimax_value : 1;
    } else if (ours) {
        ScoredChild winner;
        if (!pure_pick(n, cfg, &winner)) {
            fprintf(stderr, "no candidate %llu\n", (unsigned long long)n->node_id);
            return false;
        }
        n->expectimax_value = winner.expectimax_value;
        if (cfg->rolling_search) {
            n->value_lower = winner.child->value_lower;
            n->value_upper = winner.child->value_upper;
            goto done;
        }
        n->value_lower = 0;
        n->value_upper = 0;
        int best = -1000000;
        for (size_t i = 0; i < n->children_count; i++)
            if (n->children[i]->has_engine_eval) {
                int cp = node_eval_for_us(n->children[i], cfg->play_as_white);
                if (cp > best)
                    best = cp;
            }
        for (size_t i = 0; i < n->children_count; i++) {
            TreeNode *c = n->children[i];
            if (best > -1000000 && (!c->has_engine_eval || node_eval_for_us(c, cfg->play_as_white) <
                                                               best - cfg->max_eval_loss_cp))
                continue;
            n->value_lower = fmax(n->value_lower, c->value_lower);
            n->value_upper = fmax(n->value_upper, c->value_upper);
        }
    } else {
        double mass = 0, v = 0, lo = 0, hi = 0;
        for (size_t i = 0; i < n->children_count; i++) {
            TreeNode *c = n->children[i];
            double p = c->move_probability;
            if (!isfinite(p) || p < 0 || p > 1)
                return false;
            mass += p;
            v += p * c->expectimax_value;
            lo += p * c->value_lower;
            hi += p * c->value_upper;
        }
        if (mass > 1 + 1e-9 || (n->history_aware && n->explored && fabs(mass - 1) > 1e-9)) {
            fprintf(stderr, "probability mass %.17g at node %llu (turn=%d, ours=%d)\n", mass,
                    (unsigned long long)n->node_id, n->is_white_to_move, cfg->play_as_white);
            return false;
        }
        double tail = n->history_aware && n->explored ? 0 : fmax(0, 1 - mass);
        n->expectimax_value = fmin(1, v + tail * leaf(n, cfg));
        n->value_lower = fmin(1, lo);
        n->value_upper = fmin(1, hi + tail);
    }
done:
    n->has_expectimax = true;
    n->value_visit = 2;
    (*count)++;
    return true;
}
size_t pure_backup(Tree *tree, const RepertoireConfig *cfg) {
    if (!tree || !tree->root)
        return 0;
    RepertoireConfig local = *cfg;
    local.rolling_search = tree->config.rolling_search;
    reset_visit(tree->root);
    size_t count = 0;
    if (!backup(tree->root, &local, &count)) {
        fprintf(stderr, "Invalid probability or cyclic legacy tree: rebuild Pure search.\n");
        return 0;
    }
    return count;
}

/* Receding lookahead: commit only our next action, then cover every reply.
 * The descendants retain full path history; windows reuse evaluations, not
 * earlier choices made with a shorter horizon. */
static bool rolling_build(Tree *tree, const TreeConfig *cfg, LichessExplorer *explorer) {
    size_t head = 0, tail = 1, cap = 1024;
    TreeNode **queue = malloc(cap * sizeof(*queue));
    if (!queue) {
        tree->pure_failed = true;
        return false;
    }
    queue[0] = tree->root;
    bool ok = true;
    while (head < tail && tree->is_building) {
        TreeNode *node = queue[head++];
        bool ours = node->is_white_to_move == cfg->play_as_white;
        int horizon = node->depth + (ours ? 4 : 1);
        if (horizon > cfg->max_depth)
            horizon = cfg->max_depth;
        if (node->terminal_known || node->depth >= cfg->max_depth) {
            if (!search_window(tree, node, cfg, explorer, cfg->max_depth)) {
                ok = false;
                break;
            }
            continue;
        }
        TreeNode *selected = NULL;
        if (ours) {
            if (!node->committed_move_uci[0] || node->decision_horizon < horizon) {
                if (!search_window(tree, node, cfg, explorer, horizon)) {
                    ok = false;
                    break;
                }
                if (node->terminal_known)
                    continue;
                RepertoireConfig local = repertoire_config_default();
                local.play_as_white = cfg->play_as_white;
                local.max_eval_loss_cp = cfg->max_eval_loss_cp;
                if (!pure_commit_window(node, &local, horizon)) {
                    tree->pure_failed = true;
                    ok = false;
                    break;
                }
            }
            for (size_t i = 0; i < node->children_count; i++)
                if (!strcmp(node->children[i]->move_uci, node->committed_move_uci))
                    selected = node->children[i];
            if (!selected) {
                tree->pure_failed = true;
                ok = false;
                break;
            }
        } else if (!search_window(tree, node, cfg, explorer, horizon)) {
            ok = false;
            break;
        }
        size_t add = ours ? 1 : node->children_count;
        while (tail + add > cap)
            cap *= 2;
        TreeNode **grown = realloc(queue, cap * sizeof(*queue));
        if (!grown) {
            tree->pure_failed = true;
            ok = false;
            break;
        }
        queue = grown;
        if (ours)
            queue[tail++] = selected;
        else
            for (size_t i = 0; i < node->children_count; i++)
                queue[tail++] = node->children[i];
    }
    free(queue);
    return ok && tree->is_building && head == tail;
}

bool pure_commit_window(TreeNode *node, const RepertoireConfig *cfg, int horizon) {
    RepertoireConfig local = *cfg;
    local.max_depth = horizon;
    local.rolling_search = false;
    size_t count = 0;
    reset_visit(node);
    ScoredChild winner;
    if (!backup(node, &local, &count) || node->value_lower != node->value_upper ||
        !pure_pick(node, &local, &winner))
        return false;
    snprintf(node->committed_move_uci, sizeof(node->committed_move_uci), "%s",
             winner.child->move_uci);
    node->decision_horizon = horizon;
    node->decision_value = winner.expectimax_value;
    return true;
}
