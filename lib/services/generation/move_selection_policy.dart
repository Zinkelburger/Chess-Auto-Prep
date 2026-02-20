/// Abstract interface for move-selection strategies during generation.
///
/// The DFS in [RepertoireGenerationService] is strategy-agnostic: it
/// builds candidates, filters them, then delegates the final selection
/// and value-aggregation to a [MoveSelectionPolicy].
///
/// Implement this interface to add new generation strategies without
/// touching the DFS traversal code.
library;

import 'candidate_move.dart';
import 'generation_config.dart';

abstract class MoveSelectionPolicy {
  /// Whether this policy needs Stockfish engine workers.
  bool get requiresEngine;

  /// Whether ease should be computed at opponent-move nodes.
  bool get requiresEase;

  /// Select which candidate to play at an our-move node.
  ///
  /// [candidates] have already been evaluated and filtered by the eval
  /// guard window.  [exploreSubtree] runs the full DFS on a candidate's
  /// child position with `emitLines: false` and returns the subtree's
  /// aggregated value (used by strategies that look ahead, like MetaEval).
  Future<CandidateMove?> selectOurMove({
    required List<CandidateMove> candidates,
    required RepertoireGenerationConfig config,
    required Future<double> Function(CandidateMove candidate) exploreSubtree,
    required bool Function() isCancelled,
  });

  /// Aggregate child values at an opponent-move (chance) node.
  ///
  /// [weightedFuture] is the probability-weighted sum of child subtree
  /// values.  [localEase] is the ease at this position if [requiresEase]
  /// is true, otherwise `null`.
  double computeOpponentNodeValue({
    required double weightedFuture,
    required double? localEase,
    required RepertoireGenerationConfig config,
  });
}
