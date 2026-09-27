import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/comment_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/move_text.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

String movesOf(Chapter chapter) => writeMoveText(chapter.tree, terminator: '*');

/// The chapter written out and read back, which is what the old app and the
/// next session see.
Chapter reread(Chapter chapter) =>
    parseChapter(name: chapter.name, text: writeChapter(chapter));

/// The chapter the move landed in; the cast fails the test when the move
/// was rejected.
Chapter added(Chapter chapter, NodePath at, String uci) =>
    (addMove(chapter, at: at, uci: uci) as MoveAdded).chapter;

/// The chapter the comment landed in; the cast fails the test when the
/// chapter refused the edit.
Chapter commented(
  Chapter chapter, {
  required NodePath at,
  required String? text,
}) => (setComment(chapter, at: at, text: text) as CommentWritten).chapter;

Chapter white() => parseChapter(name: 'Gambit', text: whiteChapter);

Chapter black() => parseChapter(name: 'Sicilian', text: blackChapter);

void main() {
  test('a comment on a shared move with no comment yet goes in one game', () {
    final before = white();
    // 1. d4 d5, played by the first two games but not the third, and
    // commented in neither.
    final after = commented(
      before,
      at: NodePath.of([0, 0]),
      text: 'Symmetrical',
    );
    expect(after.lines[0].text, contains('d5 {Symmetrical}'));
    expect(after.lines[1].text, before.lines[1].text);
    expect(after.lines[2].text, before.lines[2].text);
    final d5 = reread(after).tree.children.single.children.first;
    expect(d5.comment, 'Symmetrical');
  });

  test('a comment on a move two games comment goes into both of them', () {
    const file =
        '[Event "A"]\n[Result "*"]\n\n1. d4 d5 {first} 2. c4 *\n\n'
        '[Event "B"]\n[Result "*"]\n\n1. d4 d5 {second} 2. Nf3 *\n\n'
        '[Event "C"]\n[Result "*"]\n\n1. d4 d5 2. Bf4 *\n';
    final after = commented(
      parseChapter(name: 'Shared', text: file),
      at: NodePath.of([0, 0]),
      text: 'Ours',
    );
    expect(after.lines[0].text, contains('d5 {Ours}'));
    expect(after.lines[1].text, contains('d5 {Ours}'));
    expect(after.lines[2].text, contains('1. d4 d5 2. Bf4 *'));
  });

  test('a comment at the root path is the chapter introduction', () {
    final before = white();
    final after = commented(
      before,
      at: const NodePath.root(),
      text: 'Play the Exchange.',
    );
    expect(after.tree.rootComment, 'Play the Exchange.');
    expect(after.lines[0].text, contains('{Play the Exchange.} 1. d4'));
    expect(after.lines[1].text, before.lines[1].text);
    expect(reread(after).tree.rootComment, 'Play the Exchange.');
  });

  test('an edit to the prose keeps the engine and clock tokens', () {
    // 1. d4 d5 2. c4 e6, whose comment is nothing but tokens.
    final after = commented(
      white(),
      at: NodePath.of([0, 0, 0, 0]),
      text: 'Main line',
    );
    expect(
      after.lines[0].text,
      contains('e6 {Main line [%eval 0.21] [%clk 0:29:41]}'),
    );
  });

  test('removing a comment removes the prose and keeps the tokens', () {
    // 1. d4 d5 2. c4 c6 {The Slav [%eval 0.18]}
    final after = commented(white(), at: NodePath.of([0, 0, 0, 1]), text: '');
    expect(after.lines[1].text, contains('c6 {[%eval 0.18]}'));
    expect(after.lines[1].text, isNot(contains('The Slav')));
  });

  test('a comment on a move one game plays leaves the others alone', () {
    final before = white();
    final after = commented(
      before,
      at: NodePath.of([0, 1]),
      text: 'A different defence',
    );
    expect(after.lines[2].text, contains('Nf6 {A different defence}'));
    expect(after.lines[0].text, before.lines[0].text);
    expect(after.lines[1].text, before.lines[1].text);
  });

  test('a comment inside a variation stays inside that variation', () {
    final before = black();
    final after = commented(
      before,
      at: NodePath.of([0, 0, 1]),
      text: 'Open Sicilian',
    );
    expect(after.lines[0].text, contains('(2... Nc6 {Open Sicilian} 3. d4)'));
    expect(writeChapter(reread(after)), writeChapter(after));
  });

  test('commenting a game whose tags hold an escaped quote keeps them all', () {
    const file =
        '[Event "He said \\"go\\""]\n'
        '[Result "*"]\n'
        '[LineID "line_abc"]\n'
        '\n'
        '1. d4 *\n';
    final after = commented(
      parseChapter(name: 'Quoted', text: file),
      at: NodePath.of([0]),
      text: 'Main line',
    );
    final line = after.lines.single;
    expect(line.tags.whereType<PgnTag>().map((t) => t.key), [
      'Event',
      'Result',
      'LineID',
    ]);
    expect(line.lineId, 'line_abc');
    expect(line.text, contains(r'[Event "He said \"go\""]'));
    expect(line.text, contains('1. d4 {Main line} *'));
  });

  group('a game reading could not finish', () {
    final chapter = parseChapter(name: 'Partial', text: partlyReadChapter);

    test('is read only as far as it could be read', () {
      expect(chapter.lines[2].isWhole, isFalse);
      expect(chapter.gameCount, 3);
      expect(chapter.issues.single.game, 2);
    });

    test('refuses a comment on a move it plays, and changes nothing', () {
      expect(
        setComment(chapter, at: NodePath.of([0]), text: 'mine'),
        isA<GameNotWhole>(),
      );
      expect(writeChapter(chapter), partlyReadChapter);
    });

    test('keeps its bytes when a comment goes into another game', () {
      final after = commented(
        chapter,
        at: NodePath.of([0, 0]),
        text: 'Symmetrical',
      );
      expect(after.lines[0].text, contains('d5 {Symmetrical}'));
      expect(after.lines[2].text, chapter.lines[2].text);
      expect(writeChapter(after), contains('1. d4 e6 -- 2. c4 {also vital} *'));
    });
  });

  group('a game reading could not finish, in other places', () {
    final chapter = parseChapter(name: 'Partial', text: partlyReadChapter);

    test('refuses the chapter introduction when it is the first game', () {
      final first = parseChapter(name: 'First', text: partialFirstChapter);
      expect(
        setComment(first, at: const NodePath.root(), text: 'Mine'),
        isA<GameNotWhole>(),
      );
      expect(writeChapter(first), partialFirstChapter);
    });

    test('is not extended; the move becomes a game of its own', () {
      // 1. d4 e6 is the end of the third game, but that game keeps its bytes.
      final after = added(chapter, NodePath.of([0, 2]), 'c2c4');
      expect(after.lines[2].text, chapter.lines[2].text);
      expect(after.lines, hasLength(4));
      expect(after.lines.last.text, endsWith('1. d4 e6 2. c4 *'));
    });

    test('an illegal move protects the moves written after it', () {
      final illegal = parseChapter(name: 'Illegal', text: illegalMoveChapter);
      expect(illegal.lines[1].isWhole, isFalse);
      expect(
        setComment(illegal, at: NodePath.of([0, 0]), text: 'mine'),
        isA<GameNotWhole>(),
      );
      expect(writeChapter(illegal), illegalMoveChapter);
    });
  });
}

/// Three games from 1. d4. In the third, `--` is White's ply, so `2. c4`
/// after it is White moving twice; reading stops there and the moves after
/// it are in the file and not in the tree.
const partlyReadChapter = '''
// Color: White

[Event "A"]
[Result "*"]

1. d4 d5 *

[Event "B"]
[Result "*"]

1. d4 Nf6 *

[Event "C"]
[Result "*"]

1. d4 e6 -- 2. c4 {also vital} *
''';

/// A chapter whose first game — the one the introduction belongs to — is the
/// one reading could not finish, for the same reason.
const partialFirstChapter = '''
// Color: White

[Event "C"]
[Result "*"]

1. d4 e6 -- 2. c4 *

[Event "A"]
[Result "*"]

1. d4 d5 *
''';

/// Two games, the second of which plays a move that is not legal; reading
/// stops there and the moves after it stay in the file only.
const illegalMoveChapter = '''
// Color: White

[Event "A"]
[Result "*"]

1. e4 e5 *

[Event "B"]
[Result "*"]

1. e4 e5 2. Ke3 Nf6 {kept} *
''';
