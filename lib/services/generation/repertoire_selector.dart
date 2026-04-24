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
    if (node.ply >= config.maxPly) return 0;
    if (node.cumulativeProbability < config.minProbability) return 0;

    // Transposition resolution: if this node is a childless transposition
    // leaf, redirect to the canonical node that has the real subtree
    // (matches C `resolve_transposition`).
    final resolved = _resolveTransposition(node);
    if (resolved.children.isEmpty) return 0;

    // Eval-window guard (skip root)
    if (node.ply > 0 && node.hasEngineEval) {
      final evalUs = node.evalForUs(config.playAsWhite);
      if (evalUs <= config.minEvalCp || evalUs >= config.maxEvalCp) return 0;
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    int count = 0;

    if (isOurMove) {
      final winner = _pickOurMove(resolved);
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

  ScoredChild? _pickOurMove(BuildTreeNode node) {
    switch (config.selectionMode) {
      case SelectionMode.engineOnly:
        return _pickByEngineEval(node);
      case SelectionMode.dbWinRateOnly:
        return _pickByDbWinRate(node);
      case SelectionMode.expectimax:
        return ecaCalc.scoreOurMoveChildren(node);
    }
  }

  /// Engine-only: pick the child with the best engine eval for us,
  /// respecting the max-eval-loss filter.
  ScoredChild? _pickByEngineEval(BuildTreeNode node) {
    if (node.children.isEmpty) return null;

    int bestCp = -100000;
    BuildTreeNode? bestChild;

    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      final cpUs = child.evalForUs(config.playAsWhite);
      if (cpUs > bestCp) {
        bestCp = cpUs;
        bestChild = child;
      }
    }

    if (bestChild == null) return null;
    return ScoredChild(
      child: bestChild,
      expectimaxValue: bestChild.expectimaxValue,
    );
  }

  /// DB-win-rate-only: pick the child with the highest database win rate.
  ScoredChild? _pickByDbWinRate(BuildTreeNode node) {
    if (node.children.isEmpty) return null;

    double bestWr = -1.0;
    BuildTreeNode? bestChild;

    for (final child in node.children) {
      if (child.totalGames == 0) continue;
      final wr = config.playAsWhite ? child.winRate : 1.0 - child.winRate;
      if (wr > bestWr) {
        bestWr = wr;
        bestChild = child;
      }
    }

    // Fallback: if no children have DB data, pick by engine eval
    if (bestChild == null) return _pickByEngineEval(node);

    return ScoredChild(
      child: bestChild,
      expectimaxValue: bestChild.expectimaxValue,
    );
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
