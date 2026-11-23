import 'package:chess_auto_prep/chess/pgn/board_shapes.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/chess/pgn/tree_merge.dart';
import 'package:flutter_test/flutter_test.dart';

/// A game that writes the same reply twice: once as the main move and once
/// as a variation of it. Course exports do this, and so does a file two
/// people edited.
const twiceOverGame = '''
[Event "Twice over"]
[Result "*"]

1. e4 e5 (1... e5 {alt}) 2. Nf3 *
''';

void main() {
  test('a move keeps the first game\'s glyphs, or the later game\'s where '
      'the first has none', () {
    final plain = readGame('1. e4 e5 *').tree!.children;
    final marked = readGame('1. e4! e5 *').tree!.children;
    expect(mergeForests(plain, marked).single.nags, [1]);
    final doubted = readGame('1. e4? e5 *').tree!.children;
    expect(mergeForests(marked, doubted).single.nags, [1]);
  });

  test('an ordinary game folded into nothing is taken as it is, not walked '
      'again', () {
    final game = readGame('1. e4 e5 (1... c5) 2. Nf3 *').tree!.children;
    expect(identical(mergeForests(const [], game), game), isTrue);
  });

  test('one game that plays a move twice keeps one node for it', () {
    final tree = readGame(twiceOverGame).tree!;
    final merged = mergeForests(const [], tree.children);
    final e5 = merged.single.children.single;
    expect(e5.san, 'e5');
    expect(e5.comment, 'alt', reason: 'the variation said something');
    expect(e5.children.single.san, 'Nf3');
  });

  test('a conflicting arrow keeps its spelling and clears on redraw', () {
    const host = 'Plan [%cal ge2e4]';
    final merged = joinedComment(host, '[%cal Re2e4]');
    expect(merged, host);
    final green = shapesIn(host).single;
    expect(withShapeDrawn(shapesIn(merged), green), isEmpty);
  });

  test('joining notes reaches duplicate replies below a new branch', () {
    final host = readGame('1. d4 *').tree!.children;
    final arriving = readGame(
      '1. e4 e5 {Plan [%csl Pd5]} '
      '(1... e5 {[%csl Rd5,bd4,Yd4] [%cal Re7e5,Be5e7,bad]}) *',
    ).tree!.children;

    final joined = mergeForests(host, arriving, joinNotes: true);
    expect(
      joined.last.children.single.comment,
      'Plan [%csl Pd5] [%csl bd4] [%cal Re7e5,Be5e7,bad]',
    );
    final chapter = mergeForests(host, arriving);
    expect(chapter.last.children.single.comment, 'Plan [%csl Pd5]');
  });

  test('a later game adds its variation and reorders nothing', () {
    final first = readGame('1. d4 d5 2. c4 *').tree!;
    final second = readGame('1. d4 Nf6 *').tree!;
    final merged = mergeForests(first.children, second.children);
    expect(merged.single.san, 'd4');
    expect(merged.single.children.map((n) => n.san), ['d5', 'Nf6']);
  });

  test(
    'folding drawings keeps the host colours and each shape erases once',
    () {
      const host = 'Plan [%cal Gf3e5] [%csl Bd4]';
      const arriving = '[%cal Rf3e5,yf3g5] [%csl Gd4,Pe4]';
      final merged = joinedComment(host, arriving);
      expect(merged, contains('[%csl Pe4]'));
      expect(merged, contains('[%cal yf3g5]'));
      expect(joinedComment(merged, arriving), merged);

      var drawn = shapesIn(merged);
      for (final shape in shapesIn(host)) {
        drawn = withShapeDrawn(drawn, shape);
      }
      expect(drawn, shapesIn('[%cal yf3g5] [%csl Pe4]'));
    },
  );

  test('folding a new branch joins the notes on its repeated reply', () {
    final host = readGame('1. d4 *').tree!.children;
    final source = readGame(
      '1. e4 e5 {Open game} (1... e5 {[%cal Gf1c4]} 2. Nf3 {[%clk 0:12:00]}) '
      '2. Nf3 *',
    ).tree!.children;
    final folded = mergeForests(host, source, joinNotes: true);
    final reply = folded.last.children.single;
    expect(reply.comment, 'Open game [%cal Gf1c4]');
    expect(reply.children.single.comment, '[%clk 0:12:00]');
    expect(
      mergeForests(host, source).last.children.single.comment,
      'Open game',
    );
  });

  test('every move of a merged chapter is found where the tree holds it', () {
    final chapter = parseChapter(name: 'Twice over', text: twiceOverGame);
    final replies = chapter.tree.children.single.children;
    for (final (index, reply) in replies.indexed) {
      expect(
        pathOfSans(chapter.tree, ['e4', reply.san]),
        NodePath.of([0, index]),
        reason: 'a cursor on ${reply.san} has to land on ${reply.san}',
      );
    }
  });
}
