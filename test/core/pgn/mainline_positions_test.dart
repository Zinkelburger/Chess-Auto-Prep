import 'package:chess_auto_prep/core/pgn/mainline_positions.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// [MainlinePositions] is the memo every viewer navigation reads instead of
/// replaying the game from move 1.  It is mutable, shared by identity of the
/// `moveHistory` list, and extended in place while the user is amending — so
/// what needs pinning is not just "the boards are right" but that it grows,
/// resets and gives up in exactly the cases the viewer puts it in.
void main() {
  List<PgnNodeData> sans(List<String> moves) => [
    for (final san in moves) PgnNodeData(san: san),
  ];

  Position playAll(List<String> moves) {
    var pos = Chess.initial as Position;
    for (final san in moves) {
      pos = pos.play(pos.parseSan(san)!);
    }
    return pos;
  }

  group('positions', () {
    test('holds the board after every ply, with ply 0 the start', () {
      final history = sans(['e4', 'e5', 'Nf3', 'Nc6']);
      final memo = MainlinePositions.of(history, Chess.initial);

      expect(memo.reachablePlies, 4);
      expect(memo.at(0).fen, Chess.initial.fen);
      expect(memo.at(1).fen, playAll(['e4']).fen);
      expect(memo.at(4).fen, playAll(['e4', 'e5', 'Nf3', 'Nc6']).fen);
      expect(memo.positions, hasLength(5));
    });

    test('starts from a custom position', () {
      const fen =
          'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3';
      final start = Chess.fromSetup(Setup.parseFen(fen));
      final memo = MainlinePositions.of(sans(['Bc5']), start);

      expect(memo.at(0).fen, fen);
      expect(memo.reachablePlies, 1);
      expect(memo.at(1).turn, Side.white);
    });

    test('at() clamps out-of-range plies, tryAt() reports them', () {
      final memo = MainlinePositions.of(sans(['e4', 'e5']), Chess.initial);

      expect(memo.at(99).fen, memo.at(2).fen);
      expect(memo.at(-1).fen, Chess.initial.fen);
      expect(memo.tryAt(2), isNotNull);
      expect(memo.tryAt(3), isNull);
      expect(memo.tryAt(-1), isNull);
    });

    test('the exposed list cannot be mutated by a consumer', () {
      final memo = MainlinePositions.of(sans(['e4']), Chess.initial);
      expect(() => memo.positions.add(Chess.initial), throwsUnsupportedError);
    });
  });

  group('memoisation', () {
    test('the same list and start hand back the same instance', () {
      final history = sans(['e4', 'e5']);
      final first = MainlinePositions.of(history, Chess.initial);
      final second = MainlinePositions.of(history, Chess.initial);

      expect(identical(first, second), isTrue);
    });

    test('a different list gets its own memo', () {
      final a = MainlinePositions.of(sans(['e4']), Chess.initial);
      final b = MainlinePositions.of(sans(['e4']), Chess.initial);

      expect(identical(a, b), isFalse);
    });

    test('a reload — same list, new start object — rebuilds', () {
      final history = sans(['e4']);
      final first = MainlinePositions.of(history, Chess.initial);
      final reloaded = MainlinePositions.of(
        history,
        Chess.fromSetup(Setup.parseFen(Chess.initial.fen)),
      );

      expect(identical(first, reloaded), isFalse);
      expect(reloaded.at(1).fen, playAll(['e4']).fen);
    });
  });

  group('following the list as it changes', () {
    test('grows in place when the mainline is extended (amend mode)', () {
      final history = sans(['e4', 'e5']);
      final memo = MainlinePositions.of(history, Chess.initial);
      final atPly1 = memo.at(1);

      history.add(PgnNodeData(san: 'Nf3'));
      final again = MainlinePositions.of(history, Chess.initial);

      expect(identical(again, memo), isTrue, reason: 'same memo, extended');
      expect(again.reachablePlies, 3);
      expect(again.at(3).fen, playAll(['e4', 'e5', 'Nf3']).fen);
      expect(
        identical(again.at(1), atPly1),
        isTrue,
        reason: 'plies already computed are not replayed',
      );
    });

    test('rebuilds from the start when the mainline shrinks', () {
      final history = sans(['e4', 'e5', 'Nf3']);
      final memo = MainlinePositions.of(history, Chess.initial);
      expect(memo.reachablePlies, 3);

      history.removeRange(1, 3);
      final again = MainlinePositions.of(history, Chess.initial);

      expect(identical(again, memo), isTrue);
      expect(again.reachablePlies, 1);
      expect(again.at(1).fen, playAll(['e4']).fen);
      expect(again.tryAt(2), isNull);
    });

    test('a replaced tail is picked up when the list shrinks then grows', () {
      final history = sans(['e4', 'e5', 'Nf3']);
      MainlinePositions.of(history, Chess.initial);

      history.removeLast();
      MainlinePositions.of(history, Chess.initial);
      history.add(PgnNodeData(san: 'd4'));
      final again = MainlinePositions.of(history, Chess.initial);

      expect(again.reachablePlies, 3);
      expect(again.at(3).fen, playAll(['e4', 'e5', 'd4']).fen);
    });
  });

  group('a mainline that will not play', () {
    test('stops at the illegal ply and leaves the rest unreachable', () {
      final memo = MainlinePositions.of(
        sans(['e4', 'Qh8', 'Nf3']),
        Chess.initial,
      );

      expect(memo.reachablePlies, 1);
      expect(memo.at(1).fen, playAll(['e4']).fen);
      expect(memo.tryAt(2), isNull);
      // A cursor parked past the break shows the last board that exists.
      expect(memo.at(3).fen, playAll(['e4']).fen);
    });

    test('does not retry the illegal ply when the list is extended', () {
      final history = sans(['e4', 'Qh8']);
      final memo = MainlinePositions.of(history, Chess.initial);
      expect(memo.reachablePlies, 1);

      history.add(PgnNodeData(san: 'e5'));
      final again = MainlinePositions.of(history, Chess.initial);

      expect(again.reachablePlies, 1, reason: 'still broken at ply 2');
    });

    test('a null move is played, not treated as a break', () {
      final memo = MainlinePositions.of(
        sans(['e4', '--', 'd4']),
        Chess.initial,
      );

      expect(memo.reachablePlies, 3);
      expect(memo.at(3).turn, Side.black);
    });
  });

  group('indexOfFen', () {
    test('finds the ply that reached a position, ply 0 included', () {
      final memo = MainlinePositions.of(
        sans(['e4', 'e5', 'Nf3']),
        Chess.initial,
      );

      expect(memo.indexOfFen(normalizeFen(Chess.initial.fen)), 0);
      expect(memo.indexOfFen(normalizeFen(playAll(['e4']).fen)), 1);
      expect(
        memo.indexOfFen(normalizeFen(playAll(['e4', 'e5', 'Nf3']).fen)),
        3,
      );
    });

    test('ignores the clocks, so a transposed FEN still matches', () {
      final memo = MainlinePositions.of(sans(['e4']), Chess.initial);
      final withOtherClocks = playAll([
        'e4',
      ]).copyWith(halfmoves: 7, fullmoves: 30);

      expect(memo.indexOfFen(normalizeFen(withOtherClocks.fen)), 1);
    });

    test('returns null for a position the mainline never reached', () {
      final memo = MainlinePositions.of(sans(['e4']), Chess.initial);
      expect(memo.indexOfFen(normalizeFen(playAll(['d4']).fen)), isNull);
    });

    test('sees plies added after the first lookup', () {
      final history = sans(['e4']);
      final memo = MainlinePositions.of(history, Chess.initial);
      expect(memo.indexOfFen(normalizeFen(playAll(['e4']).fen)), 1);

      history.add(PgnNodeData(san: 'e5'));
      final again = MainlinePositions.of(history, Chess.initial);

      expect(again.indexOfFen(normalizeFen(playAll(['e4', 'e5']).fen)), 2);
    });

    test('forgets plies dropped by a shrink', () {
      final history = sans(['e4', 'e5']);
      final memo = MainlinePositions.of(history, Chess.initial);
      expect(memo.indexOfFen(normalizeFen(playAll(['e4', 'e5']).fen)), 2);

      history.removeLast();
      final again = MainlinePositions.of(history, Chess.initial);

      expect(again.indexOfFen(normalizeFen(playAll(['e4', 'e5']).fen)), isNull);
      expect(again.indexOfFen(normalizeFen(playAll(['e4']).fen)), 1);
    });
  });
}
