import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/utils/movetext_builder.dart';

void main() {
  group('buildNumberedMovetext', () {
    test('empty move list', () {
      expect(buildNumberedMovetext([]), '');
    });

    test('white start from move 1 (default)', () {
      expect(
        buildNumberedMovetext(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']),
        '1. e4 e5 2. Nf3 Nc6 3. Bb5',
      );
    });

    test('black start gets ellipsis and correct increments', () {
      expect(
        buildNumberedMovetext(
          ['Ra1+', 'Kh2', 'Ra2'],
          startMoveNumber: 10,
          whiteToMoveFirst: false,
        ),
        '10... Ra1+ 11. Kh2 Ra2',
      );
    });

    test('black start at move 1 (root-position bug case)', () {
      // The old RepertoireController serializer produced "1. e5 Nf3" here.
      expect(
        buildNumberedMovetext(['e5', 'Nf3', 'Nc6'], whiteToMoveFirst: false),
        '1... e5 2. Nf3 Nc6',
      );
    });

    test('white start from a later move number', () {
      expect(buildNumberedMovetext(['Qxf7#'], startMoveNumber: 4), '4. Qxf7#');
    });

    test('single black move', () {
      expect(
        buildNumberedMovetext(
          ['Qh4#'],
          startMoveNumber: 4,
          whiteToMoveFirst: false,
        ),
        '4... Qh4#',
      );
    });

    test('per-move suffix callback (comments / NAGs / tags)', () {
      expect(
        buildNumberedMovetext([
          'e4',
          'e5',
          'Nf3',
        ], suffix: (i) => i == 1 ? ' {[%maiaProbability 0.550]}' : null),
        '1. e4 e5 {[%maiaProbability 0.550]} 2. Nf3',
      );
    });

    test('empty suffix writes nothing', () {
      expect(
        buildNumberedMovetext(['e4', 'e5'], suffix: (_) => ''),
        '1. e4 e5',
      );
    });
  });
}
