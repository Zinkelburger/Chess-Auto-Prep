import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/traps/services/trap_tour_order.dart';

TrapLineInfo _trap(
  List<String> moves, {
  double surplus = 0.1,
  String? fen,
  String? opening,
}) {
  return TrapLineInfo(
    movesSan: moves,
    trapScore: 0.5,
    popularProb: 0.4,
    popularMove: 'Nd7',
    bestMove: 'b4',
    popularEvalCp: 252,
    bestEvalCp: 10,
    evalDiffCp: 200,
    cumulativeProb: 0.01,
    trickSurplus: surplus,
    expectimaxValue: 0.59,
    wpEval: 0.51,
    fen: fen,
    openingName: opening,
  );
}

void main() {
  group('trap tour order', () {
    test('sortTrapsForTour orders by trick surplus descending', () {
      final traps = [
        _trap(['e4'], surplus: 0.05),
        _trap(['d4'], surplus: 0.20),
        _trap(['c4'], surplus: 0.12),
      ];

      final sorted = sortTrapsForTour(traps);
      expect(sorted.map((t) => t.movesSan.first).toList(), ['d4', 'c4', 'e4']);
      // The caller's list is left alone.
      expect(traps.map((t) => t.movesSan.first).toList(), ['e4', 'd4', 'c4']);
    });

    test('indexOfTrap finds trap by moves', () {
      final a = _trap(['e4', 'e5'], fen: 'fen-a');
      final b = _trap(['d4', 'd5'], fen: 'fen-b');
      final sorted = sortTrapsForTour([a, b]);

      expect(indexOfTrap(sorted, b), 1);
      expect(isSameTrap(a, a), isTrue);
      expect(isSameTrap(a, b), isFalse);
    });

    test('indexOfTrap returns -1 for a trap that is not in the list', () {
      final sorted = sortTrapsForTour([
        _trap(['e4'], fen: 'f1'),
      ]);
      expect(indexOfTrap(sorted, _trap(['d4'], fen: 'f2')), -1);
    });

    test('isSameTrap matches equal move sequences without a FEN', () {
      expect(
        isSameTrap(_trap(['e4', 'e5']), _trap(['e4', 'e5'], surplus: 0.9)),
        isTrue,
      );
    });

    group('trapTourTitle', () {
      test('numbers the trap in tour order, not list order', () {
        final weak = _trap(['e4'], surplus: 0.05, opening: 'Open Game');
        final strong = _trap(['d4'], surplus: 0.20);
        // Passed in weakest-first; the title must still say #2 for the weak one.
        expect(trapTourTitle([weak, strong], weak), 'Trap #2 · Open Game');
        expect(trapTourTitle([weak, strong], strong), 'Trap #1');
      });

      test('falls back to a bare label for an unknown trap', () {
        expect(
          trapTourTitle([
            _trap(['e4'], fen: 'f1'),
          ], _trap(['d4'], fen: 'f2', opening: 'Queen\'s Gambit')),
          "Trap · Queen's Gambit",
        );
      });
    });

    test('TrapIndexService.allTraps exposes load order', () {
      final index = TrapIndexService([
        _trap(['e4'], fen: 'f1'),
        _trap(['d4'], fen: 'f2'),
      ]);
      expect(index.allTraps.length, 2);
      expect(index.allTraps.first.movesSan, ['e4']);
    });
  });
}
