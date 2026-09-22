import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/training/training_line.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  List<TrainingLine> linesOf(String text) => trainingLines(
    parseChapter(name: 'Main', text: text),
    source: '/r/KID/Main.pgn',
  );

  group('line ids are the old app\'s', () {
    test('a game with no id header is named by its moves and place', () {
      // base64url("<moves>|<index>") without padding, cut to 22 characters.
      expect(
        [for (final l in linesOf(blackChapter)) l.key.id],
        [
          'line_YzUgTmYzIGQ2IGQ0IGN4ZD',
          'line_YzUgTmMzIE5jNnwx',
          'line_ZDQgZDV8Mg',
        ],
      );
    });

    test('a game with an id header keeps it', () {
      expect(linesOf(whiteChapter).first.key.id, 'line_MS4gZDQgZDUgMi4gYzQ');
    });

    test('a second game claiming a taken id gets the hash of its moves', () {
      const twice = '''
[Event "One"]
[LineID "x"]

1. e4 *

[Event "Two"]
[LineID "x"]

1. e4 *
''';
      // sha256("e4|1"), cut to 22 characters.
      expect(
        [for (final l in linesOf(twice)) l.key.id],
        ['x', 'line_629324b526e8081092da85'],
      );
    });

    test('a game with no moves keeps its place for the games after it', () {
      const gap = '''
[Event "Empty"]

*

[Event "One"]

1. e4 *
''';
      final lines = linesOf(gap);
      expect(lines.single.key.id, 'line_ZTR8MQ');
      expect(lines.single.game, 1);
    });

    test('castling written with zeros is named as with letters', () {
      // The old app's parser reads `0-0` as `O-O` before naming the line.
      const zeros = '''
[Event "Castles"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. 0-0 *
''';
      final line = linesOf(zeros).single;
      expect(
        line.key.id,
        linesOf(zeros.replaceAll('0-0', 'O-O')).single.key.id,
      );
    });
  });

  test('every line is keyed under the chapter file and named', () {
    final lines = linesOf(blackChapter);
    expect(lines.map((l) => l.key.source).toSet(), {'/r/KID/Main.pgn'});
    expect(lines.map((l) => l.name), [
      'Test: Repertoire for Black',
      'Test: Repertoire for Black',
      'Elsewhere',
    ]);
    expect(lines.first.chapter, 'Main');
  });

  test('the user answers only for the chapter side', () {
    final line = linesOf(blackChapter).first;
    expect(line.side, Side.black);
    // 1... c5 2. Nf3 d6 3. d4 cxd4 from a position with Black to move.
    expect(
      [for (var i = 0; i < 5; i++) line.isYours(i)],
      [true, false, true, false, true],
    );
    expect(line.yourMoves, 3);
    expect(line.fenBefore(0), line.start);
    expect(line.fenBefore(2), line.moves[1].fen);
  });

  test('a finished game or a model game is read, not drilled', () {
    const games = '''
[Event "Mate"]
[Result "1-0"]

1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0

[Event "Model"]
[Result "*"]
[ModelGameWhite "Fischer"]

1. e4 *

[Event "Line"]
[Result "*"]

1. d4 *
''';
    expect([for (final l in linesOf(games)) l.modelGame], [true, true, false]);
  });
}
