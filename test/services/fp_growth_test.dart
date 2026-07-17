import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/fp_growth.dart';

void main() {
  group('FPGrowthMiner', () {
    test('mines simple frequent patterns', () {
      final transactions = [
        {'a', 'b', 'c'},
        {'a', 'b', 'd'},
        {'a', 'b', 'c'},
        {'a', 'c', 'd'},
        {'a', 'b', 'c', 'd'},
      ];

      final miner = FPGrowthMiner(minSupport: 0.4, transactions: transactions);
      final results = miner.mine();

      expect(results, isNotEmpty);

      final abSupport = results.firstWhere(
        (r) => r.items.containsAll({'a', 'b'}) && r.items.length == 2,
        orElse: () => const FrequentItemset(items: {}, support: 0, count: 0),
      );
      expect(abSupport.count, greaterThanOrEqualTo(3));
    });

    test('returns empty for no transactions', () {
      final miner = FPGrowthMiner(minSupport: 0.5, transactions: []);
      expect(miner.mine(), isEmpty);
    });

    test('returns empty when minSupport too high', () {
      final transactions = [
        {'a', 'b'},
        {'c', 'd'},
        {'e', 'f'},
      ];
      final miner = FPGrowthMiner(minSupport: 0.9, transactions: transactions);
      expect(miner.mine(), isEmpty);
    });

    test('finds single-item frequent sets', () {
      final transactions = [
        {'Nf3', 'g3', 'Bg2'},
        {'Nf3', 'd4', 'c4'},
        {'Nf3', 'g3', 'Bg2', 'd3'},
        {'e4', 'Nf3'},
      ];

      final miner = FPGrowthMiner(minSupport: 0.5, transactions: transactions);
      final results = miner.mine();
      final nf3Sets = results.where((r) => r.items.contains('Nf3'));
      expect(nf3Sets, isNotEmpty);
    });

    test('maximalItemsets removes proper subsets', () {
      final all = [
        const FrequentItemset(items: {'a', 'b', 'c'}, support: 0.4, count: 4),
        const FrequentItemset(items: {'a', 'b'}, support: 0.6, count: 6),
        const FrequentItemset(items: {'d', 'e'}, support: 0.5, count: 5),
        const FrequentItemset(items: {'a'}, support: 0.8, count: 8),
      ];

      final miner = FPGrowthMiner(minSupport: 0.1, transactions: []);
      final maximal = miner.maximalItemsets(all);

      expect(maximal.length, 2);
      expect(maximal.any((m) => m.items.containsAll({'a', 'b', 'c'})), isTrue);
      expect(maximal.any((m) => m.items.containsAll({'d', 'e'})), isTrue);
      expect(maximal.any((m) => m.items.length == 1), isFalse);
    });

    test('chess-like itemsets produce meaningful clusters', () {
      final transactions = [
        {'d4', 'c4', 'Nc3', 'e4', 'Nf3', 'Be2'},
        {'d4', 'c4', 'Nc3', 'Nf3', 'Bg5'},
        {'d4', 'c4', 'Nc3', 'e4', 'Nf3'},
        {'Nf3', 'g3', 'Bg2', 'd3', 'O-O'},
        {'Nf3', 'g3', 'Bg2', 'O-O', 'c4'},
        {'Nf3', 'g3', 'Bg2', 'd3'},
        {'e4', 'd4', 'Nc3', 'f4'},
        {'e4', 'Nf3', 'Bb5'},
      ];

      final miner = FPGrowthMiner(minSupport: 0.25, transactions: transactions);
      final results = miner.mine();
      final maximal = miner.maximalItemsets(results);

      expect(maximal, isNotEmpty);

      final fianchetto = maximal.where(
        (m) => m.items.contains('g3') && m.items.contains('Bg2'),
      );
      expect(fianchetto, isNotEmpty);
    });
  });
}
