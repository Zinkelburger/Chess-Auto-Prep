import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/explorer_response.dart';

void main() {
  group('ExplorerResponse totals', () {
    test('take the API-level result split when present', () {
      final r = ExplorerResponse.fromJson({
        'white': 500,
        'draws': 300,
        'black': 200,
        'moves': [
          {'san': 'e4', 'uci': 'e2e4', 'white': 50, 'draws': 30, 'black': 20},
        ],
      }, fen: 'f');
      expect(r.whiteTotal, 500);
      expect(r.drawTotal, 300);
      expect(r.blackTotal, 200);
      // Game count still follows the listed moves, as before.
      expect(r.totalGames, 100);
    });

    test('fall back to summing the moves when the split is absent', () {
      const r = ExplorerResponse(
        fen: 'f',
        totalGames: 130,
        moves: [
          ExplorerMove(
            san: 'e4',
            uci: 'e2e4',
            white: 50,
            draws: 30,
            black: 20,
            playRate: 77,
          ),
          ExplorerMove(
            san: 'd4',
            uci: 'd2d4',
            white: 10,
            draws: 10,
            black: 10,
            playRate: 23,
          ),
        ],
      );
      expect(r.whiteTotal, 60);
      expect(r.drawTotal, 40);
      expect(r.blackTotal, 30);
    });
  });
}
