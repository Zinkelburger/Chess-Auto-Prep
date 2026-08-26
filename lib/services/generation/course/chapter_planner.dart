/// Cutting a flat list of repertoire lines into chapters.
///
/// A generated repertoire is a tree flattened into root-to-leaf paths, which
/// is how a machine wants it and not at all how a person studies one.  This
/// re-imposes the structure the flattening destroyed: chapters are cut at the
/// branch points where the repertoire actually divides, so every chapter is
/// "what to do against one opponent system".
///
/// Pure: no engine, no I/O.  Where chapters follow ECO codes the book lookup
/// arrives as a callback ([ChapterPlanner.ecoOf]) rather than as a dependency,
/// so the cutting stays testable with a map.  Naming happens separately in
/// `chapter_titles.dart`.
library;

import '../line_extractor.dart';
import 'opening_namer.dart';

/// Lines that share an opening move prefix and will become one chapter.
class ChapterGroup {
  /// Moves every line in the group shares, relative to the build root.
  final List<String> prefixSan;

  final List<ExtractedLine> lines;

  /// True for the bucket that collects branches too small to be chapters of
  /// their own.  Such a group is a grab-bag, not a variation, and is named
  /// and ordered accordingly.
  final bool isMisc;

  /// The ECO opening this group belongs to, when chapters follow ECO codes.
  ///
  /// Set by the planner, not derived from [prefixSan]: lines reaching one ECO
  /// by different move orders share a shorter prefix than the code's own
  /// defining position, and naming the chapter from that prefix would lose
  /// the code the grouping was built on.
  final OpeningLabel? ecoLabel;

  /// Ply at which this group parted from its sibling chapters, or null for a
  /// group that was never split.
  ///
  /// This is what names a chapter — *not* the end of [prefixSan].  A group
  /// split at Black's first move but sharing four more moves with itself is
  /// "the 1...c5 chapter"; naming it after the last shared move would give
  /// every sibling the same title.
  final int? splitPly;

  const ChapterGroup({
    required this.prefixSan,
    required this.lines,
    this.isMisc = false,
    this.splitPly,
    this.ecoLabel,
  });

  /// This group with [ecoLabel] attached — the planner stamps a whole ECO
  /// bucket, including the sub-chapters an oversized one was cut into.
  ChapterGroup withEco(OpeningLabel? label) => ChapterGroup(
    prefixSan: prefixSan,
    lines: lines,
    isMisc: isMisc,
    splitPly: splitPly,
    ecoLabel: label,
  );

  /// Total reach probability of the group — how much of the opponent's play
  /// this chapter accounts for.  Chapter order follows it.
  double get weight => lines.fold(0.0, (sum, line) => sum + line.probability);

  /// Index into [prefixSan] of the move that identifies this chapter, or null
  /// when the group starts at the root.
  ///
  /// Falls back to the last shared move when the split ply is not inside the
  /// prefix, which happens for the misc bucket: its lines came from different
  /// branches, so they agree only up to their parent.
  int? get definingPly {
    if (prefixSan.isEmpty) return null;
    final ply = splitPly;
    if (ply != null && ply < prefixSan.length) return ply;
    return prefixSan.length - 1;
  }
}

/// Splits lines into chapters by descending to branch points until every
/// chapter is small enough to study.
class ChapterPlanner {
  const ChapterPlanner({
    required this.maxLines,
    required this.minLines,
    this.ecoOf,
  }) : assert(maxLines > 0, 'maxLines must be positive');

  /// The ECO opening a line belongs to, or null to cut at branch points
  /// instead.
  ///
  /// With it set, the top-level cut follows the classification rather than
  /// the tree's shape: every line whose deepest ECO hit is B90 is one
  /// chapter, however many move orders reach it.  That is what a reader
  /// looking for "the Najdorf chapter" expects, and it is the only cut that
  /// survives a book wide enough to span whole codes.  Branch-point cutting
  /// still runs *inside* each code, so a 300-line B90 is not one chapter.
  final OpeningLabel? Function(List<String> movesSan)? ecoOf;

  /// Split a group larger than this at its next branch point.
  final int maxLines;

  /// Branches smaller than this are not chapters; they are swept into the
  /// misc group so a two-line rarity does not get equal billing with the
  /// main system.
  final int minLines;

  List<ChapterGroup> plan(List<ExtractedLine> lines) {
    if (lines.isEmpty) return const [];
    final groups = ecoOf == null ? _split(lines, 0) : _planByEco(lines);

    // Most-played first, with the leftovers bucket always last: a course
    // opens with what you will actually face.
    groups.sort((a, b) {
      if (a.isMisc != b.isMisc) return a.isMisc ? 1 : -1;
      return b.weight.compareTo(a.weight);
    });
    return groups;
  }

