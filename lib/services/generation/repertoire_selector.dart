/// Repertoire selection — top-down DFS that marks one move at each
/// our-move node, picking the child with the highest expectimax value.
///
/// Ports C's `build_repertoire_recursive` from `repertoire.c`.
library;

import 'package:dartchess/dartchess.dart';

import '../../models/build_tree_node.dart';
import '../../utils/chess_utils.dart' show tryParseFen;
import '../../utils/fen_utils.dart' show normalizeFen;
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

  /// The user's skeleton (pins, transfer targets, structure vetoes).
  late final SkeletonPlan _plan = config.skeletonPlan;
  late final Map<String, String> _pins = _plan.pinsByFen;
  late final Side _ourSide = config.playAsWhite ? Side.white : Side.black;

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
    // Pins win unconditionally: a move the user played by hand is never
    // overridden by any scorer. (It is still eval-checked at build time and
    // the UI warns if it loses too much — but selection honours the choice.)
    final pinned = _pinnedChild(node);
    if (pinned != null) {
      return ScoredChild(
        child: pinned,
        expectimaxValue: pinned.expectimaxValue,
      );
    }

    final winner = switch (config.selectionMode) {
      SelectionMode.engineOnly => _pickByEngineEval(node),
      SelectionMode.dbWinRateOnly => _pickByDbWinRate(node),
      SelectionMode.expectimax => ecaCalc.scoreOurMoveChildren(node),
      SelectionMode.playable => _pickByPlayability(node),
      SelectionMode.trappy => _pickByOpponentCpl(node),
    };
    // Layered biases, cheapest-overriding-last so the strongest signal wins:
    //   structure veto  → drop the pick if it walks into a disliked structure
    //   transfer        → prefer the move the skeleton played nearby
    //   memorability    → prefer the more natural move
    //   setup           → an explicit preferred system
    // (Pins already handled above.)
    var w = _applyStructureVeto(node, winner);
    w = _applyTransferBias(node, w);
    return _applySetupBias(node, _applyMemorabilityBias(node, w));
  }

  /// The child of [node] that a pin selects, or null when [node] is not a
  /// pinned position or the pinned move is not among its children.
  BuildTreeNode? _pinnedChild(BuildTreeNode node) {
    if (_pins.isEmpty) return null;
    final uci = _pins[normalizeFen(node.fen)];
    if (uci == null) return null;
    for (final child in node.children) {
      if (child.moveUci == uci) return child;
    }
    return null;
  }

  /// Structure veto: if [winner] walks into a disliked structure (an avoided
  /// [StructureFeature] its subtree is expected to reach), swap it for the
  /// best sound child that avoids it. When every sound child is vetoed the
  /// winner stands — the veto filters, it never leaves us with nothing.
  ScoredChild? _applyStructureVeto(BuildTreeNode node, ScoredChild? winner) {
    if (winner == null || _plan.vetoes.isEmpty) return winner;
    if (!_vetoed(winner.child)) return winner;

    final bestCp = bestSiblingEvalCp(
      node.children,
      playAsWhite: config.playAsWhite,
    );
    if (bestCp == kWorstEvalCp) return winner;

    // Among sound (within-eval-loss) children that are NOT vetoed, keep the
    // one the objective likes best.
    BuildTreeNode? pick;
    var bestScore = double.negativeInfinity;
    for (final child in node.children) {
      if (!child.hasEngineEval) continue;
      if (child.evalForUs(config.playAsWhite) < bestCp - config.maxEvalLossCp) {
        continue;
      }
      if (_vetoed(child)) continue;
      final score = child.hasExpectimax
          ? child.expectimaxValue
          : child.evalForUs(config.playAsWhite) / kMateCpBase;
      if (score > bestScore) {
        bestScore = score;
        pick = child;
      }
    }
    if (pick == null || identical(pick, winner.child)) return winner;
    return ScoredChild(child: pick, expectimaxValue: pick.expectimaxValue);
  }

  /// Transfer bias: within [SkeletonPlan] transfer distance and the eval-loss
  /// window, prefer the move the skeleton played at the nearest position (the
  /// "answer 2.Nf3 like your 2.c4" behaviour). Only fires at unpinned nodes,
  /// only picks a non-vetoed child, and never overrides the eval guard.
  ScoredChild? _applyTransferBias(BuildTreeNode node, ScoredChild? winner) {
    if (winner == null || _plan.nodes.isEmpty) return winner;
    final match = _plan.transferFor(node.fen);
    if (match == null) return winner;
    if (winner.child.moveUci == match.uci) return winner;

    final bestCp = bestSiblingEvalCp(
      node.children,
      playAsWhite: config.playAsWhite,
    );
    if (bestCp == kWorstEvalCp) return winner;

    for (final child in node.children) {
      if (child.moveUci != match.uci) continue;
      if (!child.hasEngineEval) return winner;
      if (child.evalForUs(config.playAsWhite) < bestCp - config.maxEvalLossCp) {
        return winner; // transfer move is unsound here — leave the pick
      }
      if (_vetoed(child)) return winner;
      return ScoredChild(child: child, expectimaxValue: child.expectimaxValue);
    }
    return winner;
  }

  /// Whether [child] (an opponent-to-move node after our move) is expected to
  /// reach a vetoed structure, via a bounded probability-weighted walk of the
  /// already-built subtree. Mirrors the experiment's `expected_feature`: sum
  /// opponent replies by probability, take our structurally-best answer, and
  /// veto when the expected "avoid" score crosses [_vetoThreshold].
  bool _vetoed(BuildTreeNode child) {
    if (_plan.vetoes.isEmpty) return false;
    final score = _structureLookahead(child, _vetoPlies);
    return score <= _vetoThreshold;
  }

  static const int _vetoPlies = 4;
  static const double _vetoThreshold = -0.5;

  double _structureLookahead(BuildTreeNode node, int pliesLeft) {
    double here() {
      final pos = tryParseFen(node.fen);
      return pos == null ? 0.0 : _plan.structureScore(pos, _ourSide);
    }

    if (pliesLeft <= 0 || node.children.isEmpty) return here();

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    if (isOurMove) {
      // We steer: take the continuation that best avoids the vetoed feature,
      // so the veto only fires when we cannot escape it.
      var best = double.negativeInfinity;
      for (final c in node.children) {
        final v = _structureLookahead(c, pliesLeft - 1);
        if (v > best) best = v;
      }
      return best == double.negativeInfinity ? here() : best;
    }

    // Opponent to move: probability-weighted expectation over replies, with
    // the uncovered tail mass scored as the position stands. Raw (unnormalized)
    // probabilities, matching the pipeline's convention.
    var acc = 0.0;
    var mass = 0.0;
    for (final c in node.children) {
      final p = c.moveProbability;
      acc += p * _structureLookahead(c, pliesLeft - 1);
      mass += p;
    }
    if (mass < 1.0) acc += (1.0 - mass) * here();
    return acc;
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
