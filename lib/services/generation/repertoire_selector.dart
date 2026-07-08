/// Repertoire selection — top-down DFS that marks one move at each
/// our-move node, picking the child with the highest expectimax value.
///
/// Ports C's `build_repertoire_recursive` from `repertoire.c`.
library;

import '../../models/build_tree_node.dart';
import '../../utils/eval_constants.dart';
import '../eval/eval_canonicalize.dart';
import 'eca_calculator.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'setup_bias.dart';

class RepertoireSelector {
  final TreeBuildConfig config;
  final ExpectimaxCalculator ecaCalc;
  final FenMap? fenMap;

  /// Normalized preferred-setup SAN set (empty = bias off).
  late final Set<String> _setupMoves = parseSetupMoves(config.setupMoves);

  RepertoireSelector({
    required this.config,
    required this.ecaCalc,
    this.fenMap,
  });

  /// Mark `isRepertoireMove` flags on the tree.
  /// Returns the count of selected our-move repertoire entries.
  int select(BuildTree tree) {
    return _selectRecursive(tree.root, <String>{});
  }

  int _selectRecursive(BuildTreeNode node, Set<String> visited) {
    if (node.ply >= config.maxPly && node.children.isEmpty) return 0;
    if (!_selectable(node)) return 0;

    // Transposition resolution: if this node is a childless transposition
    // leaf, redirect to the canonical node that has the real subtree
    // (matches C `resolve_transposition`).
    final resolved = resolveTransposition(node, fenMap);
    if (resolved.children.isEmpty) return 0;

    // Cycle guard: a transposition that re-enters a position already on the
    // current path would otherwise recurse forever (the ply guard can't stop
    // a redirect back to a shallower canonical). See REFACTOR_PLAN §1.3.
    final key = canonicalizeFen4(resolved.fen);
    if (!identical(resolved, node) && visited.contains(key)) return 0;

    // Eval-window guard (skip root)
    if (node.ply > 0 && node.hasEngineEval) {
      final evalUs = node.evalForUs(config.playAsWhite);
      if (evalUs <= config.minEvalCp || evalUs >= config.maxEvalCp) return 0;
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    int count = 0;

    visited.add(key);
    if (isOurMove) {
      final winner = _pickOurMove(resolved);
      if (winner != null) {
        winner.child.isRepertoireMove = true;
        winner.child.repertoireScore = winner.expectimaxValue;
        count++;
        count += _selectRecursive(winner.child, visited);
      }
    } else {
      for (final child in resolved.children) {
        if (!_selectable(child)) continue;
        count += _selectRecursive(child, visited);
      }
    }
    visited.remove(key);

    return count;
  }

  /// Coverage-aware probability guard: nodes below the reach-probability
  /// floor still get repertoire moves when the coverage floor forced them
  /// into the tree (their local move probability clears coverMinProb).
  bool _selectable(BuildTreeNode node) {
    if (node.cumulativeProbability >= config.minProbability) return true;
    return config.coverMinProb > 0.0 &&
        node.moveProbability >= config.coverMinProb;
  }

  ScoredChild? _pickOurMove(BuildTreeNode node) {
    final winner = switch (config.selectionMode) {
      SelectionMode.engineOnly => _pickByEngineEval(node),
      SelectionMode.dbWinRateOnly => _pickByDbWinRate(node),
      SelectionMode.expectimax => ecaCalc.scoreOurMoveChildren(node),
      SelectionMode.playable => _pickByPlayability(node),
      SelectionMode.trappy => _pickByOpponentCpl(node),
    };
    return _applySetupBias(node, winner);
  }

  /// Preferred-setup tie-break: within [TreeBuildConfig.setupToleranceCp]
  /// of the best child eval, prefer a move that advances the user's
  /// system.  Expectimax values are untouched — this only constrains the
  /// argmax, so when consistency would cost real eval (e.g. ...Ng4
  /// hitting the Be3 bishop) no setup move qualifies and the normal
  /// winner stands.
  ScoredChild? _applySetupBias(BuildTreeNode node, ScoredChild? winner) {
    if (winner == null || _setupMoves.isEmpty) return winner;
    if (_setupMoves.contains(normalizeSetupSan(winner.child.moveSan))) {
      return winner;
    }

    int bestCp = kWorstEvalCp;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      final cp = child.evalForUs(config.playAsWhite);
      if (cp > bestCp) bestCp = cp;
    }
    if (bestCp == kWorstEvalCp) return winner;

    // Never prefer a setup move the eval-loss guard would reject.
    final tolerance = config.setupToleranceCp < config.maxEvalLossCp
        ? config.setupToleranceCp
        : config.maxEvalLossCp;

    BuildTreeNode? setupPick;
    var bestScore = double.negativeInfinity;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      if (!_setupMoves.contains(normalizeSetupSan(child.moveSan))) continue;
      if (child.evalForUs(config.playAsWhite) < bestCp - tolerance) {
        continue;
      }
      // Among qualifying setup moves, keep the objective's favorite.
      final score = child.hasExpectimax
          ? child.expectimaxValue
          : child.evalForUs(config.playAsWhite) / 10000.0;
      if (score > bestScore) {
        bestScore = score;
        setupPick = child;
      }
    }

    if (setupPick == null) return winner;
    return ScoredChild(
      child: setupPick,
      expectimaxValue: setupPick.expectimaxValue,
    );
  }

  /// Engine-only: pick the child with the best engine eval for us,
  /// respecting the max-eval-loss filter.
  ScoredChild? _pickByEngineEval(BuildTreeNode node) {
    if (node.children.isEmpty) return null;

    int bestCp = kWorstEvalCp;
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

  /// Trappy mode: pick the child whose subtree maximizes total expected
  /// opponent centipawn loss, subject to the eval-loss filter.
  ScoredChild? _pickByOpponentCpl(BuildTreeNode node) {
    if (node.children.isEmpty) return null;

    int bestChildCp = kWorstEvalCp;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      final cpUs = child.evalForUs(config.playAsWhite);
      if (cpUs > bestChildCp) bestChildCp = cpUs;
    }

    double bestCpl = -1.0;
    BuildTreeNode? bestChild;
    int passing = 0;

    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      final cpUs = child.evalForUs(config.playAsWhite);
      if (cpUs < bestChildCp - config.maxEvalLossCp) continue;
      passing++;
      if (child.cplValue > bestCpl) {
        bestCpl = child.cplValue;
        bestChild = child;
      }
    }

    if (passing == 0) {
      for (final child in node.children) {
        if (child.cplValue > bestCpl) {
          bestCpl = child.cplValue;
          bestChild = child;
        }
      }
    }

    if (bestChild == null) return _pickByEngineEval(node);
    return ScoredChild(
      child: bestChild,
      expectimaxValue: bestChild.expectimaxValue,
    );
  }

  /// Playable mode: blend expectimax value (60%) with myEase (40%)
  /// to prefer moves that are both strong and natural.
  ScoredChild? _pickByPlayability(BuildTreeNode node) {
    if (node.children.isEmpty) return null;

    double bestScore = -1.0;
    BuildTreeNode? bestChild;

    for (final child in node.children) {
      if (!child.hasExpectimax) continue;
      final myEase = child.myEase >= 0 ? child.myEase : 0.5;
      final score = child.expectimaxValue * 0.6 + myEase * 0.4;
      if (score > bestScore) {
        bestScore = score;
        bestChild = child;
      }
    }

    if (bestChild == null) return _pickByEngineEval(node);
    return ScoredChild(
      child: bestChild,
      expectimaxValue: bestChild.expectimaxValue,
    );
  }
}