  /// Bucket by ECO code first, then cut each bucket at its branch points.
  ///
  /// A code too small to be a chapter joins the misc bucket, exactly as a
  /// too-small branch does — a two-line ECO does not get equal billing with
  /// the main system just because the encyclopedia gave it a number.
  List<ChapterGroup> _planByEco(List<ExtractedLine> lines) {
    final resolve = ecoOf!;

    // Insertion order is the tree's own child order, which selection already
    // sorted by importance.
    final buckets = <String, List<ExtractedLine>>{};
    final labels = <String, OpeningLabel>{};
    final unclassified = <ExtractedLine>[];

    for (final line in lines) {
      final label = resolve(line.movesSan);
      if (label == null || label.eco.isEmpty) {
        unclassified.add(line);
        continue;
      }
      (buckets[label.eco] ??= []).add(line);
      labels.putIfAbsent(label.eco, () => label);
    }

    final chapters = <ChapterGroup>[];
    final leftovers = <ExtractedLine>[...unclassified];
    for (final entry in buckets.entries) {
      if (entry.value.length < minLines) {
        leftovers.addAll(entry.value);
        continue;
      }
      final label = labels[entry.key];
      for (final group in _split(entry.value, 0)) {
        chapters.add(group.withEco(label));
      }
    }

    // No code cleared the bar. Falling back to branch-point cutting beats
    // emitting one giant misc chapter that happens to be the whole book.
    if (chapters.isEmpty) return _split(lines, 0);

    if (leftovers.isNotEmpty) {
      chapters.add(_group(leftovers, isMisc: true));
    }
    return chapters;
  }

  List<ChapterGroup> _split(
    List<ExtractedLine> lines,
    int fromPly, {
    int? splitPly,
  }) {
    if (lines.length <= maxLines) return [_group(lines, splitPly: splitPly)];

    final ply = _firstDivergentPly(lines, fromPly);
    if (ply == null) return [_group(lines, splitPly: splitPly)];

    // Insertion order is the tree's own child order, which selection already
    // sorted by importance — preserving it keeps sibling chapters adjacent.
    final buckets = <String, List<ExtractedLine>>{};
    final leftovers = <ExtractedLine>[];
    for (final line in lines) {
      if (ply >= line.movesSan.length) {
        // The line ends at this branch point; it has no bucket to join.
        leftovers.add(line);
        continue;
      }
      (buckets[line.movesSan[ply]] ??= []).add(line);
    }

    final chapters = <ChapterGroup>[];
    for (final bucket in buckets.values) {
      if (bucket.length < minLines) {
        leftovers.addAll(bucket);
        continue;
      }
      chapters.addAll(_split(bucket, ply + 1, splitPly: ply));
    }

    // Nothing cleared the bar — splitting here would only produce scraps, so
    // keep the group whole and oversized rather than shattering it.
    if (chapters.isEmpty) return [_group(lines, splitPly: splitPly)];

    if (leftovers.isNotEmpty) {
      chapters.add(_group(leftovers, isMisc: true, splitPly: ply));
    }
    return chapters;
  }

  ChapterGroup _group(
    List<ExtractedLine> lines, {
    bool isMisc = false,
    int? splitPly,
  }) => ChapterGroup(
    prefixSan: _commonPrefix(lines),
    lines: lines,
    isMisc: isMisc,
    splitPly: splitPly,
  );

  /// First ply at or after [fromPly] where the lines stop agreeing — either
  /// because they play different moves or because one of them ends.
  /// Null when every line is identical from [fromPly] onward.
  static int? _firstDivergentPly(List<ExtractedLine> lines, int fromPly) {
    final shortest = lines.fold<int>(
      lines.first.movesSan.length,
      (min, line) => line.movesSan.length < min ? line.movesSan.length : min,
    );
    for (var ply = fromPly; ply < shortest; ply++) {
      final move = lines.first.movesSan[ply];
      for (final line in lines) {
        if (line.movesSan[ply] != move) return ply;
      }
    }
    // All lines agree as far as the shortest one runs; it diverges by ending.
    return lines.any((line) => line.movesSan.length != shortest)
        ? shortest
        : null;
  }

  static List<String> _commonPrefix(List<ExtractedLine> lines) {
    if (lines.isEmpty) return const [];
    var prefix = lines.first.movesSan;
    for (final line in lines.skip(1)) {
      final limit = prefix.length < line.movesSan.length
          ? prefix.length
          : line.movesSan.length;
      var shared = 0;
      while (shared < limit && prefix[shared] == line.movesSan[shared]) {
        shared++;
      }
      if (shared == 0) return const [];
      prefix = prefix.sublist(0, shared);
    }
    return List<String>.unmodifiable(prefix);
  }
}
