import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/services/coherence_service.dart';
import 'package:chess_auto_prep/services/fp_growth.dart';

RepertoireLine _makeLine(String id, List<String> moves,
    {double importance = 0.05}) {
  return RepertoireLine(
    id: id,
    name: id,
    moves: moves,
    color: 'white',
    startPosition: Chess.initial,
    fullPgn: '',
    importance: importance,
  );
}

void main() {
  group('extractItemset', () {
    test('extracts white moves at even indices', () {
      final line = _makeLine('l1', ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']);
      final items = extractItemset(line, true);
      expect(items, {'e4', 'Nf3', 'Bb5'});
    });

    test('extracts black moves at odd indices', () {
      final line = _makeLine('l1', ['e4', 'e5', 'Nf3', 'Nc6']);
      final items = extractItemset(line, false);
      expect(items, {'e5', 'Nc6'});
    });
  });

  group('lineCoherence', () {
    test('line matching an MFI has positive coherence', () {
      final itemset = {'Nf3', 'g3', 'Bg2', 'd3'};
      final maximalItemsets = [
        const FrequentItemset(
            items: {'Nf3', 'g3', 'Bg2'}, support: 0.6, count: 6),
      ];
      final score = lineCoherence(itemset, maximalItemsets);
      expect(score, greaterThan(0));
    });

    test('line matching no MFI has zero coherence', () {
      final itemset = {'e4', 'd4', 'f4'};
      final maximalItemsets = [
        const FrequentItemset(
            items: {'Nf3', 'g3', 'Bg2'}, support: 0.6, count: 6),
      ];
      final score = lineCoherence(itemset, maximalItemsets);
      expect(score, 0);
    });

    test('empty maximal itemsets yield zero', () {
      final score = lineCoherence({'a', 'b'}, []);
      expect(score, 0);
    });
  });

  group('computeRiskWeightedCoherence', () {
    test('penalizes low-prob incoherent lines', () {
      final lineCoherences = {
        'l1': 0.8,
        'l2': 0.1,
      };
      final lineProbabilities = {
        'l1': 0.5,
        'l2': 0.01,
      };

      final rwc = computeRiskWeightedCoherence(
          lineCoherences, lineProbabilities);
      expect(rwc, greaterThan(0));
      expect(rwc, lessThan(1));
    });

    test('returns zero for empty input', () {
      final rwc = computeRiskWeightedCoherence({}, {});
      expect(rwc, 0);
    });
  });

  group('CoherenceService', () {
    test('compute produces clusters for coherent repertoire', () async {
      final lines = [
        _makeLine('l1', ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'Bg7', 'e4']),
        _makeLine('l2', ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Bg5']),
        _makeLine('l3', ['d4', 'Nf6', 'c4', 'e6', 'Nc3', 'Bb4', 'e3']),
        _makeLine('l4', ['d4', 'Nf6', 'c4', 'g6', 'Nc3', 'Bg7', 'Nf3']),
        _makeLine('l5', ['d4', 'd5', 'c4', 'c6', 'Nc3', 'Nf6', 'e3']),
        _makeLine('l6', ['Nf3', 'd5', 'g3', 'Nf6', 'Bg2', 'e6', 'd3']),
        _makeLine('l7', ['Nf3', 'Nf6', 'g3', 'g6', 'Bg2', 'Bg7', 'O-O']),
      ];

      final service = CoherenceService();
      await service.compute(lines: lines, playAsWhite: true);

      expect(service.result, isNotNull);
      expect(service.result!.clusters, isNotEmpty);
      expect(service.result!.globalCoherence, greaterThan(0));
    });

    test('skips computation for too few lines', () async {
      final lines = [
        _makeLine('l1', ['e4', 'e5']),
        _makeLine('l2', ['d4', 'd5']),
      ];

      final service = CoherenceService();
      await service.compute(lines: lines, playAsWhite: true);
      expect(service.result, isNull);
    });

    test('invalidate clears result', () async {
      final lines = List.generate(
          6, (i) => _makeLine('l$i', ['d4', 'Nf6', 'c4', 'g6', 'Nc3']));

      final service = CoherenceService();
      await service.compute(lines: lines, playAsWhite: true);
      expect(service.result, isNotNull);

      service.invalidate();
      expect(service.result, isNull);
    });
  });
}
