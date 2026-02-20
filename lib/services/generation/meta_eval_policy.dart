/// MetaEval move selection: explores each candidate's subtree and picks
/// the one whose propagated MetaEase score is highest.  At opponent
/// nodes, blends local ease with the weighted-future subtree value.
library;

import 'candidate_move.dart';
import 'generation_config.dart';
import 'move_selection_policy.dart';

class MetaEvalPolicy implements MoveSelectionPolicy {
  const MetaEvalPolicy();

  @override
  bool get requiresEngine => true;

  @override
  bool get requiresEase => true;

  @override
  Future<CandidateMove?> selectOurMove({
    required List<CandidateMove> candidates,
    required RepertoireGenerationConfig config,
    required Future<double> Function(CandidateMove candidate) exploreSubtree,
    required bool Function() isCancelled,
  }) async {
    if (candidates.isEmpty) return null;

    double bestMeta = -1e9;
    CandidateMove? selected;

    for (final c in candidates) {
      if (isCancelled()) break;
      final v = await exploreSubtree(c);
      if (v > bestMeta) {
        bestMeta = v;
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
  }) {
    final opponentEase = 1.0 - (localEase ?? 0.5);
    return config.metaAlpha * opponentEase +
        (1.0 - config.metaAlpha) * weightedFuture;
  }
}
