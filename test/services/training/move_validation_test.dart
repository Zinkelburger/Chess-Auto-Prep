import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/completed_move.dart';
import 'package:chess_auto_prep/services/training/move_validation.dart';

/// These cases previously ran through a fully-constructed
/// `TrainingSessionController` because the logic lived in a private part-mixin.
/// It is a pure function of (position, played move, expected SAN), so it is now
/// tested as one.
CompletedMove _move({required String uci, required String san}) =>
    CompletedMove(
      from: '',
      to: '',
      san: san,
      fenBefore: '',
      fenAfter: '',
      uci: uci,
    );

void main() {
  final start = Chess.initial;

  group('isCorrectUserMove', () {
    test('matches by resulting position, not by move text', () {
      expect(
        isCorrectUserMove(start, _move(uci: 'e2e4', san: 'e4'), 'e4'),
        isTrue,
      );
    });

    test('a different legal move is rejected even with a legal UCI', () {
      expect(
        isCorrectUserMove(start, _move(uci: 'd2d4', san: 'd4'), 'e4'),
        isFalse,
      );
    });

    group('falls back to normalized SAN when the UCI cannot be played', () {
      // e2e5 is illegal from the start position, so the position comparison
      // throws and the SAN fallback decides.

      test('annotation glyphs are ignored', () {
        expect(
          isCorrectUserMove(start, _move(uci: 'e2e5', san: 'e4!?'), 'e4'),
          isTrue,
        );
      });

      test('case and check markers are ignored', () {
        expect(
          isCorrectUserMove(start, _move(uci: 'e2e5', san: 'E4+'), 'e4'),
          isTrue,
        );
      });

      test('a genuinely different move still fails', () {
        expect(
          isCorrectUserMove(start, _move(uci: 'e2e5', san: 'd4'), 'e4'),
          isFalse,
        );
      });
    });

    test('unparsable expected SAN never matches', () {
      expect(
        isCorrectUserMove(start, _move(uci: 'e2e4', san: 'Zz9'), 'Zz9'),
        isFalse,
      );
    });

    test('an unparsable played UCI is rejected outright', () {
      // Note the asymmetry with the group above: a UCI that parses but cannot
      // be played throws and reaches the SAN fallback, whereas one that fails
      // to parse returns false immediately. Pinned as-is because the UCI comes
      // from the board widget and is always well-formed in practice — the
      // branch is defensive, and no caller depends on it falling back.
      expect(
        isCorrectUserMove(start, _move(uci: 'not-a-move', san: 'e4'), 'e4'),
        isFalse,
      );
    });

    test('a transposing move counts as correct', () {
      // Both orderings reach the same position, which is the whole reason the
      // check compares positions instead of strings.
      final afterNf3 = start.play(Move.parse('g1f3')!);
      expect(
        isCorrectUserMove(afterNf3, _move(uci: 'e7e5', san: 'e5'), 'e5'),
        isTrue,
      );
    });
  });
}
