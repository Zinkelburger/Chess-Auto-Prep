import '../models/repertoire_line.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import 'coverage_helpers.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import 'pgn_utils.dart' as pgn_utils;

/// Coverage category filter for the lines browser.
enum CoverageFilter { all, covered, tooShallow, tooDeep, unaccounted }

/// Sortable columns in the lines browser table.
enum LineSortBy { name, moves, ease, coherence, traps, coverage }

/// Per-line quality toggles. Active filters are ANDed together.
enum LineMetricsFilter { hardMoves, trappy, lowCoherence }

/// A move whose ease falls below this is flagged as hard to find.
const double hardMoveEaseThreshold = 0.3;

/// A line whose coherence falls below this is flagged as low coherence.
const double lowCoherenceThreshold = 0.4;

bool isPlaceholderLineTitle(String title) =>
    title.isEmpty ||
    title == '?' ||
    title == 'Repertoire Line' ||
    title == 'Edited Line';

/// Per-line strings derived from the PGN, precomputed once per repertoire
/// change so filter toggles and row builds never re-parse anything.
class LineDisplayData {
  /// Resolved display title: PGN event/title header, or the line name.
  final String title;

  /// Lowercase haystack for search: name, title, and moves with and
  /// without move numbers.
  final String searchText;

  /// Lowercase name, for sorting — a comparator that lower-cases both sides
  /// on every comparison allocates O(n log n) strings per sort.
  final String nameLower;

  const LineDisplayData({
    required this.title,
    required this.searchText,
    required this.nameLower,
  });

  factory LineDisplayData.of(RepertoireLine line) {
    final eventTitle = pgn_utils.extractEventTitle(line.fullPgn);
    final title = !isPlaceholderLineTitle(eventTitle) ? eventTitle : line.name;
    final searchText = [
      line.name,
      eventTitle,
      line.moves.join(' '),
      pgn_utils.formatMovesForSearch(line.moves),
    ].join('\n').toLowerCase();
    return LineDisplayData(
      title: title,
      searchText: searchText,
      nameLower: line.name.toLowerCase(),
    );
  }
}

/// Builds the display/search index for [lines]. O(total PGN size); call it
/// when the repertoire changes, not per filter run.
///
/// Pass the [previous] index and the lines it was built from to make the
/// call incremental: a [RepertoireLine] is immutable and the controller
/// replaces only the lines that changed, so entries whose line object is
/// unchanged are carried over and only new or edited lines are derived.  An
/// autosave or a one-line append then costs one line, not the whole file.
Map<String, LineDisplayData> buildLineDisplayIndex(
  List<RepertoireLine> lines, {
  Map<String, LineDisplayData>? previous,
  List<RepertoireLine>? previousLines,
}) {
  final reusable = <String, RepertoireLine>{
    if (previous != null && previousLines != null)
      for (final line in previousLines) line.id: line,
  };
  final index = <String, LineDisplayData>{};
  for (final line in lines) {
    final data = identical(reusable[line.id], line) ? previous![line.id] : null;
    index[line.id] = data ?? LineDisplayData.of(line);
  }
  return index;
}

/// Rank for coverage sorting: best (covered) first, unanalyzed last.
int? coverageSortRank(LineCoverageInfo? info) {
  final category = info?.leaf?.category;
  return switch (category) {
    LeafCategory.covered => 0,
    LeafCategory.tooDeep => 1,
    LeafCategory.tooShallow => 2,
    null => null,
  };
}

/// Filters and sorts repertoire lines for the browser. Flat list, no grouping.
List<RepertoireLine> filterAndSortLines({
  required List<RepertoireLine> allLines,
  required String searchTerm,
  required bool showOnlyMatchingPosition,
  required List<String> currentMoves,
  required LineSortBy sortBy,
  required bool sortAscending,
  required CoverageFilter coverageFilter,
  required Set<LineMetricsFilter> metricsFilters,
  required Map<String, LineCoverageInfo> lineCoverage,
  required Map<String, LineQualityInfo> lineMetrics,
  CoverageResult? coverageResult,

  /// Precomputed via [buildLineDisplayIndex]; derived on the fly when absent
  /// (tests, one-off callers).
  Map<String, LineDisplayData>? displayIndex,
}) {
  final normalizedSearch = searchTerm.toLowerCase().trim();

  final filtered = allLines.where((line) {
    if (showOnlyMatchingPosition && currentMoves.isNotEmpty) {
      if (!pgn_utils.lineMatchesPosition(line, currentMoves)) {
        return false;
      }
    }

    if (normalizedSearch.isNotEmpty) {
      final searchText =
          displayIndex?[line.id]?.searchText ??
          [
            line.name,
            pgn_utils.extractEventTitle(line.fullPgn),
            line.moves.join(' '),
            pgn_utils.formatMovesForSearch(line.moves),
          ].join('\n').toLowerCase();
      if (!searchText.contains(normalizedSearch)) {
        return false;
      }
    }

    if (coverageFilter != CoverageFilter.all && coverageResult != null) {
      final info = lineCoverage[line.id];
      if (info == null) return false;

      switch (coverageFilter) {
        case CoverageFilter.covered:
          if (info.leaf?.category != LeafCategory.covered) return false;
        case CoverageFilter.tooShallow:
          if (info.leaf?.category != LeafCategory.tooShallow) return false;
        case CoverageFilter.tooDeep:
          if (info.leaf?.category != LeafCategory.tooDeep) return false;
        case CoverageFilter.unaccounted:
          if (info.unaccountedMoves.isEmpty) return false;
        case CoverageFilter.all:
          break;
      }
    }

    if (metricsFilters.isNotEmpty) {
      final m = lineMetrics[line.id];
      if (m == null) return false;
      for (final filter in metricsFilters) {
        final passes = switch (filter) {
          LineMetricsFilter.hardMoves =>
            m.bottleneckQuality != null &&
                m.bottleneckQuality! < hardMoveEaseThreshold,
          LineMetricsFilter.trappy => m.trapCount > 0,
          LineMetricsFilter.lowCoherence =>
            m.coherence != null && m.coherence! < lowCoherenceThreshold,
        };
        if (!passes) return false;
      }
    }

    return true;
  }).toList();

  // Sort key per line; null keys always sort last regardless of direction.
  num? keyOf(RepertoireLine line) => switch (sortBy) {
    LineSortBy.name => null,
    LineSortBy.moves => line.moves.length,
    LineSortBy.ease => lineMetrics[line.id]?.playability,
    LineSortBy.coherence => lineMetrics[line.id]?.coherence,
    LineSortBy.traps => lineMetrics[line.id]?.trapCount,
    LineSortBy.coverage => coverageSortRank(lineCoverage[line.id]),
  };

  String nameKey(RepertoireLine line) =>
      displayIndex?[line.id]?.nameLower ?? line.name.toLowerCase();

  int byName(RepertoireLine a, RepertoireLine b) =>
      nameKey(a).compareTo(nameKey(b));

  filtered.sort((a, b) {
    if (sortBy == LineSortBy.name) {
      final c = byName(a, b);
      return sortAscending ? c : -c;
    }
    final ka = keyOf(a);
    final kb = keyOf(b);
    if (ka == null && kb == null) return byName(a, b);
    if (ka == null) return 1;
    if (kb == null) return -1;
    final c = ka.compareTo(kb);
    if (c != 0) return sortAscending ? c : -c;
    return byName(a, b);
  });

  return filtered;
}
