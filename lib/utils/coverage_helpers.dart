import '../models/repertoire_line.dart';
import '../services/coverage_service.dart';

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

  final unaccounted = <UnaccountedMove>[];
  for (final um in result.unaccountedMoves) {
    if (isMovesPrefix(um.parentMoves, lineMoves)) {
      unaccounted.add(um);
    }
  }

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

int commonPrefixLength(List<String> a, List<String> b) {
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  return i;
}

bool isMovesPrefix(List<String> prefix, List<String> list) {
  if (prefix.length > list.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (prefix[i] != list[i]) return false;
  }
  return true;
}

int countCoveredLines(Map<String, LineCoverageInfo> lineCoverage) =>
    lineCoverage.values
        .where((i) => i.leaf?.category == LeafCategory.covered)
        .length;

int countShallowLines(Map<String, LineCoverageInfo> lineCoverage) =>
    lineCoverage.values
        .where((i) => i.leaf?.category == LeafCategory.tooShallow)
        .length;

int countDeepLines(Map<String, LineCoverageInfo> lineCoverage) =>
    lineCoverage.values
        .where((i) => i.leaf?.category == LeafCategory.tooDeep)
        .length;

int countUnaccountedLines(Map<String, LineCoverageInfo> lineCoverage) =>
    lineCoverage.values.where((i) => i.unaccountedMoves.isNotEmpty).length;

int totalUnaccountedMoves(Map<String, LineCoverageInfo> lineCoverage) =>
    lineCoverage.values.fold(0, (sum, i) => sum + i.unaccountedMoves.length);

String formatCoveragePercent(double p) => '${(p * 100).toStringAsFixed(1)}%';
