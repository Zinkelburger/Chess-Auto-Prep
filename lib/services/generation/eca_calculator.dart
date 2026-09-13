/// Bellman backups for the declared opponent policy and engine-loss constraint.
/// Values are expected-score proxies; they are not calibrated human win rates.
library;

import '../../models/build_tree_node.dart';
import '../../utils/ease_utils.dart' show winProbability;
import '../../utils/findability.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'trap_score.dart';

class ExpectimaxCalculator {
  final TreeBuildConfig config;
  final FenMap? fenMap;
  ExpectimaxCalculator({required this.config, this.fenMap});

  int calculate(BuildTree tree) {
    if (tree.root.historyAware) {
      final saved = tree.configSnapshot;
      if (((saved['search_algorithm'] == 'rolling') !=
              config.isRollingSearch) ||
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
    return _calculate(
      tree.root,
      config.maxPly,
      fixedPolicy: config.isRollingSearch,
    );
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
      final terminal = node.terminalValue;
      if (terminal != null &&
          (!terminal.isFinite || terminal < 0 || terminal > 1)) {
        throw StateError('Invalid terminal utility');
      }
      if (!active.add(node)) {
        throw StateError('History-free cyclic tree: rebuild with Pure search.');
      }
      final resolved = resolveTransposition(node, fenMap);
      if (!identical(node, resolved)) {
        visit(resolved);
        node.expectimaxValue = resolved.expectimaxValue;
        node.valueLower = resolved.valueLower;
        node.valueUpper = resolved.valueUpper;
        node.subtreePly = resolved.subtreePly;
        node.subtreeOppPlies = resolved.subtreeOppPlies;
      } else {
        final atHorizon = node.historyAware && node.ply >= horizon;
        if (!atHorizon && node.terminalValue == null) {
          for (final c in node.children) {
            visit(c);
          }
        }
        node.subtreePly = 0;
        node.subtreeOppPlies = 0;
        final ours = node.isWhiteToMove == config.playAsWhite;
        for (final c in node.children) {
          if (c.subtreePly + 1 > node.subtreePly) {
            node.subtreePly = c.subtreePly + 1;
          }
          final opp = c.subtreeOppPlies + (ours ? 0 : 1);
          if (opp > node.subtreeOppPlies) node.subtreeOppPlies = opp;
        }
        if (node.terminalValue != null ||
            node.children.isEmpty ||
            atHorizon ||
            (fixedPolicy && ours && node.committedMoveUci.isEmpty)) {
          final value =
              node.terminalValue ??
              (node.hasEngineEval
                  ? winProbability(node.evalForUs(config.playAsWhite))
                  : 0.5);
          node.expectimaxValue = value;
          final exact =
              node.terminalValue != null ||
              (node.hasEngineEval &&
                  (!node.historyAware || node.ply >= horizon));
          node.valueLower = exact ? value : 0;
          node.valueUpper = exact ? value : 1;
        } else if (ours) {
          final candidates = eligibleChildren(
            node,
            respectCommitment: fixedPolicy,
          );
          final winner = scoreOurMoveChildren(
            node,
            respectCommitment: fixedPolicy,
          )!;
          node.expectimaxValue = winner.expectimaxValue;
          node.valueLower = candidates
              .map((c) => c.valueLower)
              .reduce((a, b) => a > b ? a : b);
          node.valueUpper = candidates
              .map((c) => c.valueUpper)
              .reduce((a, b) => a > b ? a : b);
        } else {
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
          if (node.historyAware &&
              node.explored &&
              !config.boundedDatabase &&
              (mass - 1).abs() > 1e-9) {
            throw StateError(
              'Pure opponent expansion must contain its complete policy',
            );
          }
          final missing =
              node.historyAware && node.explored && !config.boundedDatabase
              ? 0.0
              : (1 - mass).clamp(0.0, 1.0);
          value +=
              missing *
              (node.hasEngineEval
                  ? winProbability(node.evalForUs(config.playAsWhite))
                  : 0.5);
          node.expectimaxValue = value.clamp(0.0, 1.0);
          node.valueLower = lower.clamp(0.0, 1.0);
          node.valueUpper = (upper + missing).clamp(0.0, 1.0);
        }
      }
      node.hasExpectimax = true;
      active.remove(node);
      done.add(node);
    }

    visit(root);
    return done.length;
  }

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

  ScoredChild? scoreOurMoveChildren(
    BuildTreeNode node, {
    bool respectCommitment = true,
  }) {
    final candidates =
        eligibleChildren(node, respectCommitment: respectCommitment)
          ..sort((a, b) {
            var order = b.expectimaxValue.compareTo(a.expectimaxValue);
            if (order == 0) {
              order = b
                  .evalForUs(config.playAsWhite)
                  .compareTo(a.evalForUs(config.playAsWhite));
            }
            if (order == 0) order = a.moveUci.compareTo(b.moveUci);
            if (order == 0) order = a.moveSan.compareTo(b.moveSan);
            return order;
          });
    return candidates.isEmpty
        ? null
        : ScoredChild(
            child: candidates.first,
            expectimaxValue: candidates.first.expectimaxValue,
          );
  }

  /// Compute trap scores on opponent-move nodes throughout the tree.
  /// Trap score measures how often opponents play suboptimal moves;
  /// see [analyzeTrapScore] for the shared formula.
  void computeTrapScores(BuildTreeNode root) {
    _trapScoreRecursive(root);
  }

  void _trapScoreRecursive(BuildTreeNode node) {
    for (final child in node.children) {
      _trapScoreRecursive(child);
    }

    final isOurMove = node.isWhiteToMove == config.playAsWhite;
    if (isOurMove) return;

    final analysis = analyzeTrapScore(
      node,
      findabilityPRef: pRefForElo(config.maiaElo),
    );
    if (analysis == null) return;
    node.trapScore = analysis.trapScore;
  }
}

class ScoredChild {
  final BuildTreeNode child;
  final double expectimaxValue;

  const ScoredChild({required this.child, required this.expectimaxValue});
}
