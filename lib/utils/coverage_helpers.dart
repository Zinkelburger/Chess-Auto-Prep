import '../features/coverage/services/coverage_service.dart';
import '../models/repertoire_line.dart';
import 'pgn_utils.dart' show commonPrefixLength, isMovesPrefix;

/// Pre-computed coverage info for a single repertoire line.
class LineCoverageInfo {
  final LeafNode? leaf;
  final List<UnaccountedMove> unaccountedMoves;
  final Map<String, List<UnaccountedMove>> groupedUnaccounted;

  const LineCoverageInfo({
    this.leaf,
    this.unaccountedMoves = const [],
    this.groupedUnaccounted = const {},
  });
}

/// Builds per-line coverage info keyed by line id.
Map<String, LineCoverageInfo> computeLineCoverageMap(
  List<RepertoireLine> lines,
  CoverageResult result,
) {
  final map = <String, LineCoverageInfo>{};
  for (final line in lines) {
    map[line.id] = matchLineToCoverage(line, result);
  }
  return map;
}

/// Match a repertoire line to coverage leaves and unaccounted moves.
LineCoverageInfo matchLineToCoverage(
  RepertoireLine line,
  CoverageResult result,
) {
  final lineMoves = line.moves;

  LeafNode? bestLeaf;
  int bestMatch = 0;

  for (final leaf in result.allLeaves) {
    final depth = commonPrefixLength(lineMoves, leaf.moves);
    if (depth > bestMatch) {
      bestMatch = depth;
      bestLeaf = leaf;
    }
  }

  final unaccounted = [
    for (final um in result.unaccountedMoves)
      if (isMovesPrefix(um.parentMoves, lineMoves)) um,
  ];

  final groupedUnaccounted = <String, List<UnaccountedMove>>{};
  for (final um in unaccounted) {
    final key = um.parentMoves.join(' ');
    groupedUnaccounted.putIfAbsent(key, () => []).add(um);
  }

  return LineCoverageInfo(
    leaf: bestLeaf,
    unaccountedMoves: unaccounted,
    groupedUnaccounted: groupedUnaccounted,
  );
}

int _countLines(
  Map<String, LineCoverageInfo> lineCoverage,
  bool Function(LineCoverageInfo info) test,
) => lineCoverage.values.where(test).length;

int countCoveredLines(Map<String, LineCoverageInfo> lineCoverage) =>
    _countLines(lineCoverage, (i) => i.leaf?.category == LeafCategory.covered);

int countShallowLines(Map<String, LineCoverageInfo> lineCoverage) =>
    _countLines(
      lineCoverage,
      (i) => i.leaf?.category == LeafCategory.tooShallow,
    );

int countDeepLines(Map<String, LineCoverageInfo> lineCoverage) =>
    _countLines(lineCoverage, (i) => i.leaf?.category == LeafCategory.tooDeep);

int countUnaccountedLines(Map<String, LineCoverageInfo> lineCoverage) =>
    _countLines(lineCoverage, (i) => i.unaccountedMoves.isNotEmpty);

int totalUnaccountedMoves(Map<String, LineCoverageInfo> lineCoverage) =>
    lineCoverage.values.fold(0, (sum, i) => sum + i.unaccountedMoves.length);

String formatCoveragePercent(double p) => '${(p * 100).toStringAsFixed(1)}%';
