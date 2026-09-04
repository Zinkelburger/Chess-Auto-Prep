/// A coverage run end to end, over a small White repertoire against a fake
/// master book.
///
/// The point of these is that the figures are *real*: before the book was
/// wired in, the whole traversal ran and reported "0.0% covered, 0 shallow,
/// 0 unaccounted" for a repertoire of any size, because the only source of
/// game counts returned null. Every expectation below would read 0 under that
/// version.
library;

import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart'
    show BookMove;
import 'package:chess_auto_prep/utils/chess_utils.dart' show fenAfterMoves;
import 'package:chess_auto_prep/utils/fen_utils.dart' show normalizeFen;
import 'package:flutter_test/flutter_test.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

BookMove _m(String uci, int games) => BookMove(
  uci: uci,
  games: games,
  whiteWins: games ~/ 3,
  draws: games ~/ 3,
  blackWins: games - 2 * (games ~/ 3),
  averageElo: 2500,
  maxElo: 2700,
  lastYear: 2026,
  topGameId: 0,
  recentGameId: 0,
  topClassicalGameId: 0,
);

/// A book keyed by the SAN path that reaches the position, so the fixtures
/// read as openings rather than as FEN blobs.
CoverageService _serviceFor(Map<String, List<BookMove>> byPath) {
  final byFen = <String, List<BookMove>>{
    for (final e in byPath.entries)
      normalizeFen(
        fenAfterMoves(_start, e.key.isEmpty ? const [] : e.key.split(' '), 99),
      ): e.value,
  };
  return CoverageService(
    masterBook: (fen) => byFen[normalizeFen(fen)] ?? const [],
  );
}

void main() {
  test('the root is our forced prefix, and the figures are real', () async {
    // Book: after 1.e4 Black plays only 1...e5, we answer 2.Nf3, and by then
    // the line has thinned below the 95% target — a line that is deep enough.
    final service = _serviceFor({
      '': [_m('e2e4', 1000)],
      'e4': [_m('e7e5', 1000)],
      'e4 e5': [_m('g1f3', 1000)],
      'e4 e5 Nf3': [_m('b8c6', 50)],
    });

    final tree = OpeningTree()..appendLine(['e4', 'e5', 'Nf3']);

    final result = await service.analyzeOpeningTree(
      tree,
      targetPercent: 95,
      isWhiteRepertoire: true,
    );

    // 1.e4 is ours to choose, so it becomes the root and sets the
    // denominator. 1...e5 is Black's and must NOT be swallowed.
    expect(result.rootMoves, ['e4']);
    expect(result.rootGameCount, 1000);
    expect(result.targetGameCount, 950);

    expect(result.unaccountedMoves, isEmpty);
    expect(result.tooShallowLeaves, isEmpty);
    expect(result.coveredLeaves.single.moves, ['e5', 'Nf3']);
    expect(result.coveredLeaves.single.gameCount, 50);
    expect(
      result.coveragePercent,
      greaterThan(0),
      reason: 'the whole point: the figures are no longer identically zero',
    );
  });

  test('a line the book still pours games through is too shallow', () async {
    // Same shape, but 1000 games continue past our last move: the file stops
    // too early there.
    final service = _serviceFor({
      '': [_m('e2e4', 1000)],
      'e4': [_m('e7e5', 1000)],
      'e4 e5': [_m('g1f3', 1000)],
      'e4 e5 Nf3': [_m('b8c6', 1000)],
    });

    final tree = OpeningTree()..appendLine(['e4', 'e5', 'Nf3']);

    final result = await service.analyzeOpeningTree(
      tree,
      targetPercent: 95,
      isWhiteRepertoire: true,
    );

    expect(result.coveredLeaves, isEmpty);
    expect(result.tooShallowLeaves.single.moves, ['e5', 'Nf3']);
    expect(result.tooShallowLeaves.single.gameCount, 1000);
  });

  test('a Black reply the file has no answer to is unaccounted', () async {
    // Black plays 1...e5 (700) and 1...c5 (300); the file only answers 1...e5.
    final service = _serviceFor({
      '': [_m('e2e4', 1000)],
      'e4': [_m('e7e5', 700), _m('c7c5', 300)],
      'e4 e5': [_m('g1f3', 700)],
    });

    final tree = OpeningTree()..appendLine(['e4', 'e5', 'Nf3']);

    final result = await service.analyzeOpeningTree(
      tree,
      targetPercent: 95,
      isWhiteRepertoire: true,
    );

    expect(result.rootGameCount, 1000);
    expect(result.unaccountedMoves.map((m) => m.move), contains('c5'));

    final sicilian = result.unaccountedMoves.firstWhere((m) => m.move == 'c5');
    expect(sicilian.gameCount, 300);
    expect(sicilian.source, 'masters');
    expect(sicilian.probability, closeTo(0.3, 0.001));
  });

  test('the biggest gap is the most played missing reply', () async {
    final service = _serviceFor({
      '': [_m('e2e4', 1000)],
      'e4': [_m('e7e5', 500), _m('c7c5', 400), _m('e7e6', 100)],
      'e4 e5': [_m('g1f3', 500)],
    });

    final tree = OpeningTree()..appendLine(['e4', 'e5', 'Nf3']);

    final result = await service.analyzeOpeningTree(
      tree,
      targetPercent: 95,
      isWhiteRepertoire: true,
    );

    expect(result.findBiggestGap(), ['c5']);
  });

  test('our own moves are never reported as gaps', () async {
    // 2.Nf3 and 2.Bc4 are both in the book, but they are White's choice —
    // a repertoire is allowed to pick one.
    final service = _serviceFor({
      '': [_m('e2e4', 100)],
      'e4': [_m('e7e5', 100)],
      'e4 e5': [_m('g1f3', 60), _m('f1c4', 40)],
    });

    final tree = OpeningTree()..appendLine(['e4', 'e5', 'Nf3']);

    final result = await service.analyzeOpeningTree(
      tree,
      targetPercent: 95,
      isWhiteRepertoire: true,
    );

    expect(
      result.unaccountedMoves.map((m) => m.move),
      isNot(contains('Bc4')),
      reason: 'the side to move at that node is us, not the opponent',
    );
  });

  test('a line the book runs out of counts as covered, not as a gap', () async {
    final service = _serviceFor({
      '': [_m('e2e4', 100)],
      'e4': [_m('e7e5', 100)],
      // Nothing after 1.e4 e5: the book ends here.
    });

    final tree = OpeningTree()..appendLine(['e4', 'e5', 'Nf3']);

    final result = await service.analyzeOpeningTree(
      tree,
      targetPercent: 95,
      isWhiteRepertoire: true,
    );

    expect(result.unaccountedMoves, isEmpty);
    expect(result.tooShallowLeaves, isEmpty);
  });
}
