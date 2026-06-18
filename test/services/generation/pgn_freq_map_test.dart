// WS-A characterization tests for PgnFreqMap (previously untested, 675 LOC).
// Pins the in-memory frequency-map behavior: record, dedup, canonical lookup,
// filtering, and merge.

import 'package:chess_auto_prep/services/eval/eval_canonicalize.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:flutter_test/flutter_test.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  group('PgnFreqMap.recordMove', () {
    test('dedups by UCI and increments count', () {
      final m = PgnFreqMap();
      final key = canonicalizeFen4(_fen);
      m.recordMove(key, 'e2e4', 'e4');
      m.recordMove(key, 'e2e4', 'e4');
      m.recordMove(key, 'd2d4', 'd4');

      final pos = m.get(_fen)!;
      expect(pos.moves.length, 2);
      expect(pos.moves.firstWhere((x) => x.uci == 'e2e4').count, 2);
      expect(pos.moves.firstWhere((x) => x.uci == 'd2d4').count, 1);
    });

    test('get() resolves via canonical 4-field FEN (ignores move counters)', () {
      final m = PgnFreqMap();
      m.recordMove(canonicalizeFen4(_fen), 'e2e4', 'e4');
      // Query with different counters — same position.
      final other = _fen.replaceAll('0 1', '3 9');
      expect(m.get(other), isNotNull);
    });
  });

  group('PgnFreqMap.recordReach', () {
    test('counts reaches per position', () {
      final m = PgnFreqMap();
      final key = canonicalizeFen4(_fen);
      m.recordReach(key);
      m.recordReach(key);
      expect(m.get(_fen)!.reachCount, 2);
    });
  });

  group('PgnFreqMap.filteredMoves', () {
    test('drops moves below minGames and below minProb', () {
      final m = PgnFreqMap();
      final key = canonicalizeFen4(_fen);
      for (var i = 0; i < 8; i++) {
        m.recordMove(key, 'e2e4', 'e4');
      }
      m.recordMove(key, 'd2d4', 'd4'); // 1/9 ≈ 0.11
      m.recordMove(key, 'c2c4', 'c4'); // 1/10 after next… keep simple

      final pos = m.get(_fen)!;
      // minGames=2 removes the singletons; e4 (8) survives.
      final byGames = m.filteredMoves(pos, minGames: 2, minProb: 0.0);
      expect(byGames.map((x) => x.uci), ['e2e4']);

      // minProb=0.2 keeps only moves with >=20% share.
      final byProb = m.filteredMoves(pos, minGames: 1, minProb: 0.2);
      expect(byProb.map((x) => x.uci), ['e2e4']);
    });

    test('returns empty when position has no moves', () {
      final m = PgnFreqMap();
      m.recordReach(canonicalizeFen4(_fen));
      final pos = m.get(_fen)!;
      expect(m.filteredMoves(pos, minGames: 1, minProb: 0.0), isEmpty);
    });
  });

  group('PgnFreqMap.merge', () {
    test('sums move counts, reach counts, and totalGames', () {
      final key = canonicalizeFen4(_fen);
      final a = PgnFreqMap()
        ..totalGames = 3
        ..recordMove(key, 'e2e4', 'e4')
        ..recordReach(key);
      final b = PgnFreqMap()
        ..totalGames = 2
        ..recordMove(key, 'e2e4', 'e4')
        ..recordMove(key, 'd2d4', 'd4')
        ..recordReach(key);

      a.merge(b);

      expect(a.totalGames, 5);
      final pos = a.get(_fen)!;
      expect(pos.reachCount, 2);
      expect(pos.moves.firstWhere((x) => x.uci == 'e2e4').count, 2);
      expect(pos.moves.firstWhere((x) => x.uci == 'd2d4').count, 1);
    });
  });
}
