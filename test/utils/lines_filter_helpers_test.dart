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

List<RepertoireLine> _run(
  List<RepertoireLine> lines, {
  String searchTerm = '',
  bool showOnlyMatchingPosition = false,
  List<String> currentMoves = const [],
  LineSortBy sortBy = LineSortBy.name,
  bool sortAscending = true,
  CoverageFilter coverageFilter = CoverageFilter.all,
  Set<LineMetricsFilter> metricsFilters = const {},
  Map<String, LineQualityInfo>? lineMetrics,
}) {
  return filterAndSortLines(
    allLines: lines,
    searchTerm: searchTerm,
    showOnlyMatchingPosition: showOnlyMatchingPosition,
    currentMoves: currentMoves,
    sortBy: sortBy,
    sortAscending: sortAscending,
    coverageFilter: coverageFilter,
    metricsFilters: metricsFilters,
    lineCoverage: const {},
    lineMetrics: lineMetrics ?? _metricsFor(lines),
  );
}

void main() {
  group('filterAndSortLines', () {
    test('empty input returns empty output', () {
      expect(_run(const []), isEmpty);
    });

    test('search term filters by move text', () {
      final lines = [
        _line(id: 'sic', name: 'Sicilian', moves: const ['e4', 'c5']),
        _line(id: 'french', name: 'French', moves: const ['e4', 'e6']),
      ];

      expect(_run(lines, searchTerm: 'c5').map((l) => l.id), ['sic']);
    });

    test('showOnlyMatchingPosition filters to current FEN prefix', () {
      final lines = [
        _line(id: 'match', name: 'Match', moves: const ['e4', 'e5', 'Nf3']),
        _line(id: 'miss', name: 'Miss', moves: const ['e4', 'c5']),
      ];

      final result = _run(
        lines,
        showOnlyMatchingPosition: true,
        currentMoves: const ['e4', 'e5'],
      );

      expect(result.map((l) => l.id), ['match']);
    });

    test('sort by ease ascending is monotonically increasing', () {
      final lines = [
        _line(id: 'high', name: 'High', moves: const ['e4']),
        _line(id: 'low', name: 'Low', moves: const ['a4']),
        _line(id: 'mid', name: 'Mid', moves: const ['d4']),
      ];

      final result = _run(lines, sortBy: LineSortBy.ease);

      expect(result.map((l) => l.id), ['low', 'mid', 'high']);
    });

    test('sort by ease descending reverses the order', () {
      final lines = [
        _line(id: 'low', name: 'Low', moves: const ['a4']),
        _line(id: 'high', name: 'High', moves: const ['e4']),
        _line(id: 'mid', name: 'Mid', moves: const ['d4']),
      ];

      final result =
          _run(lines, sortBy: LineSortBy.ease, sortAscending: false);

      expect(result.map((l) => l.id), ['high', 'mid', 'low']);
    });

    test('lines without a sort key always sort last', () {
      final lines = [
        _line(id: 'nometrics', name: 'Aardvark', moves: const ['b4']),
        _line(id: 'high', name: 'High', moves: const ['e4']),
      ];
      final metrics = _metricsFor(lines)..remove('nometrics');

      for (final ascending in [true, false]) {
        final result = _run(
          lines,
          sortBy: LineSortBy.ease,
          sortAscending: ascending,
          lineMetrics: metrics,
        );
        expect(result.last.id, 'nometrics',
            reason: 'ascending=$ascending should keep null keys last');
      }
    });

    test('ties break by name for equal ease values', () {
      final lines = [
        _line(id: 'c', name: 'Charlie', moves: const ['c4']),
        _line(id: 'a', name: 'Alpha', moves: const ['e4']),
        _line(id: 'b', name: 'Bravo', moves: const ['d4']),
      ];

      final result = _run(lines, sortBy: LineSortBy.ease);

      expect(result.map((l) => l.id), ['a', 'b', 'c']);
    });

    test('sort by moves orders by line length', () {
      final lines = [
        _line(id: 'long', name: 'Long', moves: const ['e4', 'e5', 'Nf3']),
        _line(id: 'short', name: 'Short', moves: const ['e4']),
      ];

      expect(
        _run(lines, sortBy: LineSortBy.moves).map((l) => l.id),
        ['short', 'long'],
      );
      expect(
        _run(lines, sortBy: LineSortBy.moves, sortAscending: false)
            .map((l) => l.id),
        ['long', 'short'],
      );
    });

    test('metrics filter trappy does not mutate input lines', () {
      final lines = [
        _line(id: 'plain', name: 'Plain', moves: const ['e4']),
        _line(id: 'trappy', name: 'Trappy', moves: const ['d4']),
      ];
      final snapshot = List<RepertoireLine>.from(lines);

      final result =
          _run(lines, metricsFilters: {LineMetricsFilter.trappy});

      expect(result.map((l) => l.id), ['trappy']);
      expect(lines.map((l) => l.id), snapshot.map((l) => l.id));
    });

    test('multiple metrics filters are ANDed together', () {
      final lines = [
        _line(id: 'trappy', name: 'Trappy', moves: const ['d4']),
        _line(id: 'plain', name: 'Plain', moves: const ['e4']),
      ];
      // Trappy but no hard move: both filters together should exclude it.
      final result = _run(
        lines,
        metricsFilters: {
          LineMetricsFilter.trappy,
          LineMetricsFilter.hardMoves,
        },
      );

      expect(result, isEmpty);
    });
  });
}
