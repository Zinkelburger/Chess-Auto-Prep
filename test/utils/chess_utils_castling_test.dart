import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';

/// Regression tests for the castling-encoding bug class: king moves were being
/// classified as castling by raw square-index distance, which mis-flags every
/// vertical/diagonal king move (their indices span 7–9, not ≤2). The only
/// correct test is "does the destination hold the mover's own rook", which also
/// guarantees the castle is legal because dartchess only emits that king target
/// when castling rights, the rook, and a clear/safe path are all present.
void main() {
  Position pos(String fen) => Chess.fromSetup(Setup.parseFen(fen));
  Square sq(String name) => Square.parse(name)!;

  group('isCastlingMove', () {
    test('true only for the king→own-rook target when castling is legal', () {
      // Full castling rights, both rooks home, nothing in between.
      final p = pos('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
      expect(isCastlingMove(p, sq('e1'), sq('h1')), isTrue); // O-O
      expect(isCastlingMove(p, sq('e1'), sq('a1')), isTrue); // O-O-O
    });

    test('false for ordinary king moves in every direction', () {
      final p = pos('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
      for (final dest in ['d1', 'f1', 'd2', 'e2', 'f2']) {
        expect(
          isCastlingMove(p, sq('e1'), sq(dest)),
          isFalse,
          reason: 'e1->$dest is a normal king move, not a castle',
        );
      }
    });

    test('no castling target appears when the FEN grants no rights', () {
      // Same piece placement, but castling field is "-": dartchess emits no
      // king→rook target at all, so the helper is never handed one. Every
      // legal king target is therefore interpreted as an ordinary move.
      final p = pos('r3k2r/8/8/8/8/8/8/R3K2R w - - 0 1');
      expect(p.legalMoves[sq('e1')]!.has(sq('h1')), isFalse);
      expect(p.legalMoves[sq('e1')]!.has(sq('a1')), isFalse);
      for (final d in p.legalMoves[sq('e1')]!.squares) {
        expect(isCastlingMove(p, sq('e1'), d), isFalse);
      }
    });

    test('false when the rook has moved away (no own rook on the target)', () {
      // Kingside rook is gone from h1; only queenside remains.
      final p = pos('r3k2r/8/8/8/8/8/8/R3K3 w Qkq - 0 1');
      expect(isCastlingMove(p, sq('e1'), sq('h1')), isFalse);
      expect(isCastlingMove(p, sq('e1'), sq('a1')), isTrue);
    });

    test('false for a rook move that happens to land on a rank square', () {
      // Rook a1->e1 style move shares no king, so never a castle.
      final p = pos('4k3/8/8/8/8/8/8/R3K3 w - - 0 1');
      expect(isCastlingMove(p, sq('a1'), sq('d1')), isFalse);
    });
  });

  group('castlingKingDestination', () {
    test('maps king→rook target to the g/c-file landing square', () {
      final p = pos('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
      expect(castlingKingDestination(p, sq('e1'), sq('h1')), sq('g1'));
      expect(castlingKingDestination(p, sq('e1'), sq('a1')), sq('c1'));
    });

    test('leaves ordinary king moves untouched', () {
      final p = pos('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
      for (final dest in ['d1', 'f1', 'd2', 'e2', 'f2']) {
        expect(
          castlingKingDestination(p, sq('e1'), sq(dest)),
          sq(dest),
          reason: 'e1->$dest must not be remapped',
        );
      }
    });

    test('works for black on the back rank', () {
      final p = pos('r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1');
      expect(castlingKingDestination(p, sq('e8'), sq('h8')), sq('g8'));
      expect(castlingKingDestination(p, sq('e8'), sq('a8')), sq('c8'));
    });
  });

  group('toStandardUci', () {
    test('normalises castling to king→destination', () {
      final p = pos('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
      expect(toStandardUci(p, sq('e1'), sq('h1')), 'e1g1');
      expect(toStandardUci(p, sq('e1'), sq('a1')), 'e1c1');
    });

    test('passes normal moves through verbatim', () {
      final p = pos('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
      expect(toStandardUci(p, sq('e1'), sq('e2')), 'e1e2');
      expect(toStandardUci(p, sq('a1'), sq('d1')), 'a1d1');
    });
  });

  group('king legal-move set in an arbitrary no-rights FEN', () {
    test('king has no castling targets when rights are absent', () {
      // King home, rooks present but no rights: only adjacent squares are
      // legal — never the h-/a-file rook squares. (Black king present so the
      // setup is valid.)
      final p = pos('4k3/8/8/8/8/8/8/R3K2R w - - 0 1');
      final dests = p.legalMoves[sq('e1')]!;
      expect(dests.has(sq('h1')), isFalse);
      expect(dests.has(sq('a1')), isFalse);
      // And every legal king destination round-trips to itself (no spurious
      // castle remap) through the shared helper.
      for (final d in dests.squares) {
        expect(castlingKingDestination(p, sq('e1'), d), d);
      }
    });
  });
}
