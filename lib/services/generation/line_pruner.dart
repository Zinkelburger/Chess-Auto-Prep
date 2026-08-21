/// Similarity pruning of extracted lines via greedy weighted set cover.
///
/// The unit of value is the decision a line teaches ([LineCoverageUnit],
/// keyed by the position faced plus the move we play in it), so two lines
/// share a unit whenever they put the user in front of the same choice —
/// whether they differ only in the opponent's moves or transpose into one
/// another by a different move order. Once one is selected the other's
/// marginal value is zero and it is dropped. The survivors are the lines
/// that teach the most new, likely-to-occur, sharpest decisions.
///
/// How many survive is driven by coverage rather than by a raw line count:
/// the greedy runs to exhaustion, and the caller asks for the share of
/// reachable value it wants. A line budget stays available as a hard cap for
/// callers that need one, but it is no longer the thing you tune — "cover 92%
/// of what I will actually face" transfers between repertoires in a way that
/// "give me 100 lines" does not.
library;

import 'line_extractor.dart';

class LinePruner {
  LinePruner._();

  /// Reduce [lines] to the survivors of a greedy weighted set cover over the
  /// decisions they teach.
  ///
  /// [coverageTarget] is the share (0..1) of total reachable value to cover;
  /// the result is the shortest prefix of the greedy order that reaches it.
  /// 1.0 keeps every line that teaches anything new.
  ///
  /// [targetCount] is a hard cap on the number of lines, applied on top of
  /// [coverageTarget]; 0 means no cap. Note the change from earlier
  /// behaviour: 0 used to mean "skip pruning entirely", which handed callers
  /// back every exact training duplicate (748 of 1533 on a real Benko tree).
  /// Pruning now always runs — it only ever drops a line whose every decision
  /// is already taught by a line that was kept, so there is nothing to lose
  /// by it and no reason to offer switching it off.
  ///
  /// Lines with no decisions to teach are always dropped. Preserves the
  /// input's relative order.
  static List<ExtractedLine> prune(
    List<ExtractedLine> lines, {
    int targetCount = 0,
    double coverageTarget = 1.0,
  }) {
    if (lines.length <= 1) return lines;

    // Intern unit keys to ints so the greedy loop hashes ints, not
    // position-and-move strings.
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

    // Lines that teach nothing are never picked and never count towards
    // coverage; a line is "covered" once every decision in it is taught by
    // something already kept.
    final uncoveredLeft = [for (final ids in lineUnitIds) ids.toSet().length];
    final linesByUnit = List.generate(unitIdByKey.length, (_) => <int>[]);
    for (var i = 0; i < lineUnitIds.length; i++) {
      for (final id in lineUnitIds[i].toSet()) {
        linesByUnit[id].add(i);
      }
    }
    var totalMass = 0.0;
    for (var i = 0; i < lines.length; i++) {
      if (uncoveredLeft[i] > 0) totalMass += lines[i].probability;
    }

    // Run the greedy to exhaustion, recording after each pick how much reach
    // mass is *fully* covered by the picks so far.
    //
    // Coverage is deliberately measured in reach mass rather than in the
    // unit values that order the greedy. The values are dominated by the
    // handful of near-certain decisions at the top of the tree, so 92% of
    // value arrives after ~60 lines while 92% of the positions you actually
    // reach needs ~300. The second number is the one that answers "how much
    // of what I will face does this book cover", which is the question the
    // setting claims to answer.
    final picks = <int>[];
    final coveredMassAfter = <double>[];
    var coveredMass = 0.0;
    while (true) {
      var bestIdx = -1;
      var bestValue = 0.0;
      for (var i = 0; i < lines.length; i++) {
        if (chosen[i] || upperBound[i] <= bestValue) continue;
        var marginal = 0.0;
        final ids = lineUnitIds[i];
        final values = lineUnitValues[i];
        for (var j = 0; j < ids.length; j++) {
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
      picks.add(bestIdx);
      for (final id in lineUnitIds[bestIdx].toSet()) {
        if (covered[id]) continue;
        covered[id] = true;
        for (final line in linesByUnit[id]) {
          if (--uncoveredLeft[line] == 0) {
            coveredMass += lines[line].probability;
          }
        }
      }
      coveredMassAfter.add(coveredMass);
    }
    if (picks.isEmpty) return const [];

    final cap = targetCount > 0 && targetCount < picks.length
        ? targetCount
        : picks.length;
    final want = coverageTarget.clamp(0.0, 1.0) * totalMass;

    var take = 0;
    while (take < cap && coveredMassAfter[take] < want) {
      take++;
    }
    // The loop stops *at* the first pick that reaches the target, so take
    // that one too. This also makes a target of zero return one line rather
    // than none: a set with something to teach never comes back empty.
    if (take < cap) take++;

    final keep = List<bool>.filled(lines.length, false);
    for (final i in picks.take(take)) {
      keep[i] = true;
    }
    _pinTranspositionOwners(lines, picks, keep);

    return [
      for (var i = 0; i < lines.length; i++)
        if (keep[i]) lines[i],
    ];
  }

  /// Pull back any line whose continuation a *kept* transposition stub points
  /// at.
  ///
  /// A stub ends with "Transposes to 1. d4 ..." and deliberately does not
  /// repeat the continuation — the owning move order carries it. The greedy
  /// scores the two independently, so with `coverageTarget < 1.0` the prefix
  /// can keep the stub and drop the owner. That leaves the book naming a move
  /// order it does not contain, and the shared continuation taught nowhere at
  /// all.
  ///
  /// Pinning can push the result past [prune]'s `targetCount` cap. That is
  /// the intended trade: an owner teaches strictly more than the stub that
  /// references it, so honouring the cap by leaving a dangling reference
  /// would be the worse book.
  ///
  /// Iterates to a fixed point — a pinned owner may itself be a stub for a
  /// further transposition. Each pass can only set flags, never clear them,
  /// so the loop terminates in at most [lines] rounds.
  static void _pinTranspositionOwners(
    List<ExtractedLine> lines,
    List<int> picks,
    List<bool> keep,
  ) {
    var changed = true;
    while (changed) {
      changed = false;
      for (var i = 0; i < lines.length; i++) {
        if (!keep[i]) continue;
        final target = lines[i].transposesInto;
        if (target == null) continue;
        if (_isCarriedBy(lines, keep, target, exclude: i)) continue;
        final owner = _ownerIndexFor(lines, picks, target, exclude: i);
        // No owner anywhere in the input: the note is dangling on arrival and
        // there is nothing here to pin. `stripDanglingTranspositions` drops
        // the claim rather than letting the export make it.
        if (owner == null) continue;
        keep[owner] = true;
        changed = true;
      }
    }
  }

  /// Whether some kept line other than [exclude] plays [target]'s move order.
  static bool _isCarriedBy(
    List<ExtractedLine> lines,
    List<bool> keep,
    List<String> target, {
    required int exclude,
  }) {
    for (var i = 0; i < lines.length; i++) {
      if (i == exclude || !keep[i]) continue;
      if (_startsWith(lines[i].movesSan, target)) return true;
    }
    return false;
  }

  /// The best line playing [target]'s move order: greedy order first, so the
  /// owner pulled back in is the one that teaches the most.
  static int? _ownerIndexFor(
    List<ExtractedLine> lines,
    List<int> picks,
    List<String> target, {
    required int exclude,
  }) {
    for (final i in picks) {
      if (i == exclude) continue;
      if (_startsWith(lines[i].movesSan, target)) return i;
    }
    // A line that teaches nothing new never enters the greedy, but it can
    // still be the only carrier of a move order.
    for (var i = 0; i < lines.length; i++) {
      if (i == exclude) continue;
      if (_startsWith(lines[i].movesSan, target)) return i;
    }
    return null;
  }

  static bool _startsWith(List<String> moves, List<String> prefix) {
    if (prefix.length > moves.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (moves[i] != prefix[i]) return false;
    }
    return true;
  }
}
