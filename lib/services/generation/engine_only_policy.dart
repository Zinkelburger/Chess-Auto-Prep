/// Greedy best-eval move selection: picks the candidate with the
/// highest engine evaluation for our side.  Ignores subtree lookahead.
library;

import 'candidate_move.dart';
import 'generation_config.dart';
import 'move_selection_policy.dart';

class EngineOnlyPolicy implements MoveSelectionPolicy {
  const EngineOnlyPolicy();

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
    return candidates.reduce((a, b) {
      final aEval = config.toOurPerspective(a.evalWhiteCp);
      final bEval = config.toOurPerspective(b.evalWhiteCp);
      return aEval >= bEval ? a : b;
    });
  }

  @override
  double computeOpponentNodeValue({
    required double weightedFuture,
    required double? localEase,
    required RepertoireGenerationConfig config,
  }) =>
      weightedFuture;
}
