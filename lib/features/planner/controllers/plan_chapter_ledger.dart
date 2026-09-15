/// The chapters a planning walk opens and the build points it cuts in them.
///
/// A chapter is an opening *system*: the walk opens one whenever a branch
/// crosses into a differently named family (see [assign]), and every place
/// the walk stops becomes a build point in the chapter its path belongs to
/// (see [cut]). Chapters that never receive a build point are bookkeeping,
/// not chapters — [chapters] hides them and [finish] drops them.
library;

import '../../../services/generation/course/opening_namer.dart'
    show formatMoveReference;
import '../models/plan_models.dart';
import '../services/san_paths.dart';

/// What the ledger held at one moment, so an answer can be taken back.
class PlanChapterLedgerState {
  final List<PlanChapter> chapters;
  final Map<String, int> chapterOf;

  const PlanChapterLedgerState({
    required this.chapters,
    required this.chapterOf,
  });
}

class PlanChapterLedger {
  PlanChapterLedger({required this.nameFor, required this.chapterMass});

  /// The book's name for the position after a path, if any.
  final Future<String?> Function(List<String> path) nameFor;

  /// An opponent reply becomes its own chapter only when the branch carries
  /// at least this share of the games from the walk's root (and changes
  /// family). Our own choices split by family alone.
  final double chapterMass;

  final List<PlanChapter> _chapters = [];

  /// Which chapter each walked path belongs to (index into [_chapters]),
  /// keyed by [sanPathKey].
  final Map<String, int> _chapterOf = {};

  /// Chapters that have something to build.
  List<PlanChapter> get chapters =>
      List.unmodifiable(_chapters.where((c) => c.points.isNotEmpty));

  void clear() {
    _chapters.clear();
    _chapterOf.clear();
  }

  PlanChapterLedgerState snapshot() => PlanChapterLedgerState(
    chapters: [for (final c in _chapters) c.copy()],
    chapterOf: Map.of(_chapterOf),
  );

  void restore(PlanChapterLedgerState state) {
    _chapters
      ..clear()
      ..addAll([for (final c in state.chapters) c.copy()]);
    _chapterOf
      ..clear()
      ..addAll(state.chapterOf);
  }

  /// The opening family of a book name: the part before its first ':'
  /// ("Queen's Gambit Declined: 3.Nc3" → "Queen's Gambit Declined").
  static String familyOf(String? bookName) {
    if (bookName == null || bookName.isEmpty) return 'Repertoire';
    final colon = bookName.indexOf(':');
    return (colon > 0 ? bookName.substring(0, colon) : bookName).trim();
  }

  /// The chapter [path] belongs to, opening a root chapter on first use.
  Future<PlanChapter> chapterFor(List<String> path) async {
    final key = sanPathKey(path);
    final index = _chapterOf[key];
    if (index != null) return _chapters[index];
    // Only a walk's root gets here without an assignment.
    final family = familyOf(await nameFor(path));
    return _open(family, path);
  }

  /// Decide whether [child] starts a new chapter or stays in its parent's.
  ///
  /// New chapter when the book names a *different family* below the child
  /// and — for an opponent's reply — the branch carries [chapterMass] of the
  /// games from the root ([reach]). Our own choices (…e6 vs …c6) split by
  /// family alone: the user chose both systems.
  Future<void> assign(
    List<String> child, {
    required List<String> parent,
    required bool ourChoice,
    required double reach,
  }) async {
    final parentChapter = await chapterFor(parent);
    final family = familyOf(await nameFor(child));
    final differs = family != parentChapter.family;
    final heavy = ourChoice || reach >= chapterMass;
    if (differs && heavy) {
      _open(family, child);
    } else {
      _chapterOf[sanPathKey(child)] = _chapters.indexOf(parentChapter);
    }
  }

  /// The walk stops at [path]: record a build point in its chapter.
  Future<void> cut(
    List<String> path, {
    List<String> excludeReplies = const [],
    required String reason,
  }) async {
    final chapter = await chapterFor(path);
    chapter.points.add(
      PlanBuildPoint(
        moves: List.of(path),
        excludeReplies: excludeReplies,
        reason: reason,
      ),
    );
  }

  /// Names two chapters of one family apart and drops the chapters that
  /// have nothing to build; what remains is the plan.
  List<PlanChapter> finish() {
    _disambiguateNames();
    _chapters.removeWhere((c) => c.points.isEmpty);
    return List.of(_chapters);
  }

  PlanChapter _open(String family, List<String> path) {
    final chapter = PlanChapter(
      name: family,
      family: family,
      moves: List.of(path),
    );
    _chapters.add(chapter);
    _chapterOf[sanPathKey(path)] = _chapters.length - 1;
    return chapter;
  }

  /// Two chapters of the same name (rare: two of our systems inside one
  /// family) get the move that tells them apart appended.
  void _disambiguateNames() {
    final byName = <String, List<PlanChapter>>{};
    for (final c in _chapters) {
      byName.putIfAbsent(c.name, () => []).add(c);
    }
    for (final group in byName.values) {
      if (group.length < 2) continue;
      final shared = _commonPrefixLength(group.map((c) => c.moves));
      for (final c in group) {
        if (c.moves.length <= shared) continue;
        final ref = formatMoveReference(
          c.moves[shared],
          shared,
          rootWhiteToMove: true,
        );
        if (!c.name.contains(ref)) c.name = '${c.name} · $ref';
      }
    }
  }

  static int _commonPrefixLength(Iterable<List<String>> paths) {
    var prefix = List.of(paths.first);
    for (final path in paths.skip(1)) {
      var n = 0;
      while (n < prefix.length && n < path.length && prefix[n] == path[n]) {
        n++;
      }
      prefix = prefix.sublist(0, n);
    }
    return prefix.length;
  }
}
