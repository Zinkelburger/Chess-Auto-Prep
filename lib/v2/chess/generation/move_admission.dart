import 'search_node.dart';

/// The moves worth preparing: every one whose fixed-depth evaluation is
/// within [lossLimitCp] centipawns of our best move's.
///
/// The search enumerates *every* legal move at one of our positions,
/// promotions to all four pieces included, evaluates each of them at the same
/// fixed depth, and then throws away only the ones this window rejects.
/// Nothing else narrows our side of the tree: not how often a move is played,
/// not how many lines it would cost, not what the engine ranked it.
///
/// Example: with a 200 centipawn limit, moves scoring +30, −150 and −400 from
/// our side give a best of +30, so +30 and −150 are kept — they lose at most
/// 180 — and −400 is not. The window is plain centipawns, so a forced mate
/// (±10000) admits only the other mates.
///
/// [candidates] must not be empty; a position with no legal move is a
/// terminal, not an empty choice.
List<CandidateMove> admittedMoves(
  List<CandidateMove> candidates, {
  required int lossLimitCp,
}) {
  final best = candidates
      .map((candidate) => candidate.evalForUs.cp)
      .reduce((a, b) => a > b ? a : b);
  return [
    for (final candidate in candidates)
      if (candidate.evalForUs.cp >= best - lossLimitCp) candidate,
  ];
}
