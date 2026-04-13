/// Repertoire selection — top-down DFS that marks one move at each
/// our-move node, picking the child with the highest expectimax value.
///
/// Ports C's `build_repertoire_recursive` from `repertoire.c`.
library;

import '../../models/build_tree_node.dart';
import 'eca_calculator.dart';
import 'generation_config.dart';

class RepertoireSelector {
  final TreeBuildConfig config;
  final ExpectimaxCalculator ecaCalc;

  RepertoireSelector({required this.config, required this.ecaCalc});

  /// Mark `isRepertoireMove` flags on the tree.
  /// Returns the count of selected our-move repertoire entries.
  int select(BuildTree tree) {
    return _selectRecursive(tree.root);
  }

  int _selectRecursive(BuildTreeNode node) {
    if (node.depth >= config.maxDepth) return 0;
    if (node.cumulativeProbability < config.minProbability) return 0;
    if (node.children.isEmpty) return 0;

    // Eval-window guard (skip root)
    if (node.depth > 0 && node.hasEngineEval) {
      final evalUs = node.evalForUs(config.playAsWhite);
      if (evalUs <= config.minEvalCp || evalUs >= config.maxEvalCp) return 0;
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    int count = 0;

    if (isOurMove) {
      final winner = ecaCalc.scoreOurMoveChildren(node);
      if (winner != null) {
        winner.child.isRepertoireMove = true;
        winner.child.repertoireScore = winner.expectimaxValue;
        count++;
        count += _selectRecursive(winner.child);
      }
    } else {
      for (final child in node.children) {
        if (child.cumulativeProbability < config.minProbability) continue;
        count += _selectRecursive(child);
      }
    }

    return count;
  }
}
