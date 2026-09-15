import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/legal_destination_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LegalDestinationCache', () {
    test('lists every legal move of the start position with its FEN', () {
      final cache = LegalDestinationCache();
      final entry = cache.lookup(kStandardStartFen);
      expect(entry, isNotNull);
      expect(entry!.destinations, hasLength(20));
      final e4 = entry.destinations.firstWhere((d) => d.move.uci == 'e2e4');
      expect(
        e4.fen,
        startsWith('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b'),
      );
    });

    test('expands a promotion into four destinations', () {
      const fen = '4k3/P7/8/8/8/8/8/4K3 w - - 0 1';
      final entry = LegalDestinationCache().lookup(fen)!;
      final promotions = entry.destinations
          .where((d) => d.move.uci.startsWith('a7a8'))
          .map((d) => d.move.uci)
          .toList();
      expect(promotions, unorderedEquals(['a7a8q', 'a7a8n', 'a7a8r', 'a7a8b']));
    });

    test('returns null for a FEN that does not parse', () {
      expect(LegalDestinationCache().lookup('not a fen'), isNull);
      expect(LegalDestinationCache().length, 0);
    });

    test('evicts the least recently used position past capacity', () {
      final cache = LegalDestinationCache(capacity: 2);
      const a = kStandardStartFen;
      const b = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      const c = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';
      final first = cache.lookup(a);
      cache.lookup(b);
      // Touch [a] so [b] becomes the oldest entry.
      expect(identical(cache.lookup(a), first), isTrue);
      cache.lookup(c);
      expect(cache.length, 2);
      // [a] survived the eviction; a fresh lookup still hits the same entry.
      expect(identical(cache.lookup(a), first), isTrue);
    });
  });
}
