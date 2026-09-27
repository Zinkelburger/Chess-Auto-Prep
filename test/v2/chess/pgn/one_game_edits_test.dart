// A study chapter or a game of the PGN Viewer is one game of its file, read
// as it is written rather than merged. A game can play one move twice — on
// the main line and again as a variation beside it — and an edit made on one
// of the two must land on that one.
import 'package:chess_auto_prep/v2/chess/pgn/branch_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/comment_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/study.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two chapters; the first plays `1... e5` twice.
const twice = '''
[Event "Twice"]
[Result "*"]

1. e4 e5 (1... e5 2. Nc3) 2. Nf3 *

[Event "Other"]
[Result "*"]

1. d4 d5 *
''';

Chapter study() => parseChapter(name: 'Study', text: twice, game: 0);

/// The variation's `1... e5`, beside the main line's at `0/0`.
final variation = NodePath.of([0, 1]);

/// The first game's movetext, which is its last line.
String movesOf(Chapter chapter) => chapter.lines[0].text.split('\n').last;

ChapterEdited edited(ChapterEdit edit) => edit as ChapterEdited;

CommentWritten written(CommentResult result) => result as CommentWritten;

void main() {
  test('the game is read as written, the move twice', () {
    final e4 = study().tree.children.single;
    expect(e4.children.map((node) => node.san), ['e5', 'e5']);
    expect(e4.children[1].children.single.san, 'Nc3');
  });

  test('deleting from the variation keeps the main line', () {
    final after = edited(movesDeleted(study(), at: variation));
    expect(movesOf(after.chapter), '1. e4 e5 2. Nf3 *');
    expect(after.games.rewritten, {0});
    expect(after.games.order, [0, 1]);
    expect(after.chapter.lines[1].text, study().lines[1].text);
  });

  test('deleting from the main line keeps the variation', () {
    final after = edited(movesDeleted(study(), at: NodePath.of([0, 0])));
    expect(movesOf(after.chapter), '1. e4 e5 2. Nc3 *');
  });

  test('promoting the variation puts that one first', () {
    final after = edited(variationPromoted(study(), at: variation));
    expect(movesOf(after.chapter), '1. e4 e5 (1... e5 2. Nf3) 2. Nc3 *');
    expect(after.games.rewritten, {0});
  });

  test('promoting the main line changes nothing', () {
    expect(
      variationPromoted(study(), at: NodePath.of([0, 0])),
      isA<ChapterUnchanged>(),
    );
    expect(
      madeMainLine(study(), at: NodePath.of([0, 0, 0])),
      isA<ChapterUnchanged>(),
    );
  });

  test('making a move of the variation the main line follows its path', () {
    final after = edited(madeMainLine(study(), at: NodePath.of([0, 1, 0])));
    expect(movesOf(after.chapter), '1. e4 e5 (1... e5 2. Nf3) 2. Nc3 *');
  });

  test('making a deep move the main line promotes every step to it', () {
    const deep = '[Event "Deep"]\n\n1. e4 e5 (1... c5 2. Nf3 (2. Nc3) d6) *\n';
    final chapter = parseChapter(name: 'Deep', text: deep, game: 0);
    final after = edited(madeMainLine(chapter, at: NodePath.of([0, 1, 1])));
    expect(movesOf(after.chapter), '1. e4 c5 (1... e5) 2. Nc3 (2. Nf3 d6) *');
  });

  test('a comment on the variation goes on that move', () {
    final after = written(
      setComment(study(), at: variation, text: 'the other e5'),
    );
    expect(
      movesOf(after.chapter),
      '1. e4 e5 (1... e5 {the other e5} 2. Nc3) 2. Nf3 *',
    );
    expect(after.written.rewritten, {0});
  });

  test('a glyph on the variation goes on that move', () {
    final after = written(setGlyph(study(), at: variation, nag: 2));
    expect(movesOf(after.chapter), r'1. e4 e5 (1... e5 $2 2. Nc3) 2. Nf3 *');
  });

  test('a marker on the variation goes on that move', () {
    final after = written(
      setMarker(study(), at: variation, marker: quizStartMarker, on: true),
    );
    expect(
      movesOf(after.chapter),
      '1. e4 e5 (1... e5 {[%tstart]} 2. Nc3) 2. Nf3 *',
    );
  });

  test('a move played in the variation extends that variation', () {
    final result = addMove(study(), at: variation, uci: 'g1f3');
    expect(result, isA<MoveAdded>());
    final added = result as MoveAdded;
    expect(added.path, NodePath.of([0, 1, 1]));
    expect(added.chapter.tree.nodeAt(added.path)?.san, 'Nf3');
    expect(
      movesOf(added.chapter),
      '1. e4 e5 (1... e5 2. Nc3 (2. Nf3)) 2. Nf3 *',
    );
  });

  group('a game reading could not take whole', () {
    const broken = '[Event "Hurt"]\n\n1. e4 e5 (1... c5) 2. Qq9 *\n';
    final chapter = parseChapter(name: 'Hurt', text: broken, game: 0);

    test('refuses a deletion and a promotion', () {
      expect(
        movesDeleted(chapter, at: NodePath.of([0, 1])),
        isA<ChapterEditRefused>(),
      );
      expect(
        variationPromoted(chapter, at: NodePath.of([0, 1])),
        isA<ChapterEditRefused>(),
      );
      expect(
        madeMainLine(chapter, at: NodePath.of([0, 1])),
        isA<ChapterEditRefused>(),
      );
    });

    test('refuses a comment and a glyph', () {
      expect(
        setComment(chapter, at: NodePath.of([0, 1]), text: 'no'),
        isA<GameNotWhole>(),
      );
      expect(
        setGlyph(chapter, at: NodePath.of([0, 1]), nag: 1),
        isA<GameNotWhole>(),
      );
    });
  });
}
