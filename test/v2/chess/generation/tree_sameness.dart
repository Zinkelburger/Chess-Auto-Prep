import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:flutter_test/flutter_test.dart';

/// One move out of a node, whichever kind of node it is.
typedef TreeBranch = ({
  String uci,
  String san,
  double probability,
  SearchNode child,
});

/// Fails unless [actual] is the same tree as [expected]: the same shape, the
/// same positions, the same evaluations, the same values and bounds, the same
/// moves with the same shares, and the same move chosen where we choose.
///
/// Moves are matched by UCI rather than by position in the list, because a
/// file says which moves a node has but not the order a reader must return
/// them in — the old app sorts what it reads. Where the order is part of the
/// answer, at one of our nodes, [OurNode.chosen] is checked directly.
void expectSameTree(
  SearchNode actual,
  SearchNode expected, {
  String where = 'the root',
}) {
  expect(actual.runtimeType, expected.runtimeType, reason: where);
  expect(actual.fen.value, expected.fen.value, reason: where);
  expect(actual.evalForUs.cp, expected.evalForUs.cp, reason: where);
  expect(actual.evaluated, expected.evaluated, reason: where);
  expect(
    actual.valuation.value,
    closeTo(expected.valuation.value, 1e-12),
    reason: where,
  );
  expect(
    actual.valuation.lower,
    closeTo(expected.valuation.lower, 1e-12),
    reason: where,
  );
  expect(
    actual.valuation.upper,
    closeTo(expected.valuation.upper, 1e-12),
    reason: where,
  );
  if (expected is TerminalNode) {
    final mine = actual as TerminalNode;
    expect(mine.kind, expected.kind, reason: where);
    expect(mine.ourTurn, expected.ourTurn, reason: where);
  }
  if (expected is OurNode) {
    expect(
      (actual as OurNode).chosen.move.uci,
      expected.chosen.move.uci,
      reason: where,
    );
  }
  _expectSameBranches(actual, expected, where);
}

void _expectSameBranches(SearchNode actual, SearchNode expected, String where) {
  final mine = {for (final branch in branchesOf(actual)) branch.uci: branch};
  final theirs = {
    for (final branch in branchesOf(expected)) branch.uci: branch,
  };
  expect(mine.keys, unorderedEquals(theirs.keys), reason: where);
  for (final entry in theirs.entries) {
    final branch = mine[entry.key]!;
    final below = '$where → ${entry.key}';
    expect(branch.san, entry.value.san, reason: below);
    expect(
      branch.probability,
      closeTo(entry.value.probability, 1e-12),
      reason: below,
    );
    expectSameTree(branch.child, entry.value.child, where: below);
  }
}

/// The moves out of [node], ours or the opponent's, each with the share the
/// file gives it; our own moves are always certain.
List<TreeBranch> branchesOf(SearchNode node) => switch (node) {
  OurNode(:final candidates) => [
    for (final candidate in candidates)
      (
        uci: candidate.move.uci,
        san: candidate.move.san,
        probability: 1.0,
        child: candidate.child,
      ),
  ],
  OpponentNode(:final replies) => [
    for (final reply in replies)
      (
        uci: reply.move.uci,
        san: reply.move.san,
        probability: reply.probability,
        child: reply.child,
      ),
  ],
  TerminalNode() || HorizonNode() || FrontierNode() => const [],
};
