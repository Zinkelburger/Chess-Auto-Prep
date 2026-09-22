/// Bellman backups for the declared opponent policy and engine-loss constraint.
/// Values are expected-score proxies; they are not calibrated human win rates.
library;

import '../../chess_core/generation/build_tree_node.dart';
import '../../utils/ease_utils.dart' show winProbability;
import '../../utils/findability.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'trap_score.dart';

/// Backs up expectimax values, bounds and subtree depths over a [BuildTree],
/// and scores our-move children with the same ordering selection uses.
///
/// Our nodes take the max over the children admitted by the engine-loss
/// window; opponent nodes take the policy-weighted sum, with any missing
/// probability mass valued at the node's own engine estimate. Terminal and
/// horizon leaves have exact bounds; every other frontier value is
/// provisional within [0, 1].
class ExpectimaxCalculator {
  final TreeBuildConfig config;
  final FenMap? fenMap;
  ExpectimaxCalculator({required this.config, this.fenMap});

  /// Back up the whole tree from its root. Returns the number of nodes
  /// visited. A Pure tree must have been built under the same search model
  /// as [config]; otherwise its saved values would be silently re-scored.
  int calculate(BuildTree tree) {
    if (tree.root.historyAware) _assertSavedModelMatches(tree.configSnapshot);
    return _calculate(
      tree.root,
      config.maxPly,
      fixedPolicy: config.isRollingSearch,
    );
  }

  void _assertSavedModelMatches(Map<String, dynamic> saved) {
    if (((saved['search_algorithm'] == 'rolling') != config.isRollingSearch) ||
        (saved['play_as_white'] != null &&
            saved['play_as_white'] != config.playAsWhite) ||
        (saved['max_depth'] != null && saved['max_depth'] != config.maxPly) ||
        (saved['max_eval_loss_cp'] != null &&
            saved['max_eval_loss_cp'] != config.maxEvalLossCp)) {
      throw StateError(
        'Pure values require the saved search model; rebuild after changing it.',
      );
    }
  }

  /// Freeze a completed local decision. Its comparison value is kept for
  /// audit; later evaluation of the committed policy cannot replace it.
  void commitWindow(BuildTreeNode node, int horizon) {
    calculateWindow(node, horizon);
    final winner = scoreOurMoveChildren(node, respectCommitment: false);
    if (winner == null || node.valueLower != node.valueUpper) {
      throw StateError('Fast needs a completed lookahead before committing');
    }
    node.committedMoveUci = winner.child.moveUci;
    node.decisionHorizon = horizon;
    node.decisionValue = winner.expectimaxValue;
  }

  /// Evaluate a complete local window before committing a Rolling decision.
  int calculateWindow(BuildTreeNode root, int horizon) =>
      _calculate(root, horizon, fixedPolicy: false);

  int _calculate(BuildTreeNode root, int horizon, {required bool fixedPolicy}) {
    final done = <BuildTreeNode>{};
    final active = <BuildTreeNode>{};
    void visit(BuildTreeNode node) {
      if (done.contains(node)) return;
      _assertValidTerminal(node);
      if (!active.add(node)) {
        throw StateError('History-free cyclic tree: rebuild with Pure search.');
      }
      final resolved = resolveTransposition(node, fenMap);
      if (!identical(node, resolved)) {
        visit(resolved);
        _adoptBackup(node, from: resolved);
      } else {
        final atHorizon = node.historyAware && node.ply >= horizon;
        if (!atHorizon && node.terminalValue == null) {
          for (final c in node.children) {
            visit(c);
          }
        }
        _backupSubtreeDepths(node);
        _backupValue(
          node,
          horizon: horizon,
          atHorizon: atHorizon,
          fixedPolicy: fixedPolicy,
        );
      }
      node.hasExpectimax = true;
      active.remove(node);
      done.add(node);
    }

    visit(root);
    return done.length;
  }

