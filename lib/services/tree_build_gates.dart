/// Frontier gates shared by the main BFS loop ([TreeBuildService]) and the
/// DB Explorer loop ([DbExplorerTreeBuilder]): whether a dequeued node is
/// still worth expanding, and whether its position is already expanded
/// elsewhere in the tree.
library;

import '../chess_core/generation/build_tree_node.dart';
import 'generation/build_run.dart';
import 'generation/frontier_queue.dart';
import 'generation/tree_prune.dart';

extension BuildRunFrontierGates on BuildRun {
  /// Whether [node] fell below the search floor: its reach is under
  /// `minProbability`, or (best-first) its discounted our-move priority is.
  /// Discounted alternatives are not worth budget (searchPriority ≤
  /// cumulativeProbability always).
  bool belowSearchFloor(BuildTreeNode node) =>
      node.cumulativeProbability < config.minProbability ||
      (config.bestFirst &&
          node.searchPriority >= 0.0 &&
          node.searchPriority < config.minProbability);

  /// Transposition detection: when [node]'s position is already expanded
  /// elsewhere, register [node] as a transposition leaf (adding its reach
  /// probability to the canonical subtree, which may re-queue leaves onto
  /// [queue]) and return true.  Otherwise register [node] as the canonical
  /// expansion and return false.
  bool resolveTranspositionOrRegister(BuildTreeNode node, FrontierQueue queue) {
    final canonical = fenMap.getCanonical(node.fen);
    // A node that already holds children (a resumed partial expansion) must
    // not become a transposition leaf: [resolveTransposition] only redirects
    // childless nodes, so its partial subtree would shadow the canonical one.
    // It re-expands instead, as before the table was seeded on resume.
    if (canonical != null &&
        !identical(canonical, node) &&
        node.children.isEmpty) {
      // A second way into the position: its reach is the sum of both.
      if (fenMap.addTransposition(node.fen, node)) {
        addArrivalCumP(
          canonical,
          node.cumulativeProbability,
          config.minProbability,
          queue,
          fenMap: fenMap,
        );
      }
      markExplored(node);
      return true;
    }
    fenMap.putCanonical(node.fen, node);
    return false;
  }
}
