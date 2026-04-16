/// Repertoire selection — top-down DFS that marks one move at each
/// our-move node, picking the child with the highest expectimax value.
///
/// Ports C's `build_repertoire_recursive` from `repertoire.c`.
library;

import '../../models/build_tree_node.dart';
import 'eca_calculator.dart';
import 'fen_map.dart';
import 'generation_config.dart';

class RepertoireSelector {
  final TreeBuildConfig config;
  final ExpectimaxCalculator ecaCalc;
  final FenMap? fenMap;

  RepertoireSelector({
    required this.config,
    required this.ecaCalc,
    this.fenMap,
  });

  /// Mark `isRepertoireMove` flags on the tree.
  /// Returns the count of selected our-move repertoire entries.
  int select(BuildTree tree) {
    return _selectRecursive(tree.root);
  }

  int _selectRecursive(BuildTreeNode node) {
    if (node.depth >= config.maxDepth) return 0;
    if (node.cumulativeProbability < config.minProbability) return 0;

    // Transposition resolution: if this node is a childless transposition
    // leaf, redirect to the canonical node that has the real subtree
    // (matches C `resolve_transposition`).
    final resolved = _resolveTransposition(node);
    if (resolved.children.isEmpty) return 0;

    // Eval-window guard (skip root)
    if (node.depth > 0 && node.hasEngineEval) {
      final evalUs = node.evalForUs(config.playAsWhite);
      if (evalUs <= config.minEvalCp || evalUs >= config.maxEvalCp) return 0;
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    int count = 0;

    if (isOurMove) {
      final winner = ecaCalc.scoreOurMoveChildren(resolved);
      if (winner != null) {
        winner.child.isRepertoireMove = true;
        winner.child.repertoireScore = winner.expectimaxValue;
        count++;
        count += _selectRecursive(winner.child);
      }
    } else {
      for (final child in resolved.children) {
        if (child.cumulativeProbability < config.minProbability) continue;
        count += _selectRecursive(child);
      }
    }

    return count;
  }

  /// If [node] is a childless transposition leaf, find the canonical node
  /// (which has children) via the FenMap.  Returns [node] itself if it
  /// already has children or no canonical is found.
  BuildTreeNode _resolveTransposition(BuildTreeNode node) {
    if (node.children.isNotEmpty || fenMap == null) return node;
    final canonical = fenMap!.getCanonical(node.fen);
    if (canonical != null && canonical != node && canonical.children.isNotEmpty) {
      return canonical;
    }
    return node;
  }
}
