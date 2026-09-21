// The tree on screen is every game of the chapter merged in file order, so
// which branch is the main line is decided both inside the games and by the
// order of the games. These are the edits that change either.
import 'package:chess_auto_prep/v2/chess/pgn/branch_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/move_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// Three games from the initial position, the second of them branching off
/// the first at move 1 and the third at move 2.
const threeLines = '''
// Book
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 e6 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *

[Event "Slav"]
[Result "*"]

1. d4 d5 2. c4 c6 *
''';

Chapter book() => parseChapter(name: 'Book', text: threeLines);

ChapterEdited edited(ChapterEdit edit) => edit as ChapterEdited;

String movesOf(Chapter chapter) => writeMoveText(chapter.tree, terminator: '*');

List<String> namesOf(Chapter chapter) => [
  for (final line in chapter.lines) tagValue(line.tags, 'Event')!,
];

/// Where [sans] is in the chapter's merged tree.
NodePath at(Chapter chapter, List<String> sans) =>
    pathOfSans(chapter.tree, sans)!;

void main() {
  test('the merged tree follows the order of the games', () {
    expect(movesOf(book()), '1. d4 d5 (1... Nf6) 2. c4 e6 (2... c6) *');
  });

  test('making a branch the main line reorders the games, writing none', () {
    final before = book();

    final after = edited(madeMainLine(before, at: at(before, ['d4', 'Nf6'])));

    expect(namesOf(after.chapter), ['Indian', "Queen's", 'Slav']);
    expect(movesOf(after.chapter), '1. d4 Nf6 (1... d5 2. c4 e6 (2... c6)) *');
    expect(after.games.order, [1, 0, 2]);
    expect(after.games.rewritten, isEmpty);
    expect(after.games.before, 3);
  });

  test('a game the reorder moved keeps its own bytes', () {
    final before = book();

    final after = edited(madeMainLine(before, at: at(before, ['d4', 'Nf6'])));

    expect(after.chapter.lines[0].text, before.lines[1].text);
    expect(after.chapter.lines[1].text, before.lines[0].text);
  });

  test('promoting a branch inside one game rewrites that game', () {
    final before = parseChapter(name: 'One', text: oneGameWithVariation);

    final after = edited(
      variationPromoted(before, at: at(before, ['e4', 'c5'])),
    );

    expect(movesOf(after.chapter), '1. e4 c5 (1... e5 2. Nf3) *');
    expect(after.games.rewritten, {0});
    expect(after.games.order, [0]);
  });

  test('promoting a move that is already first changes nothing', () {
    final before = book();

    expect(
      variationPromoted(before, at: at(before, ['d4', 'd5'])),
      isA<ChapterUnchanged>(),
    );
  });

  test('deleting from a move cuts every game that plays it', () {
    final before = book();

    final after = edited(
      movesDeleted(before, at: at(before, ['d4', 'd5', 'c4'])),
    );

    expect(movesOf(after.chapter), '1. d4 d5 (1... Nf6) *');
    expect(after.games.order, [0, 1, 2]);
    expect(after.games.rewritten, {0, 2});
  });

  test('a game that still has a move is cut short rather than removed', () {
    final before = book();

    final after = edited(movesDeleted(before, at: at(before, ['d4', 'Nf6'])));

    expect(namesOf(after.chapter), ["Queen's", 'Indian', 'Slav']);
    expect(after.chapter.lines[1].text, endsWith('1. d4 *'));
    expect(after.games.order, [0, 1, 2]);
    expect(after.games.rewritten, {1});
    expect(movesOf(after.chapter), '1. d4 d5 2. c4 e6 (2... c6) *');
  });

  test('a game left with no moves at all leaves the file', () {
    final before = book();

    final after = edited(movesDeleted(before, at: at(before, ['d4'])));

    expect(after.chapter.lines, isEmpty);
    expect(after.games.order, isEmpty);
    expect(after.games.before, 3);
    expect(writeChapter(after.chapter), '// Book\n// Color: White\n\n');
  });

  test('the file a deletion produces reads back as the tree it made', () {
    final before = book();

    final after = edited(
      movesDeleted(before, at: at(before, ['d4', 'd5', 'c4'])),
    );

    final reread = parseChapter(
      name: 'Book',
      text: writeChapter(after.chapter),
    );
    expect(movesOf(reread), movesOf(after.chapter));
  });

  test('a line that could not be read in full refuses the edit', () {
    final before = parseChapter(name: 'Hurt', text: brokenSecondGame);

    final refused = movesDeleted(before, at: at(before, ['e4', 'e5']));

    expect(
      (refused as ChapterEditRefused).reason,
      'a line in the way could not be read in full',
    );
  });

  test('the root is not a move, so nothing is deleted from it', () {
    expect(
      movesDeleted(book(), at: const NodePath.root()),
      isA<ChapterUnchanged>(),
    );
  });

  test('the chapter fixtures survive a promotion and read back', () {
    final before = parseChapter(name: 'Gambit', text: whiteChapter);

    final after = edited(
      madeMainLine(before, at: at(before, ['d4', 'd5', 'c4', 'c6'])),
    );

    final reread = parseChapter(
      name: 'Gambit',
      text: writeChapter(after.chapter),
    );
    expect(movesOf(reread), movesOf(after.chapter));
    expect(reread.tree.children.first.children.first.san, 'd5');
  });
}

const oneGameWithVariation = '''
// One
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 (1... c5) 2. Nf3 *
''';

/// Two games, the second of which holds a word no reader can take, so it
/// keeps its own bytes and every edit that would write it is refused.
const brokenSecondGame = '''
// Hurt
// Color: White

[Event "Fine"]
[Result "*"]

1. e4 e5 2. Nf3 *

[Event "Broken"]
[Result "*"]

1. e4 e5 2. Qq9 *
''';