  static void _assertValidTerminal(BuildTreeNode node) {
    final terminal = node.terminalValue;
    if (terminal != null &&
        (!terminal.isFinite || terminal < 0 || terminal > 1)) {
      throw StateError('Invalid terminal utility');
    }
  }

  /// A transposition leaf takes its canonical expansion's backup verbatim.
  static void _adoptBackup(BuildTreeNode node, {required BuildTreeNode from}) {
    node.expectimaxValue = from.expectimaxValue;
    node.valueLower = from.valueLower;
    node.valueUpper = from.valueUpper;
    node.subtreePly = from.subtreePly;
    node.subtreeOppPlies = from.subtreeOppPlies;
  }

  /// Longest path below [node] in plies, and in opponent plies only.
  void _backupSubtreeDepths(BuildTreeNode node) {
    node.subtreePly = 0;
    node.subtreeOppPlies = 0;
    final ours = _isOurTurn(node);
    for (final c in node.children) {
      if (c.subtreePly + 1 > node.subtreePly) {
        node.subtreePly = c.subtreePly + 1;
      }
      final opp = c.subtreeOppPlies + (ours ? 0 : 1);
      if (opp > node.subtreeOppPlies) node.subtreeOppPlies = opp;
    }
  }

  void _backupValue(
    BuildTreeNode node, {
    required int horizon,
    required bool atHorizon,
    required bool fixedPolicy,
  }) {
    final ours = _isOurTurn(node);
    if (node.terminalValue != null ||
        node.children.isEmpty ||
        atHorizon ||
        (fixedPolicy && ours && node.committedMoveUci.isEmpty)) {
      _backupLeaf(node, horizon: horizon);
    } else if (ours) {
      _backupOurNode(node, fixedPolicy: fixedPolicy);
    } else {
      _backupOpponentNode(node);
    }
  }

  /// Terminal value when known, else the engine estimate. Bounds are exact
  /// for terminals and for engine-evaluated legacy or horizon leaves; an
  /// unevaluated frontier leaf keeps the full [0, 1] interval.
  void _backupLeaf(BuildTreeNode node, {required int horizon}) {
    final value = node.terminalValue ?? _engineUtility(node);
    node.expectimaxValue = value;
    final exact =
        node.terminalValue != null ||
        (node.hasEngineEval && (!node.historyAware || node.ply >= horizon));
    node.valueLower = exact ? value : 0;
    node.valueUpper = exact ? value : 1;
  }

  /// Max over the admitted candidates; bounds are the max of theirs.
  void _backupOurNode(BuildTreeNode node, {required bool fixedPolicy}) {
    final candidates = eligibleChildren(node, respectCommitment: fixedPolicy);
    final winner = scoreOurMoveChildren(node, respectCommitment: fixedPolicy)!;
    node.expectimaxValue = winner.expectimaxValue;
    node.valueLower = candidates
        .map((c) => c.valueLower)
        .reduce((a, b) => a > b ? a : b);
    node.valueUpper = candidates
        .map((c) => c.valueUpper)
        .reduce((a, b) => a > b ? a : b);
  }

  /// Policy-weighted sum over the replies. A complete Pure expansion must
  /// carry its whole policy; otherwise the missing mass is valued at the
  /// node's engine estimate and widens the upper bound.
  void _backupOpponentNode(BuildTreeNode node) {
    var mass = 0.0, value = 0.0, lower = 0.0, upper = 0.0;
    for (final c in node.children) {
      final p = c.moveProbability;
      if (!p.isFinite || p < 0 || p > 1) {
        throw StateError('Invalid opponent probability');
      }
      mass += p;
      value += p * c.expectimaxValue;
      lower += p * c.valueLower;
      upper += p * c.valueUpper;
    }
    if (mass > 1 + 1e-9) {
      throw StateError('Opponent probability mass exceeds one: $mass');
    }
    final completePolicy =
        node.historyAware && node.explored && !config.boundedDatabase;
    if (completePolicy && (mass - 1).abs() > 1e-9) {
      throw StateError(
        'Pure opponent expansion must contain its complete policy',
      );
    }
    final missing = completePolicy ? 0.0 : (1 - mass).clamp(0.0, 1.0);
    value += missing * _engineUtility(node);
    node.expectimaxValue = value.clamp(0.0, 1.0);
    node.valueLower = lower.clamp(0.0, 1.0);
    node.valueUpper = (upper + missing).clamp(0.0, 1.0);
  }

