import 'package:chess_auto_prep/chess/pgn/chapter_grouping.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// One unfinished game per entry, with these White, Black and Event tags;
/// null leaves a header as PGN's unknown `?`.
List<List<PgnHeader>> games(List<(String?, String?, String?)> tags) => [
  for (final (white, black, event) in tags)
    [
      PgnTag('Event', event ?? '?'),
      PgnTag('White', white ?? '?'),
      PgnTag('Black', black ?? '?'),
      const PgnTag('Result', '*'),
    ],
];

void main() {
  test(
    'the chapter header is the one whose titles come in the fewest runs',
    () {
      // White changes on every game; Black lists its two titles together.
      final grouping = groupChapters(
        games([
          ('A', 'x', 'E'),
          ('B', 'x', 'E'),
          ('A', 'y', 'E'),
          ('B', 'y', 'E'),
        ]),
      );
      expect(grouping.chapterKey, 'Black');
      expect(grouping.titleKey, 'White');
      expect(grouping.titles, ['x', 'x', 'y', 'y']);
    },
  );

  test('an untitled game at the start is a run of its own, and White wins '
      'a tie', () {
    final grouping = groupChapters(
      games([
        ('A', null, 'E'),
        ('A', 'x', 'E'),
        ('B', 'x', 'E'),
        ('B', 'y', 'E'),
        ('C', 'y', 'E'),
      ]),
    );
    expect(grouping.chapterKey, 'White');
  });

  test('half the games titled is enough, fewer is not', () {
    final half = groupChapters(
      games([
        ('A', null, 'E'),
        ('A', null, 'E'),
        ('B', null, 'E'),
        (null, null, 'E'),
        (null, null, 'E'),
        (null, null, 'E'),
      ]),
    );
    expect(half.chapterKey, 'White');
    final fewer = groupChapters(
      games([
        ('A', null, 'E'),
        ('B', null, 'E'),
        ('B', null, 'E'),
        (null, null, 'E'),
        (null, null, 'E'),
        (null, null, 'E'),
        (null, null, 'E'),
      ]),
    );
    expect(fewer.hasChapters, isFalse);
    expect(fewer.titles, everyElement(defaultChapterTitle));
  });

  test('a course titled by Event names its lines in White', () {
    final grouping = groupChapters(
      games([
        ('p', null, 'One'),
        ('q', null, 'One'),
        ('r', null, 'Two'),
        ('s', null, 'Two'),
      ]),
    );
    expect(grouping.chapterKey, 'Event');
    expect(grouping.titleKey, 'White');
  });
}
