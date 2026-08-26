/// Turning planned chapter groups into the names a reader actually sees.
///
/// Follows the convention published courses use: the course is named for the
/// opening, and chapters are named for what distinguishes them *within* that
/// opening.  A Maroczy Bind course does not repeat "Sicilian Defense:
/// Accelerated Dragon" in all twelve chapter titles, so the segments every
/// chapter shares are stripped and only the distinguishing tail survives.
library;

import '../line_extractor.dart';
import 'chapter_planner.dart';
import 'opening_namer.dart';

/// Where the chapter sits in the exported file.
enum ChapterKind { lines, modelGames }

/// A named chapter, ready to be stamped into PGN headers.
class ChapterTitle {
  /// One-based position in the course.
  final int index;

  /// Display name including the index, e.g. `3. Maroczy Bind (6.Be3)`.
  final String name;

  /// ECO code of the chapter's defining position, when the book knows one.
  final String? eco;

  final ChapterKind kind;

  const ChapterTitle({
    required this.index,
    required this.name,
    this.eco,
    this.kind = ChapterKind.lines,
  });
}

/// Names a planned course: the course title, every chapter, and each line's
/// variation name inside its chapter.
class CourseNamer {
  CourseNamer({
    required this.namer,
    required this.rootWhiteToMove,
    required this.startMoveNumber,
    required this.repertoirePrefix,
    required this.playAsWhite,
  });

  final OpeningNamer namer;
  final bool rootWhiteToMove;
  final int startMoveNumber;

  /// Moves leading from the repertoire file's start position to the build
  /// root; chapter prefixes are relative to the build root, so the book
  /// lookup needs both halves.
  final List<String> repertoirePrefix;

  final bool playAsWhite;

  /// Course title, e.g. `Accelerated Dragon: Repertoire for Black`.
  ///
  /// Uses the opening of the position the repertoire starts from, which is
  /// the one thing every chapter has in common.
  String courseTitle({String? fallback}) {
    final opening = namer.label(repertoirePrefix)?.name;
    final subject = opening ?? fallback ?? 'Opening';
    return '$subject: Repertoire for ${playAsWhite ? 'White' : 'Black'}';
  }

  /// Name every chapter, resolving collisions and stripping the family name
  /// the whole course shares.
  List<ChapterTitle> nameChapters(List<ChapterGroup> groups) {
    if (groups.isEmpty) return const [];

    // A group cut by ECO code carries its own label: its lines may reach the
    // code by several move orders, so their common prefix names something
    // shallower than the chapter actually is. Sub-chapters of one code share
    // that label and are told apart by [_disambiguate]'s defining move.
    final labels = [
      for (final group in groups)
        group.ecoLabel ??
            namer.label([...repertoirePrefix, ...group.prefixSan]),
    ];
    final shared = _sharedLeadingSegments(labels);

    final bases = [
      for (var i = 0; i < groups.length; i++)
        _baseName(groups[i], labels[i], shared),
    ];
    final resolved = _disambiguate(groups, bases);

    return [
      for (var i = 0; i < groups.length; i++)
        ChapterTitle(
          index: i + 1,
          name: '${i + 1}. ${resolved[i]}',
          eco: labels[i]?.eco,
        ),
    ];
  }

  /// Variation names for every line in [group] — what appears in each line's
  /// `[Black]` header and becomes its title in the repertoire list.
  ///
  /// Named as a batch because the names must be distinct *within the chapter*:
  /// two lines sharing a title are indistinguishable in every list that shows
  /// them.  Preference order per line: a *more specific* opening name than the
  /// chapter's, then the shortest run of moves that tells it apart from its
  /// siblings, then a plain index.
  List<String> variationNames(
    ChapterGroup group, {
    required String chapterBaseName,
  }) {
    final names = List<String?>.filled(group.lines.length, null);
    final used = <String>{};

    // Pass 1: a book name more specific than the chapter's, but only when it
    // belongs to one line — a name two lines share identifies neither.
    final specific = [
      for (final line in group.lines) _specificName(line, chapterBaseName),
    ];
    final occurrences = <String, int>{};
    for (final name in specific) {
      if (name != null) occurrences[name] = (occurrences[name] ?? 0) + 1;
    }
    for (var i = 0; i < names.length; i++) {
      final name = specific[i];
      if (name != null && occurrences[name] == 1 && used.add(name)) {
        names[i] = name;
      }
    }

    // Pass 2: one shared move-run depth deep enough to separate everything
    // left.  Growing all of them together matters — showing "3.h3" beside
    // "3.h3 h6" reads as though the first line simply stops there.
    final remaining = [
      for (var i = 0; i < names.length; i++)
        if (names[i] == null) i,
    ];
    if (remaining.isNotEmpty) {
      _assignMoveRuns(group, remaining, names, used);
    }

    return [
      for (var i = 0; i < names.length; i++)
        names[i] ?? _uniqueName('Line ${i + 1}', used),
    ];
  }

