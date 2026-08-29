import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/board_annotation.dart';

void main() {
  group('BoardAnnotation.arrowFromUci', () {
    test('parses a plain move into a blue arrow', () {
      final a = BoardAnnotation.arrowFromUci('e2e4');
      expect(a, isNotNull);
      expect(a!.orig, 'e2');
      expect(a.dest, 'e4');
      expect(a.brush, AnnotationBrush.blue);
      expect(a.isArrow, isTrue);
    });

    test('ignores a promotion suffix and honours the brush', () {
      final a = BoardAnnotation.arrowFromUci(
        'e7e8q',
        brush: AnnotationBrush.green,
      );
      expect(a?.dest, 'e8');
      expect(a?.brush, AnnotationBrush.green);
    });

    test('rejects malformed or zero-length moves', () {
      expect(BoardAnnotation.arrowFromUci('zz99'), isNull);
      expect(BoardAnnotation.arrowFromUci('e2'), isNull);
      expect(BoardAnnotation.arrowFromUci('e2e2'), isNull);
      expect(BoardAnnotation.arrowFromUci(''), isNull);
    });
  });

  test('annotations compare by value', () {
    expect(
      BoardAnnotation.arrowFromUci('e2e4'),
      equals(BoardAnnotation.arrowFromUci('e2e4')),
    );
    expect(
      BoardAnnotation.arrowFromUci('e2e4'),
      isNot(equals(BoardAnnotation.arrowFromUci('d2d4'))),
    );
    expect(
      BoardAnnotation.arrowFromUci('e2e4'),
      isNot(
        equals(
          BoardAnnotation.arrowFromUci('e2e4', brush: AnnotationBrush.red),
        ),
      ),
    );
  });
}
