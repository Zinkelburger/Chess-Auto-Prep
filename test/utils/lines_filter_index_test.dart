/// The lines browser's display index is derived per line and reused across
/// list swaps, so an autosave or an append costs one line, not the file.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/utils/lines_filter_helpers.dart';
import 'package:dartchess/dartchess.dart';

RepertoireLine _line(String id, String name, List<String> moves) =>
    RepertoireLine(
      id: id,
      name: name,
      moves: moves,
      color: 'white',
      fullPgn: '[Event "$name"]\n\n${moves.join(' ')} *',
      startPosition: Chess.initial,
    );

void main() {
  test('entries for unchanged line objects are carried over', () {
    final a = _line('a', 'Alpha', ['e4']);
    final b = _line('b', 'Beta', ['d4']);
    final first = buildLineDisplayIndex([a, b]);

    final bEdited = _line('b', 'Beta edited', ['d4', 'd5']);
    final c = _line('c', 'Gamma', ['c4']);
    final second = buildLineDisplayIndex(
      [a, bEdited, c],
      previous: first,
      previousLines: [a, b],
    );

    expect(identical(second['a'], first['a']), isTrue);
    expect(identical(second['b'], first['b']), isFalse);
    expect(second['b']!.title, 'Beta edited');
    expect(second['c']!.nameLower, 'gamma');
    expect(second.length, 3);
  });

  test('a removed line drops out of the index', () {
    final a = _line('a', 'Alpha', ['e4']);
    final b = _line('b', 'Beta', ['d4']);
    final first = buildLineDisplayIndex([a, b]);
    final second = buildLineDisplayIndex(
      [b],
      previous: first,
      previousLines: [a, b],
    );
    expect(second.keys, ['b']);
  });

  test('the lowercase name sorts without re-lowercasing per compare', () {
    final lines = [
      _line('1', 'beta', ['e4']),
      _line('2', 'Alpha', ['d4']),
      _line('3', 'gamma', ['c4']),
    ];
    final sorted = filterAndSortLines(
      allLines: lines,
      searchTerm: '',
      showOnlyMatchingPosition: false,
      currentMoves: const [],
      sortBy: LineSortBy.name,
      sortAscending: true,
      coverageFilter: CoverageFilter.all,
      metricsFilters: const {},
      lineCoverage: const {},
      lineMetrics: const {},
      displayIndex: buildLineDisplayIndex(lines),
    );
    expect(sorted.map((l) => l.name), ['Alpha', 'beta', 'gamma']);
  });
}
