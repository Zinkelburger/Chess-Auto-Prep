import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// A game whose comment holds a blank line and then a line starting with
/// `[`, which is what an engine token on its own line looks like.
const runOnComment = '''
// Color: White

[Event "Notes"]
[Result "*"]

1. e4 {A thought that runs on

[%eval 0.21]} d5 2. c4 *
''';

/// A chapter whose first game names a position nothing can read, followed by
/// a game that reads perfectly well.
const brokenFirstGame = '''
// Color: White

[Event "Broken"]
[FEN "not a fen"]
[Result "*"]

1. e4 *

[Event "Good"]
[Result "*"]

1. d4 d5 *
''';

void main() {
  final chapter = parseChapter(name: 'Main', text: blackChapter);

  test('reads the side from the // Color line and counts the games', () {
    expect(chapter.side, Side.black);
    expect(chapter.gameCount, 2);
    expect(chapter.skippedGames, 1);
    expect(chapter.unreadableGames, 0);
    expect(chapter.issues, isEmpty);
  });

  test('merges every game into one tree; the first game is the main line', () {
    final c5 = chapter.tree.children.single;
    expect(c5.san, 'c5');
    expect(c5.comment, 'The Sicilian [%eval 0.30]');
    expect(c5.children.map((n) => n.san), ['Nf3', 'Nc3']);

    final nf3 = c5.children[0];
    expect(nf3.children.map((n) => n.san), ['d6', 'Nc6']);
    expect(chapter.tree.nodeAt(NodePath.of([0, 1]))?.comment, 'Closed');
  });

  test('a file with no games is an empty White chapter', () {
    final empty = parseChapter(name: 'New', text: '// Main\n');
    expect(empty.side, Side.white);
    expect(empty.tree.isEmpty, isTrue);
    expect(empty.gameCount, 0);
  });

  group('a game whose comment holds a blank line', () {
    final notes = parseChapter(name: 'Notes', text: runOnComment);

    test('keeps every move written after that comment', () {
      expect(mainlineSans(notes.tree), ['e4', 'd5', 'c4']);
    });

    test('still has them after an edit writes the game again', () {
      final edited = setComment(notes, at: NodePath.of([0]), text: 'Mine');
      expect(writeChapter(edited), contains('d5 2. c4 *'));
    });
  });

  group('a game nothing can read', () {
    final mixed = parseChapter(name: 'Mixed', text: brokenFirstGame);

    test('does not hide the games after it', () {
      expect(mixed.tree.rootFen, Fen.initial);
      expect(mainlineSans(mixed.tree), ['d4', 'd5']);
      expect(mixed.gameCount, 1);
      expect(mixed.unreadableGames, 1);
      expect(mixed.skippedGames, 0);
      expect(mixed.issues.single.game, 0);
      expect(mixed.issues.single.detail, 'unusable FEN header');
    });

    test('keeps its own text word for word', () {
      expect(writeChapter(mixed), brokenFirstGame);
    });

    test('leaves a chapter of nothing else without moves, not without a '
        'position', () {
      final broken = parseChapter(
        name: 'Broken',
        text: '''
[Event "Broken"]
[FEN "not a fen"]
[Result "*"]

1. e4 *
''',
      );
      expect(broken.tree.rootFen, Fen.initial);
      expect(broken.tree.isEmpty, isTrue);
      expect(broken.gameCount, 0);
      expect(broken.unreadableGames, 1);
    });
  });
}