  /// Moves shown when nothing shorter distinguishes the line.
  static const int _minVariationMoves = 3;

  String? _specificName(ExtractedLine line, String chapterBaseName) {
    final segments = namer.label([
      ...repertoirePrefix,
      ...line.movesSan,
    ])?.segments;
    if (segments == null || segments.isEmpty) return null;
    final specific = segments.last;
    if (specific.isEmpty || specific == chapterBaseName) return null;
    return specific;
  }

  void _assignMoveRuns(
    ChapterGroup group,
    List<int> indices,
    List<String?> names,
    Set<String> used,
  ) {
    final from = group.prefixSan.length;
    final longest = indices.fold<int>(
      0,
      (max, i) => group.lines[i].movesSan.length - from > max
          ? group.lines[i].movesSan.length - from
          : max,
    );

    String runFor(int index, int limit) => formatMoveRun(
      group.lines[index].movesSan,
      fromPly: from,
      rootWhiteToMove: rootWhiteToMove,
      startMoveNumber: startMoveNumber,
      limit: limit,
    );

    for (var limit = _minVariationMoves; limit <= longest; limit++) {
      final runs = [for (final i in indices) runFor(i, limit)];
      if (runs.any((r) => r.isEmpty)) continue;
      if (runs.toSet().length != runs.length) continue;
      if (runs.any(used.contains)) continue;

      for (var k = 0; k < indices.length; k++) {
        names[indices[k]] = runs[k];
        used.add(runs[k]);
      }
      return;
    }

    // Duplicate lines, or lines shorter than the minimum run: fall back to a
    // full-length run and let the index suffix separate whatever is left.
    for (final i in indices) {
      final run = runFor(i, longest < 1 ? 1 : longest);
      if (run.isEmpty) continue;
      names[i] = _uniqueName(run, used);
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────

  String _baseName(
    ChapterGroup group,
    OpeningLabel? label,
    int sharedSegments,
  ) {
    if (group.isMisc) {
      final move = _definingMove(group);
      return move == null ? 'Rare sidelines' : 'Rare sidelines after $move';
    }

    final segments = label?.segments ?? const <String>[];
    if (segments.isNotEmpty) {
      // Never strip everything: the last segment is the chapter's identity.
      final strip = sharedSegments < segments.length
          ? sharedSegments
          : segments.length - 1;
      final name = segments.skip(strip).join(', ');
      if (name.isNotEmpty) return name;
    }

    final move = _definingMove(group);
    return move == null ? 'Main line' : 'After $move';
  }

  String? _definingMove(ChapterGroup group) {
    final ply = group.definingPly;
    if (ply == null) return null;
    return formatMoveReference(
      group.prefixSan[ply],
      ply,
      rootWhiteToMove: rootWhiteToMove,
      startMoveNumber: startMoveNumber,
    );
  }

  /// Append the defining move to any name shared by two or more chapters.
  /// Two chapters of a Maroczy course can both be "Maroczy Bind"; `6.Be3` and
  /// `6.Be2` are what tell them apart.
  List<String> _disambiguate(List<ChapterGroup> groups, List<String> bases) {
    final counts = <String, int>{};
    for (final base in bases) {
      counts[base] = (counts[base] ?? 0) + 1;
    }

    final used = <String>{};
    return [
      for (var i = 0; i < groups.length; i++)
        _uniqueName(
          counts[bases[i]]! > 1
              ? _withMove(bases[i], _definingMove(groups[i]))
              : bases[i],
          used,
        ),
    ];
  }

  static String _withMove(String base, String? move) =>
      move == null ? base : '$base ($move)';

  /// Last-resort uniqueness so two chapters can never share a header value,
  /// which would silently merge them in any consumer that groups by name.
  static String _uniqueName(String candidate, Set<String> used) {
    if (used.add(candidate)) return candidate;
    for (var suffix = 2; ; suffix++) {
      final next = '$candidate #$suffix';
      if (used.add(next)) return next;
    }
  }

  /// How many leading name segments every chapter has in common — the course
  /// subject, which the title already states.
  static int _sharedLeadingSegments(List<OpeningLabel?> labels) {
    final named = [
      for (final label in labels)
        if (label != null) label.segments,
    ];
    if (named.length < 2) return 0;

    var shared = 0;
    final shortest = named.fold<int>(
      named.first.length,
      (min, s) => s.length < min ? s.length : min,
    );
    while (shared < shortest) {
      final segment = named.first[shared];
      if (named.any((s) => s[shared] != segment)) break;
      shared++;
    }
    return shared;
  }
}
