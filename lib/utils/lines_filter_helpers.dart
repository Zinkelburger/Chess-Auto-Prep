import '../models/repertoire_line.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../utils/coverage_helpers.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import '../utils/pgn_utils.dart' as pgn_utils;

/// Coverage category filter for the lines browser.
enum CoverageFilter {
  all,
  covered,
  tooShallow,
  tooDeep,
  unaccounted,
}

/// Sort order for the lines browser.
enum LineSortBy {
  name,
  length,
  position,
  quality,
  playability,
  traps,
  coherence,
}

/// Quality/metrics filter for the lines browser.
enum LineMetricsFilter {
  all,
  hardMoves,
  trappy,
  lowCoherence,
}

bool isPlaceholderLineTitle(String title) =>
    title.isEmpty ||
    title == '?' ||
    title == 'Repertoire Line' ||
    title == 'Edited Line';

String getLineGroupName(RepertoireLine line) {
  final eventTitle = pgn_utils.extractEventTitle(line.fullPgn);
  if (!isPlaceholderLineTitle(eventTitle)) {
    final parts = eventTitle.split(RegExp(r'[:\-–#]'));
    if (parts.isNotEmpty) {
      return parts[0].trim();
    }
    return eventTitle;
  }

  if (line.moves.length >= 2) {
    return '1.${line.moves[0]} ${line.moves[1]}';
  } else if (line.moves.isNotEmpty) {
    return '1.${line.moves[0]}';
  }
  return 'Other';
}

/// Filters, sorts, and groups repertoire lines for the browser.
({
  List<RepertoireLine> filtered,
  Map<String, List<RepertoireLine>> grouped,
  Set<String> groupsToExpand,
}) filterSortAndGroupLines({
  required List<RepertoireLine> allLines,
  required String searchTerm,
  required bool showOnlyMatchingPosition,
  required List<String> currentMoves,
  required LineSortBy sortBy,
  required CoverageFilter coverageFilter,
  required LineMetricsFilter metricsFilter,
  required Map<String, LineCoverageInfo> lineCoverage,
  required Map<String, LineQualityInfo> lineMetrics,
  CoverageResult? coverageResult,
}) {
  final normalizedSearch = searchTerm.toLowerCase().trim();

  var filtered = allLines.where((line) {
    if (showOnlyMatchingPosition && currentMoves.isNotEmpty) {
      if (!pgn_utils.lineMatchesPosition(line, currentMoves)) {
        return false;
      }
    }

    if (normalizedSearch.isNotEmpty) {
      final lineName = line.name.toLowerCase();
      final eventTitle =
          pgn_utils.extractEventTitle(line.fullPgn).toLowerCase();
      final movesString = line.moves.join(' ').toLowerCase();
      final formattedMoves =
          pgn_utils.formatMovesForSearch(line.moves).toLowerCase();

      if (!lineName.contains(normalizedSearch) &&
          !eventTitle.contains(normalizedSearch) &&
          !movesString.contains(normalizedSearch) &&
          !formattedMoves.contains(normalizedSearch)) {
        return false;
      }
    }

    if (coverageFilter != CoverageFilter.all && coverageResult != null) {
      final info = lineCoverage[line.id];
      if (info == null) return false;

      switch (coverageFilter) {
        case CoverageFilter.covered:
          return info.leaf?.category == LeafCategory.covered;
        case CoverageFilter.tooShallow:
          return info.leaf?.category == LeafCategory.tooShallow;
        case CoverageFilter.tooDeep:
          return info.leaf?.category == LeafCategory.tooDeep;
        case CoverageFilter.unaccounted:
          return info.unaccountedMoves.isNotEmpty;
        case CoverageFilter.all:
          return true;
      }
    }

    return true;
  }).toList();

  if (metricsFilter != LineMetricsFilter.all) {
    filtered = filtered.where((line) {
      final m = lineMetrics[line.id];
      if (m == null) return false;
      return switch (metricsFilter) {
        LineMetricsFilter.all => true,
        LineMetricsFilter.hardMoves =>
          m.bottleneckQuality != null && m.bottleneckQuality! < 0.3,
        LineMetricsFilter.trappy => m.trapCount > 0,
        LineMetricsFilter.lowCoherence =>
          m.coherence != null && m.coherence! < 0.4,
      };
    }).toList();
  }

  switch (sortBy) {
    case LineSortBy.length:
      filtered.sort((a, b) => b.moves.length.compareTo(a.moves.length));
    case LineSortBy.position:
      filtered.sort((a, b) {
        final aMatch = pgn_utils.getPositionMatchDepth(a, currentMoves);
        final bMatch = pgn_utils.getPositionMatchDepth(b, currentMoves);
        if (aMatch != bMatch) return bMatch.compareTo(aMatch);
        return a.name.compareTo(b.name);
      });
    case LineSortBy.quality:
      filtered.sort((a, b) {
        final aq = lineMetrics[a.id]?.quality ?? 0.5;
        final bq = lineMetrics[b.id]?.quality ?? 0.5;
        return aq.compareTo(bq);
      });
    case LineSortBy.playability:
      filtered.sort((a, b) {
        final ap = lineMetrics[a.id]?.playability ?? 0.5;
        final bp = lineMetrics[b.id]?.playability ?? 0.5;
        return bp.compareTo(ap);
      });
    case LineSortBy.traps:
      filtered.sort((a, b) {
        final at = lineMetrics[a.id]?.trapCount ?? 0;
        final bt = lineMetrics[b.id]?.trapCount ?? 0;
        return bt.compareTo(at);
      });
    case LineSortBy.coherence:
      filtered.sort((a, b) {
        final ac = lineMetrics[a.id]?.coherence ?? 0.5;
        final bc = lineMetrics[b.id]?.coherence ?? 0.5;
        return bc.compareTo(ac);
      });
    case LineSortBy.name:
      filtered.sort((a, b) => a.name.compareTo(b.name));
  }

  final grouped = <String, List<RepertoireLine>>{};
  for (final line in filtered) {
    final groupName = getLineGroupName(line);
    grouped.putIfAbsent(groupName, () => []).add(line);
  }

  final groupsToExpand = <String>{};
  if (currentMoves.isNotEmpty) {
    for (final entry in grouped.entries) {
      final hasExactMatch = entry.value.any((l) =>
          l.moves.length >= currentMoves.length &&
          pgn_utils.lineMatchesPosition(l, currentMoves));
      if (hasExactMatch) {
        groupsToExpand.add(entry.key);
      }
    }
  }

  return (
    filtered: filtered,
    grouped: grouped,
    groupsToExpand: groupsToExpand,
  );
}