  bool _isOurTurn(BuildTreeNode node) =>
      node.isWhiteToMove == config.playAsWhite;

  /// Expected score from the node's own engine eval; neutral when it has
  /// none.
  double _engineUtility(BuildTreeNode node) => node.hasEngineEval
      ? winProbability(node.evalForUs(config.playAsWhite))
      : 0.5;

  /// New Pure trees have already scored every legal move before applying
  /// this constraint. Legacy trees are evaluated only over their saved set.
  List<BuildTreeNode> eligibleChildren(
    BuildTreeNode node, {
    bool respectCommitment = true,
  }) {
    if (respectCommitment && node.committedMoveUci.isNotEmpty) {
      final committed = node.children
          .where((c) => c.moveUci == node.committedMoveUci)
          .toList();
      if (committed.length != 1 || !committed.single.hasExpectimax) {
        throw StateError('Invalid saved Fast commitment');
      }
      return committed;
    }
    final valued = node.children.where((c) => c.hasExpectimax).toList();
    final evaluated = valued.where((c) => c.hasEngineEval).toList();
    if (evaluated.isEmpty) return valued;
    final best = evaluated
        .map((c) => c.evalForUs(config.playAsWhite))
        .reduce((a, b) => a > b ? a : b);
    return evaluated
        .where(
          (c) => c.evalForUs(config.playAsWhite) >= best - config.maxEvalLossCp,
        )
        .toList();
  }

  /// The child selection and backup both pick: highest expectimax value,
  /// then engine eval for us, then UCI, then SAN. Null when no child is
  /// eligible.
  ScoredChild? scoreOurMoveChildren(
    BuildTreeNode node, {
    bool respectCommitment = true,
  }) {
    final candidates = eligibleChildren(
      node,
      respectCommitment: respectCommitment,
    )..sort(_byValueThenEvalThenMove);
    return candidates.isEmpty
        ? null
        : ScoredChild(
            child: candidates.first,
            expectimaxValue: candidates.first.expectimaxValue,
          );
  }

  int _byValueThenEvalThenMove(BuildTreeNode a, BuildTreeNode b) {
    var order = b.expectimaxValue.compareTo(a.expectimaxValue);
    if (order == 0) {
      order = b
          .evalForUs(config.playAsWhite)
          .compareTo(a.evalForUs(config.playAsWhite));
    }
    if (order == 0) order = a.moveUci.compareTo(b.moveUci);
    if (order == 0) order = a.moveSan.compareTo(b.moveSan);
    return order;
  }

  /// Compute trap scores on opponent-move nodes throughout the tree.
  /// Trap score measures how often opponents play suboptimal moves;
  /// see [analyzeTrapScore] for the shared formula.
  void computeTrapScores(BuildTreeNode root) {
    _trapScoreRecursive(root, pRefForElo(config.maiaElo));
  }

  void _trapScoreRecursive(BuildTreeNode node, double findabilityPRef) {
    for (final child in node.children) {
      _trapScoreRecursive(child, findabilityPRef);
    }
    if (_isOurTurn(node)) return;

    final analysis = analyzeTrapScore(node, findabilityPRef: findabilityPRef);
    if (analysis == null) return;
    node.trapScore = analysis.trapScore;
  }
}

/// The child [ExpectimaxCalculator.scoreOurMoveChildren] picked and the
/// value it was picked for.
class ScoredChild {
  final BuildTreeNode child;
  final double expectimaxValue;

  const ScoredChild({required this.child, required this.expectimaxValue});
}
