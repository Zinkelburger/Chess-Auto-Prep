import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/tactics_fixture.dart';

void main() {
  List<Puzzle> read(String text) =>
      puzzlesOf(parseChapter(name: 'Default', text: text, game: 0).lines);
  final puzzles = read(tacticsSet);

  // The tests below were written against a fortnight's window, which
  // keeps the month-old #4 out of what they are about.
  const fortnight = PuzzleFilter(days: 14);

  List<int> queued(PuzzleFilter filter, [List<Puzzle>? from]) => [
    for (final p in queueOf(from ?? puzzles, filter, today: tacticsToday))
      p.index,
  ];

  test('the default queue: blunders, mistakes and custom puzzles of every '
      'date, newest game first', () {
    // #2 is an inaccuracy; #4 is a month old and still in, so an old set
    // does not open empty; the custom puzzle has no date and sorts last.
    expect(queued(PuzzleFilter.defaults), [1, 0, 4, 3]);
  });

  test('the window counts today as the first day and can be switched off', () {
    expect(queued(fortnight.copyWith(days: () => 3)), [1, 0, 3]);
    expect(queued(fortnight.copyWith(days: () => 2)), [1, 3]);
    expect(queued(fortnight.copyWith(days: () => null)), [1, 0, 4, 3]);
  });

  test('each mistake kind can be taken in or left out', () {
    final all = PuzzleFilter(days: 14, kinds: MistakeKind.values.toSet());
    expect(queued(all), [1, 0, 2, 3]);
    expect(
      queued(const PuzzleFilter(days: 14, kinds: {MistakeKind.inaccuracy})),
      [2],
    );
  });

  test('one-star puzzles are hidden until asked for, and reviewed ones on '
      'request', () {
    final rated = read(
      tacticsSet.replaceFirst(
        '[FlawTags',
        '[ReviewCount "1"]\n[SuccessCount "1"]\n[StarRating "1"]\n[FlawTags',
      ),
    );
    expect(queued(fortnight, rated), [1, 3]);
    expect(queued(const PuzzleFilter(days: 14, hideOneStar: false), rated), [
      1,
      0,
      3,
    ]);
    expect(
      queued(
        const PuzzleFilter(days: 14, hideOneStar: false, unreviewedOnly: true),
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
      queued(
        const PuzzleFilter(days: 14, order: PuzzleOrder.leastReviewed),
        tried,
      ),
      [0, 3, 1],
    );
    expect(
      queued(
        const PuzzleFilter(days: 14, order: PuzzleOrder.worstSuccess),
        tried,
      ),
      [0, 3, 1],
    );
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
    expect(queued(fortnight, set), [2, 0, 1]);
    expect(queued(const PuzzleFilter(days: 14, groupByGame: false), set), [
      0,
      1,
      2,
    ]);
  });

  test('random order is a shuffle of the same puzzles, which one seed keeps '
      'however the puzzles\' headers change', () {
    const random = PuzzleFilter(
      days: 14,
      order: PuzzleOrder.random,
      groupByGame: false,
    );
    List<int> shuffled(List<Puzzle> from) => [
      for (final p in queueOf(from, random, today: tacticsToday, seed: 7))
        p.index,
    ];
    expect(shuffled(puzzles).toSet(), {0, 1, 3});
    // The set read again after an attempt was written into it.
    final tried = read(
      tacticsSet.replaceFirst(
        '[OpponentBestResponse "d4"]',
        '[OpponentBestResponse "d4"]\n[ReviewCount "1"]\n[SuccessCount "1"]',
      ),
    );
    expect(shuffled(tried), shuffled(puzzles));
  });

  test('newest first puts a date the game does not know after the ones it '
      'could be', () {
    String game(String date) =>
        '''
[Event "x"]
[Date "$date"]
[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]
[SetUp "1"]
[UserMove "a3"]
[MistakeType "??"]

1. e4 *
''';
    final set = read(
      [
        game('????.??.??'),
        game('2026.09.??'),
        game('2026.09.02'),
        game('2026.08.30'),
      ].join('\n'),
    );
    expect(queued(const PuzzleFilter(groupByGame: false), set), [2, 1, 3, 0]);
  });

  test('the filter is kept as JSON, every date as a written null', () {
    const chosen = PuzzleFilter(
      order: PuzzleOrder.worstSuccess,
      groupByGame: false,
      kinds: {MistakeKind.inaccuracy},
      unreviewedOnly: true,
      hideOneStar: false,
      days: null,
    );
    expect(PuzzleFilter.fromJson(chosen.toJson()), chosen);
    expect(PuzzleFilter.fromJson(const {'order': 'random'}).days, isNull);
    expect(PuzzleFilter.fromJson('nonsense'), PuzzleFilter.defaults);
  });
}
