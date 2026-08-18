import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/board_shape_comments.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show filterDisplayComment;
import 'package:chess_auto_prep/models/board_annotation.dart';

void main() {
  group('parseBoardShapes', () {
    test('reads Lichess circles and arrows out of a comment', () {
      final shapes = parseBoardShapes(
        'The knight is stuck. [%csl Gd4,Re5] [%cal Gd4e5,Rf3g5]',
      );

      expect(shapes.length, 4);
      final circles = shapes.where((s) => s.isCircle).toList();
      final arrows = shapes.where((s) => s.isArrow).toList();

      expect(circles.map((s) => s.orig), ['d4', 'e5']);
      expect(circles.map((s) => s.brush), [
        AnnotationBrush.green,
        AnnotationBrush.red,
      ]);
      expect(arrows.first.orig, 'd4');
      expect(arrows.first.dest, 'e5');
      expect(arrows.last.brush, AnnotationBrush.red);
    });

    test('returns nothing for comments without shape tokens', () {
      expect(parseBoardShapes('Just prose.'), isEmpty);
      expect(parseBoardShapes(null), isEmpty);
      expect(parseBoardShapes(''), isEmpty);
    });

    test('skips malformed entries instead of throwing', () {
      // Scraped PGNs carry junk: a bad square, a truncated arrow, an unknown
      // colour letter (which falls back to green rather than being dropped).
      final shapes = parseBoardShapes('[%csl Gz9,Xd4] [%cal Gd4,Gd4e5]');
      expect(shapes.length, 2);
      expect(shapes.first.orig, 'd4');
      expect(shapes.first.brush, AnnotationBrush.green);
      expect(shapes.last.isArrow, isTrue);
    });

    test('uppercases and lowercases both parse', () {
      final shapes = parseBoardShapes('[%cal gD4E5]');
      expect(shapes.single.orig, 'd4');
      expect(shapes.single.dest, 'e5');
    });
  });

  group('writeBoardShapes', () {
    test('round-trips through parse unchanged', () {
      const original = '[%csl Gd4] [%cal Rf3g5]';
      final written = writeBoardShapes(null, parseBoardShapes(original));
      expect(parseBoardShapes(written).length, 2);
      expect(written, contains('[%csl Gd4]'));
      expect(written, contains('[%cal Rf3g5]'));
    });

    test('keeps prose and replaces old tokens rather than appending', () {
      final result = writeBoardShapes('Key idea. [%cal Gd4e5]', [
        const BoardAnnotation(
          orig: 'a1',
          dest: 'a8',
          brush: AnnotationBrush.red,
        ),
      ]);
      expect(result, 'Key idea. [%cal Ra1a8]');
      expect('[%cal Gd4e5]'.allMatches(result!).length, 0);
    });

    test('clearing shapes leaves prose alone', () {
      expect(writeBoardShapes('Key idea. [%cal Gd4e5]', const []), 'Key idea.');
    });

    test('clearing shapes on a shapes-only comment yields null', () {
      expect(writeBoardShapes('[%cal Gd4e5]', const []), isNull);
    });

    test('preserves other annotation tokens such as clocks', () {
      final result = writeBoardShapes('[%clk 0:03:00] [%csl Gd4]', const []);
      expect(result, '[%clk 0:03:00]');
    });
  });

  group('toggleBoardShape', () {
    const arrow = BoardAnnotation(orig: 'd4', dest: 'e5');
    const circle = BoardAnnotation(orig: 'd4');

    test('adds a shape that is not there', () {
      expect(toggleBoardShape(const [], arrow).length, 1);
    });

    test('erases an identical shape', () {
      expect(toggleBoardShape(const [arrow], arrow), isEmpty);
    });

    test('recolours instead of erasing when the brush differs', () {
      final result = toggleBoardShape(
        const [arrow],
        const BoardAnnotation(
          orig: 'd4',
          dest: 'e5',
          brush: AnnotationBrush.red,
        ),
      );
      expect(result.length, 1);
      expect(result.single.brush, AnnotationBrush.red);
    });

    test('an arrow and a circle on the same origin are distinct', () {
      final result = toggleBoardShape(const [arrow], circle);
      expect(result.length, 2);
    });
  });

  test('shape tokens still never leak into displayed prose', () {
    // The display filter and this file are two halves of one contract: shapes
    // render on the board, never as text in the movetext.
    expect(
      filterDisplayComment('Key idea. [%csl Gd4] [%cal Rf3g5]'),
      'Key idea.',
    );
  });
}
