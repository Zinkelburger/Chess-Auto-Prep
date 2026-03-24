/// ECA (Expected Centipawn Advantage) move selection policy.
///
/// Ported from the C tree_builder's ECA algorithm.  At each opponent node
/// the policy computes the local expected centipawn loss — how many
/// centipawns the opponent is expected to lose due to suboptimal play —
/// and accumulates it depth-discounted through the tree.  At our-move
/// nodes we pick the candidate whose subtree yields the highest
/// accumulated ECA.
///
/// Higher ECA = the opponent is expected to blunder more centipawns in
/// that line, making it a better repertoire choice.
library;

import 'candidate_move.dart';
import 'generation_config.dart';
import 'move_selection_policy.dart';

class EcaPolicy implements MoveSelectionPolicy {
  const EcaPolicy();

  @override
  bool get requiresEngine => true;

  @override
  bool get requiresEase => false;

  @override
  Future<CandidateMove?> selectOurMove({
    required List<CandidateMove> candidates,
    required RepertoireGenerationConfig config,
    required Future<double> Function(CandidateMove candidate) exploreSubtree,
    required bool Function() isCancelled,
  }) async {
    if (candidates.isEmpty) return null;

    double bestEca = -1e9;
    CandidateMove? selected;

    for (final c in candidates) {
      if (isCancelled()) break;
      final eca = await exploreSubtree(c);
      if (eca > bestEca) {
        bestEca = eca;
        selected = c;
      }
    }

    return selected;
  }

  @override
  double computeOpponentNodeValue({
    required double weightedFuture,
    required double? localEase,
    required RepertoireGenerationConfig config,
  }) =>
      weightedFuture;
}
