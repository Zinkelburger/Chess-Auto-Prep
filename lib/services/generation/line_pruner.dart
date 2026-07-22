/// Similarity pruning of extracted lines via greedy weighted set cover.
///
/// The unit of value is the our-move a line teaches
/// ([LineCoverageUnit], keyed by our-move projection prefix), so lines that
/// differ only in opponent moves share every unit: once one is selected the
/// other's marginal value is zero and it is dropped.  The survivors are the
/// lines that teach the most new, likely-to-occur, sharpest our-moves.
library;

import 'line_extractor.dart';

class LinePruner {
  LinePruner._();

  /// Reduce [lines] to at most [targetCount] lines maximizing covered
  /// our-move value.  Stops early once no remaining line adds an uncovered
  /// our-move, so the result can be shorter than [targetCount]; lines with
  /// zero novel value (pure duplicates by our-move projection) are always
  /// dropped.  Preserves the input's relative order.  Returns [lines]
  /// unchanged when [targetCount] <= 0.
  static List<ExtractedLine> prune(
    List<ExtractedLine> lines, {
    required int targetCount,
  }) {
    if (targetCount <= 0 || lines.length <= 1) return lines;

    // Intern unit keys to ints so the greedy loop hashes ints, not
    // move-sequence strings.
    final unitIdByKey = <String, int>{};
    final lineUnitIds = <List<int>>[];
    final lineUnitValues = <List<double>>[];
    for (final line in lines) {
      final ids = <int>[];
      final values = <double>[];
      for (final unit in line.coverageUnits) {
        ids.add(unitIdByKey.putIfAbsent(unit.key, () => unitIdByKey.length));
        values.add(unit.value);
      }
      lineUnitIds.add(ids);
      lineUnitValues.add(values);
    }

    final covered = List<bool>.filled(unitIdByKey.length, false);
    final chosen = List<bool>.filled(lines.length, false);
    // Marginal values only shrink as coverage grows, so a line whose cached
    // bound trails the current round's best can be skipped unrecomputed.
    final upperBound = List<double>.filled(lines.length, double.infinity);
    final selected = <int>[];

    while (selected.length < targetCount) {
      var bestIdx = -1;
      var bestValue = 0.0;
      for (int i = 0; i < lines.length; i++) {
        if (chosen[i] || upperBound[i] <= bestValue) continue;
        var marginal = 0.0;
        final ids = lineUnitIds[i];
        final values = lineUnitValues[i];
        for (int j = 0; j < ids.length; j++) {
          if (!covered[ids[j]]) marginal += values[j];
        }
        upperBound[i] = marginal;
        if (marginal > bestValue) {
          bestValue = marginal;
          bestIdx = i;
        }
      }
      if (bestIdx < 0) break;
      chosen[bestIdx] = true;
      selected.add(bestIdx);
      for (final id in lineUnitIds[bestIdx]) {
        covered[id] = true;
      }
    }

    selected.sort();
    return [for (final i in selected) lines[i]];
  }
}
