import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the SAN/UCI conversion contracts that `utils/chess_move_utils.dart`
/// used to provide in parallel. The two files had *divergent* semantics for
/// the same three function names; these tests pin down the surviving one.
const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// Both sides can castle either way; nothing in between.
const castleFen = 'r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w KQkq - 0 1';

void main() {
  group('uciToSanOrNull (strict — safe for move identity)', () {
    test('converts a legal move', () {
      expect(uciToSanOrNull(startFen, 'g1f3'), 'Nf3');
      expect(uciToSanOrNull(startFen, 'e2e4'), 'e4');
    });

    test('returns null for illegal or garbage input', () {
      expect(uciToSanOrNull(startFen, 'e2e5'), isNull);
      expect(uciToSanOrNull(startFen, 'zzzz'), isNull);
      expect(uciToSanOrNull('not a fen', 'e2e4'), isNull);
    });
  });

  group('uciToSan (lenient — display only)', () {
    test('converts a legal move', () {
      expect(uciToSan(startFen, 'g1f3'), 'Nf3');
    });

    test('echoes the raw UCI when the move cannot be resolved', () {
      // This fallback is exactly why identity comparisons must use
      // uciToSanOrNull: "e2e5" is not a SAN move, but it is a plausible
      // map key / set member and would silently pass an `!= null` guard.
      expect(uciToSan(startFen, 'e2e5'), 'e2e5');
      expect(uciToSan('not a fen', 'e2e4'), 'e2e4');
    });
  });

  group('sanToUci', () {
    test('converts a normal move', () {
      expect(sanToUci(startFen, 'Nf3'), 'g1f3');
      expect(sanToUci(startFen, 'e4'), 'e2e4');
    });

    test('returns null for illegal SAN', () {
      expect(sanToUci(startFen, 'Nf6'), isNull);
      expect(sanToUci(startFen, 'xyz'), isNull);
    });

    test('emits castling king→destination, matching engine UCI', () {
      // Regression: the deleted chess_move_utils.sanToUci returned dartchess'
      // raw king→ROOK encoding (e1h1), which never compares equal to the
      // king→DEST encoding (e1g1) that Stockfish emits. The audit and
      // hole-hunt services compare `line.moveUci == repUci`, so castling
      // moves in a repertoire were silently skipped by both sweeps.
      expect(sanToUci(castleFen, 'O-O'), 'e1g1');
      expect(sanToUci(castleFen, 'O-O-O'), 'e1c1');
    });

    test('round-trips castling through uciToSanOrNull', () {
      final uci = sanToUci(castleFen, 'O-O')!;
      expect(uciToSanOrNull(castleFen, uci), 'O-O');
    });
  });

  group('uciPvToSan', () {
    test('converts a full PV', () {
      expect(uciPvToSan(startFen, ['e2e4', 'e7e5', 'g1f3']), [
        'e4',
        'e5',
        'Nf3',
      ]);
    });

    test('caps at maxMoves', () {
      expect(uciPvToSan(startFen, ['e2e4', 'e7e5', 'g1f3'], maxMoves: 2), [
        'e4',
        'e5',
      ]);
    });

    test('defaults to a cap of 8 plies', () {
      final pv = [
        'e2e4',
        'e7e5',
        'g1f3',
        'b8c6',
        'f1b5',
        'a7a6',
        'b5a4',
        'g8f6',
        'e1g1',
      ];
      expect(uciPvToSan(startFen, pv).length, 8);
    });

    test('stops at the first unapplicable move, keeping the valid prefix', () {
      expect(uciPvToSan(startFen, ['e2e4', 'e2e4', 'g1f3']), ['e4']);
    });

    test('empty on unparsable fen', () {
      expect(uciPvToSan('bad fen', ['e2e4']), isEmpty);
    });

    test('empty input yields empty output', () {
      expect(uciPvToSan(startFen, const []), isEmpty);
    });
  });

  group('null-move SAN (ChessBase Z0 / --)', () {
    test('isNullMoveSan recognises ChessBase, SCID, and UCI spellings', () {
      expect(isNullMoveSan('--'), isTrue);
      expect(isNullMoveSan('Z0'), isTrue);
      expect(isNullMoveSan('0000'), isTrue);
      expect(isNullMoveSan('@@@@'), isTrue);
      expect(isNullMoveSan('e4'), isFalse);
      expect(isNullMoveSan('Nf3'), isFalse);
    });

    test('playSanOrNullMove passes the turn so White can play again', () {
      final afterD4 = playSanOrNullMove(Chess.initial, 'd4')!;
      expect(afterD4.turn, Side.black);

      final afterPass = playSanOrNullMove(afterD4, 'Z0')!;
      expect(afterPass.turn, Side.white);
      expect(afterPass.board, afterD4.board);

      final afterNf3 = playSanOrNullMove(afterPass, 'Nf3');
      expect(afterNf3, isNotNull);
      expect(afterNf3!.fen.split(' ')[0], contains('N'));
    });
  });
}
