import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';

/// The buggy pre-fix formula, kept here so the test can demonstrate exactly
/// where it diverges from reality.
int oldBaseIndex(int moveNumber, bool isWhite, int startFullmoves) =>
    (moveNumber - startFullmoves) * 2 + (isWhite ? 0 : 1);

/// Ground truth: replay [mainlineSans] from [startFen] and return the ply
/// (count of half-moves played) at which the *next* move to play is the one
/// numbered [moveNumber] for the given side. This is what "the position the
/// inline line departs from" actually means.
int groundTruthBaseIndex(
  String startFen,
  List<String> mainlineSans,
  int moveNumber,
  bool isWhite,
) {
  Position pos = Chess.fromSetup(Setup.parseFen(startFen));
  for (int ply = 0; ply <= mainlineSans.length; ply++) {
    final atThisMove = pos.fullmoves == moveNumber &&
        (pos.turn == Side.white) == isWhite;
    if (atThisMove) return ply;
    if (ply == mainlineSans.length) break;
    final m = pos.parseSan(mainlineSans[ply]);
    if (m == null) break;
    pos = pos.play(m);
  }
  return -1; // not found
}

void main() {
  group('plyBeforeMove — White-to-move start (standard game)', () {
    const startFen =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final mainline = ['e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4'];

    test('matches ground truth for every move in the line', () {
      // (moveNumber, isWhite) for each ply position 0..n
      final cases = <(int, bool)>[
        (1, true), // before 1.e4   -> ply 0
        (1, false), // before 1...c5 -> ply 1
        (2, true), // before 2.Nf3  -> ply 2
        (2, false), // before 2...d6 -> ply 3
        (3, true), // before 3.d4   -> ply 4
        (3, false), // before 3...cxd4 -> ply 5
      ];
      for (final (num, white) in cases) {
        final truth = groundTruthBaseIndex(startFen, mainline, num, white);
        final got = plyBeforeMove(
          moveNumber: num,
          isWhite: white,
          startFullmoves: 1,
          startWhiteToMove: true,
        );
        expect(got, truth, reason: 'move $num ${white ? "w" : "b"}');
        // For a White-start game the old formula was already correct:
        expect(oldBaseIndex(num, white, 1), truth);
      }
    });
  });

  group('plyBeforeMove — Black-to-move start (FEN study)', () {
    // Position after 1.e4: Black to move, fullmoves still 1.
    const startFen =
        'rnbqkbnr/pppppppp/8/4P3/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    final mainline = ['c5', 'Nf3', 'd6', 'd4', 'cxd4'];
    // plies:          0     1     2    3     4

    test('new helper matches ground truth; old formula is off by one', () {
      final cases = <(int, bool)>[
        (1, false), // before 1...c5 -> ply 0
        (2, true), // before 2.Nf3  -> ply 1
        (2, false), // before 2...d6 -> ply 2
        (3, true), // before 3.d4   -> ply 3
        (3, false), // before 3...cxd4 -> ply 4
      ];
      for (final (num, white) in cases) {
        final truth = groundTruthBaseIndex(startFen, mainline, num, white);
        expect(truth, isNonNegative, reason: 'sanity: $num found');

        final got = plyBeforeMove(
          moveNumber: num,
          isWhite: white,
          startFullmoves: 1,
          startWhiteToMove: false,
        );
        expect(got, truth, reason: 'NEW move $num ${white ? "w" : "b"}');

        // Demonstrate the old bug: it overshoots by exactly one ply because it
        // never accounts for ply 0 being a Black move.
        expect(oldBaseIndex(num, white, 1), truth + 1,
            reason: 'OLD move $num ${white ? "w" : "b"} overshoots');
      }
    });

    test('end-to-end: replay base + inline line lands on the right position',
        () {
      // User clicks "Nf3" in a comment line "2.Nf3 d6 3.d4". Run = [Nf3,d6,d4],
      // first move 2.Nf3 (white). Clicking index 0 should leave the board on
      // the position right after Nf3.
      final baseIndex = plyBeforeMove(
        moveNumber: 2,
        isWhite: true,
        startFullmoves: 1,
        startWhiteToMove: false,
      );

      // Replay mainline to the branch point, then the inline move.
      Position pos = Chess.fromSetup(Setup.parseFen(startFen));
      for (int i = 0; i < baseIndex; i++) {
        pos = pos.play(pos.parseSan(mainline[i])!);
      }
      pos = pos.play(pos.parseSan('Nf3')!);

      // Independently: from start, play c5 then Nf3.
      Position expected = Chess.fromSetup(Setup.parseFen(startFen));
      expected = expected.play(expected.parseSan('c5')!);
      expected = expected.play(expected.parseSan('Nf3')!);

      expect(pos.fen, expected.fen);
    });
  });

  group('plyBeforeMove — deeper Black-to-move start (fullmoves 20)', () {
    // Arbitrary legal position, Black to move, fullmoves 20.
    const startFen = '8/5k2/8/8/3K4/8/8/8 b - - 0 20';
    final mainline = ['Ke7', 'Kd5', 'Kd7', 'Kc5'];

    test('matches ground truth', () {
      final cases = <(int, bool)>[
        (20, false), // before 20...Ke7 -> ply 0
        (21, true), // before 21.Kd5   -> ply 1
        (21, false), // before 21...Kd7 -> ply 2
        (22, true), // before 22.Kc5   -> ply 3
      ];
      for (final (num, white) in cases) {
        final truth = groundTruthBaseIndex(startFen, mainline, num, white);
        final got = plyBeforeMove(
          moveNumber: num,
          isWhite: white,
          startFullmoves: 20,
          startWhiteToMove: false,
        );
        expect(got, truth, reason: 'move $num ${white ? "w" : "b"}');
      }
    });
  });
}
