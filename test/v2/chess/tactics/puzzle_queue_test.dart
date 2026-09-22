import 'dart:math';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/tactics_fixture.dart';

void main() {
  List<Puzzle> read(String text) =>
      puzzlesOf(parseChapter(name: 'Default', text: text, game: 0).lines);
  final puzzles = read(tacticsSet);

  List<int> queued(PuzzleFilter filter, [List<Puzzle>? from]) => [
    for (final p in queueOf(from ?? puzzles, filter, today: tacticsToday))
      p.index,
  ];

  test('the default queue: blunders, mistakes and custom puzzles from the '
      'last fortnight, newest game first', () {
    // #2 is an inaccuracy and #4 a month old; the custom puzzle has no date,
    // which passes the window and sorts last.
    expect(queued(PuzzleFilter.defaults), [1, 0, 3]);
  });

  test('the window counts today as the first day and can be switched off', () {
    const fortnight = PuzzleFilter();
    expect(queued(fortnight.copyWith(days: () => 3)), [1, 0, 3]);
    expect(queued(fortnight.copyWith(days: () => 2)), [1, 3]);
    expect(queued(fortnight.copyWith(days: () => null)), [1, 0, 4, 3]);
  });

  test('each mistake kind can be taken in or left out', () {
    final all = PuzzleFilter(kinds: MistakeKind.values.toSet());
    expect(queued(all), [1, 0, 2, 3]);
    expect(queued(const PuzzleFilter(kinds: {MistakeKind.inaccuracy})), [2]);
  });

  test('one-star puzzles are hidden until asked for, and reviewed ones on '
      'request', () {
    final rated = read(
      tacticsSet.replaceFirst(
        '[FlawTags',
        '[ReviewCount "1"]\n[SuccessCount "1"]\n[StarRating "1"]\n[FlawTags',
      ),
    );
    expect(queued(PuzzleFilter.defaults, rated), [1, 3]);
    expect(queued(const PuzzleFilter(hideOneStar: false), rated), [1, 0, 3]);
    expect(
      queued(
        const PuzzleFilter(hideOneStar: false, unreviewedOnly: true),
        rated,
      ),
      [1, 3],
    );
  });

  test('least reviewed and worst success keep file order among equals', () {
    final tried = read(
      tacticsSet.replaceFirst(
        '[OpponentBestResponse "d4"]',
        '[OpponentBestResponse "d4"]\n[ReviewCount "2"]\n[SuccessCount "2"]',
      ),
    );
    expect(
      queued(const PuzzleFilter(order: PuzzleOrder.leastReviewed), tried),
      [0, 3, 1],
    );
    expect(queued(const PuzzleFilter(order: PuzzleOrder.worstSuccess), tried), [
      0,
      3,
      1,
    ]);
  });

  test('grouping by game plays one game\'s puzzles together, earliest move '
      'first', () {
    // Two puzzles from one game, move 10 listed before move 4, and another
    // game between them in newest order.
    String game(int move, String date, String id) =>
        '''
[Event "x"]
[White "Me"]
[Black "B"]
[Date "$date"]
[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 $move"]
[SetUp "1"]
[GameId "$id"]
[UserMove "a3"]
[MistakeType "??"]

$move. e4 *
''';
    final set = read(
      [
        game(10, '2026.09.21', 'one'),
        game(7, '2026.09.21', 'two'),
        game(4, '2026.09.21', 'one'),
      ].join('\n'),
    );
    expect(queued(PuzzleFilter.defaults, set), [2, 0, 1]);
    expect(queued(const PuzzleFilter(groupByGame: false), set), [0, 1, 2]);
  });

  test('random order is a shuffle of the same puzzles', () {
    final shuffled = queueOf(
      puzzles,
      const PuzzleFilter(order: PuzzleOrder.random, groupByGame: false),
      today: tacticsToday,
      random: Random(1),
    );
    expect({for (final p in shuffled) p.index}, {0, 1, 3});
  });

  test('the filter is kept as JSON, every date as a written null', () {
    final chosen = PuzzleFilter(
      order: PuzzleOrder.worstSuccess,
      groupByGame: false,
      kinds: {MistakeKind.inaccuracy},
      unreviewedOnly: true,
      hideOneStar: false,
      days: null,
    );
    expect(PuzzleFilter.fromJson(chosen.toJson()), chosen);
    expect(PuzzleFilter.fromJson(const {'order': 'random'}).days, 14);
    expect(PuzzleFilter.fromJson('nonsense'), PuzzleFilter.defaults);
  });
}
