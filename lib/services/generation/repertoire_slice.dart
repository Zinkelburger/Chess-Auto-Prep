/// Choosing how many of a finished build's lines the repertoire keeps.
///
/// A build exports every line that teaches something new *and* is different
/// enough from what is already in the book to deserve its own entry, ranked
/// by how much new ground each one breaks ([LinePruner.rank]). That is the
/// honest maximum, and it is still more than most people want to study: the
/// tail of the ranking is lines answering a rarer opponent try than one
/// already covered.
///
/// The size therefore belongs *after* the build, where the line count and
/// the coverage it buys can both be shown. Before the build it was a
/// percentage typed with no information, baked into the file.
///
/// Nothing here writes: it reports which lines a cut keeps and which it
/// drops, and the caller decides what to do about it.
library;

import '../../models/build_tree_node.dart';
import 'fen_map.dart';
import 'generation_config.dart';
import 'line_extractor.dart';
import 'line_pruner.dart';

/// What a cut at a given size keeps and drops.
class SlicePlan {
  const SlicePlan({
    required this.keep,
    required this.coverage,
    required this.keptKeys,
    required this.droppedKeys,
  });

  /// Lines the repertoire keeps. May exceed the requested count by a line or
  /// two when a kept transposition stub drags its owner back in.
  final int keep;

  /// Share (0..1) of the positions you are actually likely to reach that the
  /// kept lines answer as mainlines — what training will quiz.
  ///
  /// The sidelines folded into them answer more; the size control reads that
  /// off [RepertoireSlicer.answeredCoverageAt], which is an array lookup and
  /// so safe to call from `build` as this whole plan is not.
  final double coverage;

  /// Move-sequence keys of the kept lines, and of the dropped ones.
  /// A key is the line's SAN moves joined by spaces — the same identity the
  /// export already uses to avoid writing a line twice.
  final Set<String> keptKeys;
  final Set<String> droppedKeys;

  /// How many lines this cut would actually remove from a repertoire that
  /// currently holds [existingLineMoves].
  ///
  /// Only lines this cut drops *and* that are really in the file count. A
  /// line the user wrote by hand never matches a generated line's key, so it
  /// is neither counted nor removed — a button that offers to delete N lines
  /// must not be counting lines it will leave alone.
  int removalsFrom(Iterable<List<String>> existingLineMoves) {
    var count = 0;
    for (final moves in existingLineMoves) {
      if (droppedKeys.contains(RepertoireSlicer.lineKey(moves))) count++;
    }
    return count;
  }
}

/// Re-cuts a finished build's lines without rebuilding anything.
///
/// Extraction and ranking are pure functions of the saved tree, so re-cutting
/// costs one pass over lines already in memory — no engine, no network. That
/// is what makes a size *control* possible rather than a size *setting*.
class RepertoireSlicer {
  RepertoireSlicer._(this._slice);

  final LineSlice _slice;

  /// Rank the lines of an already-selected tree.
  ///
  /// The tree must carry its repertoire-move flags — a saved
  /// `<name>_tree.json` does, because selection runs before it is written.
  static RepertoireSlicer forTree(
    BuildTree tree, {
    required TreeBuildConfig config,
    FenMap? fenMap,
  }) {
    final map = fenMap ?? (FenMap()..populate(tree.root));
    final lines = LineExtractor(config: config, fenMap: map).extract(tree);
    return RepertoireSlicer._(
      LinePruner.rank(lines, diversity: LineDiversity.fromConfig(config)),
    );
  }

  /// Every line that teaches something new — the largest cut on offer.
  int get maxLines => _slice.length;

  /// Coverage a cut of [keep] lines reaches, counting mainlines only.
  double coverageAt(int keep) => _slice.coverageAt(keep);

  /// The same counting the sidelines those mainlines carry.
  double answeredCoverageAt(int keep) => _slice.answeredCoverageAt(keep);

  /// How many lines the export writes as a sideline rather than an entry.
  int get foldedCount => _slice.foldedCount;

  /// How many failed the diversity bar with no kept line to hang off, so
  /// they are not in the export at all.
  int get droppedCount => _slice.droppedCount;

  /// Fewest lines reaching [share] of what you will face. The starting
  /// position for the control, so it opens somewhere sensible.
  int countForCoverage(double share) => _slice.countForCoverage(share);

  /// Every extracted line's key, built once.
  ///
  /// [plan] used to walk [LineSlice.ranked] and re-join the SAN moves of every
  /// line on every call — a fresh list plus one `join` per line — although
  /// neither the ranking nor the keys depend on [keep].  On a 1500-line build
  /// that was 1500 string joins per call, and the size control calls this
  /// whenever the user asks for a different number.
  ///
  /// Every *extracted* line, not every ranked one: a line folded into
  /// another, or ranked out for teaching nothing, is still in a file an
  /// earlier build wrote, and the trim button has to be able to offer it.
  late final List<String> _allKeys = _slice.everyLineKey;

  int? _memoKeep;
  SlicePlan? _memoPlan;

  /// The kept and dropped move-sequence keys for a cut of [keep] lines.
  ///
  /// Memoised on [keep]: the size control asks for a count to display it and
  /// asks again for the same count to apply it, and the pin fixed point in
  /// [LineSlice.take] is not cheap enough to run twice for one answer.
  SlicePlan plan(int keep) {
    final memo = _memoPlan;
    if (memo != null && _memoKeep == keep) return memo;

    final kept = _slice.take(keep);
    final keptKeys = {for (final l in kept) lineKey(l.movesSan)};
    final droppedKeys = <String>{};
    for (final key in _allKeys) {
      if (!keptKeys.contains(key)) droppedKeys.add(key);
    }
    final plan = SlicePlan(
      keep: kept.length,
      coverage: _slice.coverageAt(keep),
      keptKeys: keptKeys,
      droppedKeys: droppedKeys,
    );
    _memoKeep = keep;
    _memoPlan = plan;
    return plan;
  }

  /// A line's identity: its SAN moves joined by spaces.
  ///
  /// Deliberately the same rule as `GenerationRequest.lineKey`, so a line
  /// this cut drops is matched against the repertoire by exactly the
  /// identity the export used when it wrote it.
  static String lineKey(List<String> moves) => LinePruner.lineKey(moves);
}
