/// Export the policy chosen by the same Bellman scorer used for valuation.
library;

import '../../chess_core/generation/build_tree_node.dart';
import 'eca_calculator.dart';
import 'fen_map.dart';
import 'generation_config.dart';

/// Marks the repertoire move at every reachable our-turn node.
///
/// Selection follows [ExpectimaxCalculator.scoreOurMoveChildren] exactly, so
/// the exported policy is the one the backup valued; the calculator must
/// have run over [BuildTree] first.
class RepertoireSelector {
  final TreeBuildConfig config;
  final ExpectimaxCalculator ecaCalc;
  final FenMap? fenMap;
  RepertoireSelector({
    required this.config,
    required this.ecaCalc,
    this.fenMap,
  });

  /// Clear every repertoire flag, then walk from the root: our nodes take
  /// the scorer's winner, opponent nodes follow every positive-probability
  /// reply. Returns the number of moves marked.
  int select(BuildTree tree) {
    void clear(BuildTreeNode node) {
      node.isRepertoireMove = false;
      node.repertoireScore = 0;
      for (final c in node.children) {
        clear(c);
      }
    }

    clear(tree.root);
    final visited = <BuildTreeNode>{};
    var count = 0;
    void walk(BuildTreeNode arrival) {
      final node = resolveTransposition(arrival, fenMap);
      if (!visited.add(node) || node.terminalValue != null) return;
      if (node.isWhiteToMove == config.playAsWhite) {
        if (config.isRollingSearch && node.committedMoveUci.isEmpty) return;
        final winner = ecaCalc.scoreOurMoveChildren(node);
        if (winner == null) return;
        winner.child.isRepertoireMove = true;
        winner.child.repertoireScore = winner.expectimaxValue;
        count++;
        walk(winner.child);
      } else {
        for (final c in node.children) {
          if (c.moveProbability > 0) walk(c);
        }
      }
    }

    walk(tree.root);
    return count;
  }
}
