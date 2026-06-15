import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import 'package:chess_auto_prep/utils/lines_filter_helpers.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireLine _line({
  required String id,
  required String name,
  required List<String> moves,
  String fullPgn = '',
}) {
  return RepertoireLine(
    id: id,
    name: name,
    moves: moves,
    color: 'white',
    startPosition: Chess.initial,
    fullPgn: fullPgn,
  );
}

Map<String, LineQualityInfo> _metricsFor(Iterable<RepertoireLine> lines) {
  return {
    for (final line in lines)
      line.id: LineQualityInfo(
        quality: switch (line.id) {
          'high' => 0.9,
          'mid' => 0.5,
          'low' => 0.1,
          'a' || 'b' || 'c' => 0.5,
          _ => 0.5,
        },
        trapCount: line.id == 'trappy' ? 2 : 0,
      ),
  };
}

void main() {
  group('getLineGroupName', () {
    test('group names use event title when present', () {
      final line = _line(
        id: '1',
        name: 'Line',
        moves: const ['e4', 'e5'],
        fullPgn: '[Event "Sicilian Defense: Najdorf"]\n\n1. e4 e5',
      );

      expect(getLineGroupName(line), 'Sicilian Defense');
    });

    test('group names use first-move fallback when title is placeholder', () {
      final line = _line(
        id: '2',
        name: 'Repertoire Line',
        moves: const ['d4', 'd5', 'c4'],
        fullPgn: '[Event "?"]\n\n1. d4 d5 2. c4',
      );

      expect(getLineGroupName(line), '1.d4 d5');
    });
  });

  group('filterSortAndGroupLines', () {
    test('empty input returns empty output', () {
      final result = filterSortAndGroupLines(
        allLines: const [],
        searchTerm: '',
        showOnlyMatchingPosition: false,
        currentMoves: const [],
        sortBy: LineSortBy.name,
        coverageFilter: CoverageFilter.all,
        metricsFilter: LineMetricsFilter.all,
        lineCoverage: const {},
        lineMetrics: const {},
      );

      expect(result.filtered, isEmpty);
      expect(result.grouped, isEmpty);
      expect(result.groupsToExpand, isEmpty);
    });

    test('search term filters by move text', () {
      final lines = [
        _line(id: 'sic', name: 'Sicilian', moves: const ['e4', 'c5']),
        _line(id: 'french', name: 'French', moves: const ['e4', 'e6']),
      ];

      final result = filterSortAndGroupLines(
        allLines: lines,
        searchTerm: 'c5',
        showOnlyMatchingPosition: false,
        currentMoves: const [],
        sortBy: LineSortBy.name,
        coverageFilter: CoverageFilter.all,
        metricsFilter: LineMetricsFilter.all,
        lineCoverage: const {},
        lineMetrics: _metricsFor(lines),
      );

      expect(result.filtered.map((l) => l.id), ['sic']);
    });

    test('showOnlyMatchingPosition filters to current FEN prefix', () {
      final lines = [
        _line(id: 'match', name: 'Match', moves: const ['e4', 'e5', 'Nf3']),
        _line(id: 'miss', name: 'Miss', moves: const ['e4', 'c5']),
      ];

      final result = filterSortAndGroupLines(
        allLines: lines,
        searchTerm: '',
        showOnlyMatchingPosition: true,
        currentMoves: const ['e4', 'e5'],
        sortBy: LineSortBy.name,
        coverageFilter: CoverageFilter.all,
        metricsFilter: LineMetricsFilter.all,
        lineCoverage: const {},
        lineMetrics: _metricsFor(lines),
      );

      expect(result.filtered.map((l) => l.id), ['match']);
    });

    test('sort by playability is monotonically decreasing', () {
      final lines = [
        _line(id: 'low', name: 'Low', moves: const ['a4']),
        _line(id: 'high', name: 'High', moves: const ['e4']),
        _line(id: 'mid', name: 'Mid', moves: const ['d4']),
      ];

      final result = filterSortAndGroupLines(
        allLines: lines,
        searchTerm: '',
        showOnlyMatchingPosition: false,
        currentMoves: const [],
        sortBy: LineSortBy.playability,
        coverageFilter: CoverageFilter.all,
        metricsFilter: LineMetricsFilter.all,
        lineCoverage: const {},
        lineMetrics: _metricsFor(lines),
      );

      final scores = result.filtered
          .map((l) => _metricsFor(lines)[l.id]!.playability!)
          .toList();
      for (var i = 0; i < scores.length - 1; i++) {
        expect(scores[i], greaterThanOrEqualTo(scores[i + 1]));
      }
    });

    test('sort is stable for equal playability values', () {
      final lines = [
        _line(id: 'a', name: 'Alpha', moves: const ['e4']),
        _line(id: 'b', name: 'Bravo', moves: const ['d4']),
        _line(id: 'c', name: 'Charlie', moves: const ['c4']),
      ];

      final result = filterSortAndGroupLines(
        allLines: lines,
        searchTerm: '',
        showOnlyMatchingPosition: false,
        currentMoves: const [],
        sortBy: LineSortBy.playability,
        coverageFilter: CoverageFilter.all,
        metricsFilter: LineMetricsFilter.all,
        lineCoverage: const {},
        lineMetrics: _metricsFor(lines),
      );

      expect(result.filtered.map((l) => l.id), ['a', 'b', 'c']);
    });

    test('filtering then sorting equals sorting then filtering on result set',
        () {
      final lines = [
        _line(id: 'sic', name: 'Sicilian', moves: const ['e4', 'c5']),
        _line(id: 'french', name: 'French', moves: const ['e4', 'e6']),
        _line(id: 'queens', name: 'Queens', moves: const ['d4', 'd5']),
      ];
      final metrics = _metricsFor(lines);

      final filterThenSort = filterSortAndGroupLines(
        allLines: lines,
        searchTerm: 'e4',
        showOnlyMatchingPosition: false,
        currentMoves: const [],
        sortBy: LineSortBy.playability,
        coverageFilter: CoverageFilter.all,
        metricsFilter: LineMetricsFilter.all,
        lineCoverage: const {},
        lineMetrics: metrics,
      );

      final sortedAll = filterSortAndGroupLines(
        allLines: lines,
        searchTerm: '',
        showOnlyMatchingPosition: false,
        currentMoves: const [],
        sortBy: LineSortBy.playability,
        coverageFilter: CoverageFilter.all,
        metricsFilter: LineMetricsFilter.all,
        lineCoverage: const {},
        lineMetrics: metrics,
      );

      final sortThenFilter = sortedAll.filtered
          .where((line) =>
              line.name.toLowerCase().contains('e4') ||
              line.moves.join(' ').toLowerCase().contains('e4'))
          .toList();

      expect(
        filterThenSort.filtered.map((l) => l.id),
        sortThenFilter.map((l) => l.id),
      );
    });

    test('metrics filter trappy does not mutate input lines', () {
      final lines = [
        _line(id: 'plain', name: 'Plain', moves: const ['e4']),
        _line(id: 'trappy', name: 'Trappy', moves: const ['d4']),
      ];
      final snapshot = List<RepertoireLine>.from(lines);

      final result = filterSortAndGroupLines(
        allLines: lines,
        searchTerm: '',
        showOnlyMatchingPosition: false,
        currentMoves: const [],
        sortBy: LineSortBy.name,
        coverageFilter: CoverageFilter.all,
        metricsFilter: LineMetricsFilter.trappy,
        lineCoverage: const {},
        lineMetrics: _metricsFor(lines),
      );

      expect(result.filtered.map((l) => l.id), ['trappy']);
      expect(lines.map((l) => l.id), snapshot.map((l) => l.id));
    });
  });
}
