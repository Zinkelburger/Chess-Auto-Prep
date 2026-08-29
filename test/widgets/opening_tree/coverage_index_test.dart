/// Coverage classification for tree rows, indexed once per result.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/widgets/opening_tree/coverage_annotation.dart';

LeafNode _leaf(String fen, LeafCategory category) => LeafNode(
  fen: fen,
  moves: const [],
  gameCount: 1,
  category: category,
  reason: '',
);

void main() {
  test('leaves classify by normalised FEN, shallow beating covered', () {
    final tree = OpeningTree();
    tree.appendLine(['e4', 'e5']);
    tree.appendLine(['e4', 'c5']);
    final e5 = tree.root.children['e4']!.children['e5']!;
    final c5 = tree.root.children['e4']!.children['c5']!;

    // Same position, different move counters: still the same leaf.
    final withCounters = '${e5.fen.split(' ').take(4).join(' ')} 7 9';
    final result = CoverageResult(
      rootFen: tree.root.fen,
      rootMoves: const [],
      rootGameCount: 10,
      targetPercent: 90,
      targetGameCount: 9,
      coveredLeaves: [
        _leaf(withCounters, LeafCategory.covered),
        _leaf(c5.fen, LeafCategory.covered),
      ],
      tooShallowLeaves: [_leaf(withCounters, LeafCategory.tooShallow)],
      tooDeepLeaves: const [],
      unaccountedMoves: const [],
      totalCoveredGames: 0,
      totalShallowGames: 0,
      totalDeepGames: 0,
      totalUnaccountedGames: 0,
    );
    final index = CoverageIndex(result);
    expect(index.statusOf(PositionGroup([e5])), CoverageStatus.tooShallow);
    expect(index.statusOf(PositionGroup([c5])), CoverageStatus.covered);
    expect(index.statusOf(PositionGroup([tree.root.children['e4']!])), isNull);
  });

  test('an unanswered opponent reply from this path marks the row', () {
    final tree = OpeningTree();
    tree.appendLine(['e4', 'e5', 'Nf3']);
    final e5 = tree.root.children['e4']!.children['e5']!;
    final result = CoverageResult(
      rootFen: tree.root.fen,
      rootMoves: const [],
      rootGameCount: 10,
      targetPercent: 90,
      targetGameCount: 9,
      coveredLeaves: const [],
      tooShallowLeaves: const [],
      tooDeepLeaves: const [],
      unaccountedMoves: [
        UnaccountedMove(
          parentMoves: const ['e4', 'e5'],
          move: 'Bc4',
          gameCount: 3,
          probability: 0.3,
          source: 'lichess',
        ),
      ],
      totalCoveredGames: 0,
      totalShallowGames: 0,
      totalDeepGames: 0,
      totalUnaccountedGames: 3,
    );
    final index = CoverageIndex(result);
    expect(index.statusOf(PositionGroup([e5])), CoverageStatus.unaccounted);

    // Once the repertoire answers it, the row is clean.
    tree.appendLine(['e4', 'e5', 'Bc4']);
    expect(index.statusOf(PositionGroup([e5])), isNull);
    expect(
      resolveCoverageStatus(
        group: PositionGroup([e5]),
        tree: tree,
        coverageResult: result,
      ),
      isNull,
    );
  });
}
