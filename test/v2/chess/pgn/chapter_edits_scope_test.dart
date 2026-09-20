// What an edit says it wrote. The store refuses a save that changes any
// other game, so an edit that under-reports loses the user's work and one
// that over-reports lets a bad write through: these are the shapes.
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  Chapter white() => parseChapter(name: 'Gambit', text: whiteChapter);

  GamesWritten wroteAdding(Chapter chapter, NodePath at, String uci) =>
      (addMove(chapter, at: at, uci: uci) as MoveAdded).written;

  GamesWritten wroteCommenting(Chapter chapter, NodePath at, String text) =>
      (setComment(chapter, at: at, text: text) as CommentWritten).written;

  test('a move at the end of a line says that game and no other', () {
    // 1. d4 d5 2. c4 c6 3. Nf3, the end of the second game.
    final written = wroteAdding(white(), NodePath.of([0, 0, 0, 1, 0]), 'g8f6');
    expect(written.rewritten, {1});
    expect(written.appended, 0);
  });

  test('a move at a branch point says one game was added and none '
      'written again', () {
    // 2... e6, beside the c6 the second game plays.
    final written = wroteAdding(white(), NodePath.of([0, 0, 0]), 'g8f6');
    expect(written.rewritten, isEmpty);
    expect(written.appended, 1);
  });

  test('the first move of an empty chapter is a game added', () {
    final empty = parseChapter(name: 'Sidelines', text: emptyChapter);
    final written = wroteAdding(empty, const NodePath.root(), 'd2d4');
    expect(written.rewritten, isEmpty);
    expect(written.appended, 1);
  });

  test('a move the chapter already has writes nothing', () {
    final written = wroteAdding(white(), const NodePath.root(), 'd2d4');
    expect(written.rewritten, isEmpty);
    expect(written.appended, 0);
  });

  test('a comment on a shared move says every game that plays it', () {
    // 2. c4, which the first two games both play; the third starts 1... Nf6.
    final written = wroteCommenting(white(), NodePath.of([0, 0, 0]), 'Ours');
    expect(written.rewritten, {0, 1});
    expect(written.appended, 0);
  });

  test('a comment on a move one game plays says that game', () {
    final written = wroteCommenting(white(), NodePath.of([0, 0, 0, 1]), 'Slav');
    expect(written.rewritten, {1});
  });

  test('the chapter introduction is written into the first game', () {
    final written = wroteCommenting(white(), const NodePath.root(), 'Read me');
    expect(written.rewritten, {0});
  });

  test('words that leave the file as it was write nothing', () {
    final written = wroteCommenting(
      white(),
      NodePath.of([0, 0, 0, 1]),
      'The Slav',
    );
    expect(written.rewritten, isEmpty);
  });
}
