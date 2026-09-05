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

  group('ExplorerResponse games', () {
    Map<String, dynamic> json() => {
      'white': 3,
      'draws': 1,
      'black': 1,
      'moves': [
        {'san': 'Nf3', 'uci': 'g1f3', 'white': 2, 'draws': 1, 'black': 1},
        {'san': 'Nc3', 'uci': 'b1c3', 'white': 1, 'draws': 0, 'black': 0},
      ],
      'topGames': [
        {
          'id': 'abc123',
          'winner': 'white',
          'white': {'name': 'Carlsen, Magnus', 'rating': 2830},
          'black': {'name': 'Nakamura, Hikaru', 'rating': 2790},
          'year': 2024,
          'month': '2024-03',
          'uci': 'g1f3',
        },
        {
          'id': 'drawn1',
          'winner': null,
          'white': {'name': 'A', 'rating': 2500},
          'black': {'name': 'B', 'rating': 2500},
          'year': 2023,
          'uci': 'b1c3',
        },
      ],
      'recentGames': [
        {
          'id': 'rec1',
          'winner': 'black',
          'white': {'name': 'C', 'rating': 2400},
          'black': {'name': 'D', 'rating': 2450},
          'year': 2025,
          'month': '2025-01',
          'uci': 'g1f3',
        },
      ],
    };

    test('are parsed with the row SAN and the result spelled out', () {
      final r = ExplorerResponse.fromJson(
        json(),
        fen: 'x',
        gameSource: ExplorerGameSource.masters,
      );
      expect(r.topGames.length, 2);
      final top = r.topGames.first;
      expect(top.id, 'abc123');
      expect(top.source, ExplorerGameSource.masters);
      expect(top.white, 'Carlsen, Magnus');
      expect(top.whiteElo, 2830);
      expect(top.result, '1-0');
      expect(top.san, 'Nf3');
      expect(top.when, '2024-03');
      expect(top.topElo, 2830);
      // A present-but-null winner is a draw; a missing move is a blank SAN.
      expect(r.topGames.last.result, '1/2-1/2');
      expect(r.topGames.last.when, '2023');
      expect(r.recentGames.single.result, '0-1');
    });

    test('are left out unless the caller names a source', () {
      final r = ExplorerResponse.fromJson(json(), fen: 'x');
      expect(r.topGames, isEmpty);
      expect(r.recentGames, isEmpty);
      expect(r.moves.length, 2, reason: 'the table is unaffected');
    });
  });
}
