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

    test(
      'omits ChessBase null moves but keeps White numbering after a pass',
      () {
        expect(
          buildNumberedMovetext(['d4', '--', 'Nf3', 'Z0', 'e3']),
          '1. d4 2. Nf3 3. e3',
        );
      },
    );
  });

  group('compact style', () {
    test('drops the space after the move number', () {
      expect(
        buildNumberedMovetext(['e4', 'e5', 'Nf3'], compact: true),
        '1.e4 e5 2.Nf3',
      );
    });

    test('applies to a leading Black move too', () {
      expect(
        buildNumberedMovetext(
          ['e5', 'Nf3'],
          startMoveNumber: 3,
          whiteToMoveFirst: false,
          compact: true,
        ),
        '3...e5 4.Nf3',
      );
    });

    test('differs from the default only in that space', () {
      const moves = ['d4', 'Nf6', 'c4', 'e6'];
      expect(
        buildNumberedMovetext(moves, compact: true).replaceAll('.', '. '),
        buildNumberedMovetext(moves),
      );
    });
  });

  group('formatMoveAtPly', () {
    test('numbers a White move with a dot and Black with an ellipsis', () {
      expect(formatMoveAtPly(0, 'e4'), '1. e4');
      expect(formatMoveAtPly(1, 'e5'), '1... e5');
      expect(formatMoveAtPly(4, 'd4'), '3. d4');
      expect(formatMoveAtPly(5, 'cxd4'), '3... cxd4');
    });

    test('agrees with the numbering buildNumberedMovetext gives the same '
        'sequence', () {
      const moves = ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5'];
      final full = buildNumberedMovetext(moves);
      for (var ply = 0; ply < moves.length; ply++) {
        final piece = formatMoveAtPly(ply, moves[ply]);
        if (ply.isEven) {
          // White moves appear verbatim in the full movetext.
          expect(full, contains(piece), reason: 'ply $ply');
        } else {
          // Black moves are unnumbered mid-sequence, but the move number the
          // helper reports must match the preceding White move's.
          expect(piece, startsWith('${ply ~/ 2 + 1}...'), reason: 'ply $ply');
        }
      }
    });
  });

  group('moveNumberAtPly', () {
    test('plies 0 and 1 are both move 1', () {
      expect(moveNumberAtPly(0), 1);
      expect(moveNumberAtPly(1), 1);
      expect(moveNumberAtPly(2), 2);
      expect(moveNumberAtPly(3), 2);
    });

    test('startMoveNumber offsets a line that does not begin at move 1', () {
      expect(moveNumberAtPly(0, startMoveNumber: 6), 6);
      expect(moveNumberAtPly(1, startMoveNumber: 6), 6);
      expect(moveNumberAtPly(2, startMoveNumber: 6), 7);
    });
  });

  group('moveNumberLabel', () {
    test('White gets a dot and Black an ellipsis', () {
      expect(moveNumberLabel(moveNumber: 3, isWhite: true), '3.');
      expect(moveNumberLabel(moveNumber: 3, isWhite: false), '3...');
    });
  });

  group('formatNumberedMove', () {
    test('takes the number and side directly', () {
      expect(formatNumberedMove('Nf3', moveNumber: 3, isWhite: true), '3. Nf3');
      expect(
        formatNumberedMove('Nf6', moveNumber: 3, isWhite: false),
        '3... Nf6',
      );
    });

    test('compact drops the space', () {
      expect(
        formatNumberedMove('Nf3', moveNumber: 3, isWhite: true, compact: true),
        '3.Nf3',
      );
      expect(
        formatNumberedMove('Nf6', moveNumber: 3, isWhite: false, compact: true),
        '3...Nf6',
      );
    });
  });

  group('formatMoveAtPly composes the two', () {
    test('agrees with formatNumberedMove for every ply', () {
      for (var ply = 0; ply < 12; ply++) {
        expect(
          formatMoveAtPly(ply, 'x'),
          formatNumberedMove(
            'x',
            moveNumber: moveNumberAtPly(ply),
            isWhite: ply.isEven,
          ),
          reason: 'ply $ply',
        );
      }
    });

    test('startMoveNumber shifts the label', () {
      expect(formatMoveAtPly(0, 'Be3', startMoveNumber: 6), '6. Be3');
      expect(formatMoveAtPly(1, 'Bg7', startMoveNumber: 6), '6... Bg7');
      expect(
        formatMoveAtPly(1, 'Bg7', startMoveNumber: 6, compact: true),
        '6...Bg7',
      );
    });

    test('a 1-based ply converts by subtracting one', () {
      // MoveEval.ply is 1-based: 1 = after White's first move.
      expect(formatMoveAtPly(1 - 1, 'e4'), '1. e4');
      expect(formatMoveAtPly(2 - 1, 'e5'), '1... e5');
      expect(formatMoveAtPly(3 - 1, 'Nf3'), '2. Nf3');
    });

    test('a 1-based move *count* converts the same way', () {
      // draft_repertoire_writer.lastMoveLabel: depth = line.length.
      expect(formatMoveAtPly(1 - 1, 'e4', compact: true), '1.e4');
      expect(formatMoveAtPly(2 - 1, 'e5', compact: true), '1...e5');
      expect(formatMoveAtPly(7 - 1, 'Nf3', compact: true), '4.Nf3');
    });
  });
}
