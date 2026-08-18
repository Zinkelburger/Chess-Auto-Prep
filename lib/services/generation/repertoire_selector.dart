/// Repertoire selection — top-down DFS that marks one move at each
/// our-move node, picking the child with the highest expectimax value.
///
/// Ports C's `build_repertoire_recursive` from `repertoire.c`.
library;

import '../../models/build_tree_node.dart';
import '../../utils/eval_constants.dart';
import 'eca_calculator.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'node_selection.dart';
import 'setup_bias.dart';

/// Playable-mode blend: weight of expectimax value vs myEase when scoring
/// our-move candidates.  60/40 keeps objective strength dominant while
/// still letting naturalness break real ties.
const double kPlayabilityExpectimaxWeight = 0.6;
const double kPlayabilityEaseWeight = 1.0 - kPlayabilityExpectimaxWeight;

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

    if (isTranspositionCycle(node, resolved, visited)) return 0;

    // Eval-window guard (skip root)
    if (node.ply > 0 && node.hasEngineEval) {
      final evalUs = node.evalForUs(config.playAsWhite);
      if (evalUs <= config.minEvalCp || evalUs >= config.maxEvalCp) return 0;
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    int count = 0;

    final key = enterFenPath(resolved, visited);
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
    leaveFenPath(key, visited);

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
    // Setup bias last: an explicit preferred system outranks the soft
    // memorability preference.
    return _applySetupBias(node, _applyMemorabilityBias(node, winner));
  }

  /// Memorability tie-break: within
  /// [TreeBuildConfig.memorabilityToleranceCp] of the best child eval,
  /// prefer the move the user would most naturally play anyway (highest
  /// own-side Maia probability, populated on every our-move child during
  /// the build).  Natural moves are cheaper to memorize and survive
  /// forgetting.  Like the setup bias this only constrains the argmax —
  /// expectimax values are untouched, and the tolerance is capped at
  /// [TreeBuildConfig.maxEvalLossCp] so the override can never pick a move
  /// the eval-loss guard would reject.  0 disables.
  ///
  /// Skipped in trappy mode: a trappy pick deliberately trades eval for
  /// trickiness, and a naturalness override within the same tolerance
  /// would silently cancel exactly those picks.
  ScoredChild? _applyMemorabilityBias(BuildTreeNode node, ScoredChild? winner) {
    if (winner == null || config.memorabilityToleranceCp <= 0) return winner;
    if (config.selectionMode == SelectionMode.trappy) return winner;

    final bestCp = bestSiblingEvalCp(
      node.children,
      playAsWhite: config.playAsWhite,
    );
    if (bestCp == kWorstEvalCp) return winner;

    final tolerance = config.memorabilityToleranceCp < config.maxEvalLossCp
        ? config.memorabilityToleranceCp
        : config.maxEvalLossCp;

    BuildTreeNode? pick;
    var bestFreq = -1.0;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      // maiaFrequency < 0 means no Maia data — such a child can never win
      // the tie-break, and when NO child has data the winner stands.
      if (child.maiaFrequency < 0) continue;
      if (child.evalForUs(config.playAsWhite) < bestCp - tolerance) continue;
      if (child.maiaFrequency > bestFreq) {
        bestFreq = child.maiaFrequency;
        pick = child;
      }
    }

    if (pick == null || identical(pick, winner.child)) return winner;
    return ScoredChild(child: pick, expectimaxValue: pick.expectimaxValue);
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

    final bestCp = bestSiblingEvalCp(
      node.children,
      playAsWhite: config.playAsWhite,
    );
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
      // Without expectimax, scale raw cp into the same [0, 1]-ish range so
      // it stays comparable (kMateCpBase cp ≈ certain win ≈ V of 1.0).
      final score = child.hasExpectimax
          ? child.expectimaxValue
          : child.evalForUs(config.playAsWhite) / kMateCpBase;
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

  /// Engine-only: pick the child with the best engine eval for us
  /// (argmax over children that have an engine eval).
  ScoredChild? _pickByEngineEval(BuildTreeNode node) {
    // maxEvalLossCp: 0 keeps only the best-eval children; the argmax then
    // picks the first of them — same child the plain eval argmax chose.
    final bestChild = pickChildByValue(
      node.children,
      playAsWhite: config.playAsWhite,
      maxEvalLossCp: 0,
      eligible: (child) => child.hasEngineEval,
      value: (child) => child.evalForUs(config.playAsWhite).toDouble(),
      minValue: kWorstEvalCp.toDouble(),
    );

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
      final wr = child.winRateFor(config.playAsWhite);
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
  ///
  /// The filtered pass requires an engine eval, but the fallback pass
  /// historically considered ALL children — hence
  /// `eligibleGuardsFallback: false`.
  ScoredChild? _pickByOpponentCpl(BuildTreeNode node) {
    final bestChild = pickChildByValue(
      node.children,
      playAsWhite: config.playAsWhite,
      maxEvalLossCp: config.maxEvalLossCp,
      eligible: (child) => child.hasEngineEval,
      eligibleGuardsFallback: false,
      value: (child) => child.cplValue,
    );

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
      final score =
          child.expectimaxValue * kPlayabilityExpectimaxWeight +
          myEase * kPlayabilityEaseWeight;
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
