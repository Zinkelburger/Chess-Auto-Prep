import 'dart:convert';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:flutter_test/flutter_test.dart';

ReadingPlace? decoded(Map<String, Object?> extra) =>
    ReadingPlace.decode(jsonEncode({'gameIndex': 0, 'gameKey': 'k', ...extra}));

List<int> pathOf(Map<String, Object?> extra) => decoded(extra)!.path.indexes;

ChapterLine game(String headers, [String moves = '1. e4 *']) => parseChapter(
  name: 'Games',
  text: '[Event "E"]\n$headers\n\n$moves\n',
).lines.single;

void main() {
  group('a saved place read back', () {
    test('takes a ply count from nothing up to ten thousand', () {
      expect(pathOf({'ply': -5}), isEmpty);
      expect(pathOf({'ply': 20000}), hasLength(10000));
    });

    test('takes a path of up to ten thousand steps, each a place from 0', () {
      expect(
        pathOf({
          'v2Path': [0, 2],
        }),
        [0, 2],
      );
      final longest = [1, ...List.filled(9999, 0)];
      expect(pathOf({'v2Path': longest}).first, 1);
      expect(
        pathOf({
          'v2Path': [1, ...List.filled(10000, 0)],
        }),
        isEmpty,
        reason: 'too long: the ply count is used instead',
      );
      expect(
        pathOf({
          'v2Path': ['x'],
          'ply': 2,
        }),
        [0, 0],
      );
    });

    test('keeps at most a hundred filter rules', () {
      final place = decoded({
        'v2Filter': {
          'rules': [
            for (var i = 0; i < 101; i++)
              {'field': 'Event', 'rule': 'contains', 'value': '$i'},
          ],
        },
      })!;
      expect(place.filter.rules, hasLength(100));
    });
  });

  test('a place whose game has changed is found by its key', () {
    final games = [game('[White "A"]'), game('[White "B"]')];
    final place = ReadingPlace.decode(
      jsonEncode({'gameIndex': 0, 'gameKey': readingGameKey(games[1])}),
    )!;
    expect(place.locate(games), 1);
  });

  test('a saved filter keeps whether any rule is enough, and a position only '
      'when it is one', () {
    const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final kept = decoded({
      'v2Filter': {'any': true, 'rules': <Object>[], 'position': start},
    })!;
    expect(kept.filter.any, isTrue);
    expect(kept.filter.position?.value, start);
    final broken = decoded({
      'v2Filter': {'rules': <Object>[], 'position': 'not a position'},
    })!;
    expect(broken.filter.any, isFalse);
    expect(broken.filter.position, isNull);
  });

  test('a place past the end of the file is found by its key', () {
    final games = [game('[White "A"]'), game('[White "B"]')];
    final place = ReadingPlace.decode(
      jsonEncode({'gameIndex': 2, 'gameKey': readingGameKey(games[1])}),
    )!;
    expect(place.locate(games), 1);
  });

  group('a game key', () {
    test('is the GameId when the game has one, never an empty one', () {
      expect(readingGameKey(game('[GameId "abc"]')), 'abc');
      expect(readingGameKey(game('[GameId ""]')), isNotEmpty);
    });

    test('is a chess.com game page only on chess.com', () {
      const page = 'https://www.chess.com/game/live/123';
      expect(readingGameKey(game('[Site "$page"]')), page);
      expect(
        readingGameKey(game('[Site "https://example.com/game/live/123"]')),
        isNot(page),
      );
    });

    test('follows the main line, whatever variations sit beside it', () {
      expect(
        readingGameKey(game('[White "A"]', '1. e4 (1. d4) e5 2. Nf3 *')),
        readingGameKey(game('[White "A"]', '1. e4 e5 2. Nf3 *')),
      );
    });
  });
}
