import 'package:chess_auto_prep/chess/pgn/board_shapes.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/comment_edits.dart';
import 'package:chess_auto_prep/chess/pgn/comment_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:dartchess/dartchess.dart' show Square;
import 'package:flutter_test/flutter_test.dart';

const _arrow = BoardShape(Square.e2, Square.e4, ShapeColour.green);
const _circle = BoardShape.circle(Square.d5, ShapeColour.red);

void main() {
  group('reading', () {
    test('reads Lichess circles and arrows, circles first', () {
      expect(shapesIn('Good {x} [%cal Ge2e4,Yb1c3] [%csl Rd5]'), [
        _circle,
        _arrow,
        const BoardShape(Square.b1, Square.c3, ShapeColour.yellow),
      ]);
    });

    test('skips entries that name no squares and keeps the rest', () {
      expect(shapesIn('[%cal Ge2e4,Gz9z9,Re2e2,Bd1] [%csl ,Gx1,rd5]'), [
        _circle,
        _arrow,
      ]);
    });

    test('an unknown colour letter reads as green and is written back as '
        'it was', () {
      expect(shapesIn('[%csl Pd5]'), [
        const BoardShape.circle(Square.d5, ShapeColour.green),
      ]);
      expect(withShapes('[%csl Pd5]', shapesIn('[%csl Pd5]')), '[%csl Pd5]');
    });

    test('a comment without tokens has no shapes', () {
      expect(shapesIn(null), isEmpty);
      expect(shapesIn('Only words'), isEmpty);
    });
  });

  group('writing', () {
    test('replaces the tokens and keeps the words and other tokens', () {
      const comment = 'Nice [%eval 0.3] [%cal Rd1d8] idea [%csl Ga1]';
      final written = withShapes(comment, const [_arrow, _circle]);
      expect(written, 'Nice [%eval 0.3] idea [%csl Rd5] [%cal Ge2e4]');
      expect(displayComment(written!), 'Nice idea');
      expect(shapesIn(written), [_circle, _arrow]);
    });

    test('a shape kept is written as the comment wrote it, colour letter '
        'and case included', () {
      const comment = 'See [%csl Pd5,rd4] [%cal ye2e4]';
      final kept = shapesIn(comment);
      expect(kept, [
        const BoardShape.circle(Square.d5, ShapeColour.green),
        const BoardShape.circle(Square.d4, ShapeColour.red),
        const BoardShape(Square.e2, Square.e4, ShapeColour.yellow),
      ]);
      expect(withShapes(comment, kept), comment);
      // Drawing one more arrow leaves the others as they were written.
      expect(
        withShapes(comment, [
          ...kept,
          const BoardShape(Square.g1, Square.f3, ShapeColour.red),
        ]),
        'See [%csl Pd5,rd4] [%cal ye2e4,Rg1f3]',
      );
    });

    test('entries that read as no shape stay, as written, after the '
        'shapes', () {
      const comment = '[%cal Ge2e4,Gz9z9,Re2e2,Bd1] [%csl ,Gx1,rd5]';
      expect(
        withShapes(comment, shapesIn(comment)),
        '[%csl rd5,Gx1] [%cal Ge2e4,Gz9z9,Re2e2,Bd1]',
      );
      expect(
        withShapes(comment, const []),
        '[%csl Gx1] [%cal Gz9z9,Re2e2,Bd1]',
      );
      expect(
        withShapes(comment, const [_circle]),
        '[%csl rd5,Gx1] [%cal Gz9z9,Re2e2,Bd1]',
      );
    });

    test('no shapes takes the tokens away; nothing left is null', () {
      expect(withShapes('Plan [%cal Ge2e4]', const []), 'Plan');
      expect(withShapes('[%cal Ge2e4]', const []), isNull);
      expect(withShapes(null, const [_arrow]), '[%cal Ge2e4]');
    });
  });

  group('drawing over', () {
    test('adds, recolours, and takes away a shape drawn twice', () {
      final one = withShapeDrawn(const [], _arrow);
      expect(one, [_arrow]);
      const red = BoardShape(Square.e2, Square.e4, ShapeColour.red);
      expect(withShapeDrawn(one, red), [red]);
      expect(withShapeDrawn(one, _arrow), isEmpty);
      expect(withShapeDrawn(one, _circle), [_arrow, _circle]);
    });
  });

  group('in a chapter', () {
    const pgn =
        '[Event "A"]\n[Result "*"]\n\n{Intro} 1. e4 {Good [%clk 0:01:00]} e5 *\n';
    Chapter chapter() => parseChapter(name: 'Shapes', text: pgn);

    Chapter drawn(Chapter before, NodePath at, List<BoardShape> shapes) =>
        (setShapes(before, at: at, shapes: shapes) as ChapterEdited).chapter;

    test('a move keeps its words and clock beside the new arrows', () {
      final after = drawn(chapter(), NodePath.of([0]), const [_arrow]);
      expect(
        after.lines.single.text,
        contains('1. e4 {Good [%clk 0:01:00] [%cal Ge2e4]} e5'),
      );
      final reread = parseChapter(name: 'Shapes', text: writeChapter(after));
      expect(shapesIn(reread.tree.children.single.comment), [_arrow]);
    });

    test('shapes on the starting position join the introduction', () {
      final after = drawn(chapter(), const NodePath.root(), const [_circle]);
      expect(after.tree.rootComment, 'Intro [%csl Rd5]');
    });

    test('drawing what is there already changes nothing', () {
      final once = drawn(chapter(), NodePath.of([0]), const [_arrow]);
      expect(
        setShapes(once, at: NodePath.of([0]), shapes: const [_arrow]),
        isA<ChapterUnchanged>(),
      );
    });
  });
}
