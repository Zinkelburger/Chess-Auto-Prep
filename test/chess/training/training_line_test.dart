import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  List<TrainingLine> linesOf(String text) => trainingLines(
    parseChapter(name: 'Main', text: text),
    source: '/r/KID/Main.pgn',
  );

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
    expect(line.key.id, linesOf(zeros.replaceAll('0-0', 'O-O')).single.key.id);
  });

  test('a game with an illegal move trains only the moves before it', () {
    const typo = '''
[Event "Typo"]

1. e4 e5 2. Nf3 Nc6 3. Bb4 a6 4. Bc4 Nf6 *
''';
    final line = linesOf(typo).single;
    expect(line.moves.map((m) => m.san), ['e4', 'e5', 'Nf3', 'Nc6']);
    // It is trained under the id the old app gives it, which hashes every
    // move token of the main line.
    expect(line.key.id, 'line_ZTQgZTUgTmYzIE5jNiBCYj');
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

  group('quiz markers', () {
    const marked = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 { [%tstart] } Nc6 3. Bb5 { Pin it. [%tend] } a6 4. Ba4 *
''';

    test('narrow what is asked to the marked moves', () {
      final line = linesOf(marked).single;
      expect((line.quizStart, line.quizEnd), (2, 5));
      expect(line.yourMoves, 2);
      expect(line.isYours(0), isFalse, reason: '1.e4 plays itself');
      expect(line.isYours(2), isTrue);
      expect(line.isYours(6), isFalse, reason: '4.Ba4 is after the end');
    });

    test('an end marked before the start is not taken', () {
      final line = linesOf(
        marked
            .replaceFirst('{ [%tstart] }', '{ [%tend] }')
            .replaceFirst('Pin it. [%tend]', '[%tstart]'),
      ).single;
      expect((line.quizStart, line.quizEnd), (4, line.moves.length));
    });

    test('a line without markers asks from the start to the end', () {
      final line = linesOf(whiteChapter).first;
      expect((line.quizStart, line.quizEnd), (0, line.moves.length));
    });
  });

  test('a study read whole trains each chapter from its own side, and '
      'needs no side question', () {
    String chapter(String name, String side, String moves) =>
        '[Event "Prep – Club Open: $name"]\n[Result "*"]\n'
        '[Orientation "$side"]\n\n$moves *\n';
    final text =
        '${chapter('Jane · As White', 'white', '1. e4 c5')}\n'
        '${chapter('Bob · As Black', 'black', '1. d4 Nf6')}';
    final whole = parseChapter(name: 'Prep', text: text);
    expect(whole.sideStated, isTrue);
    expect([for (final l in linesOf(text)) l.side], [Side.white, Side.black]);
    // The same games under a `// Color:` line are one repertoire.
    expect(
      [for (final l in linesOf('// Color: Black\n$text')) l.side],
      [Side.black, Side.black],
    );
  });
}
