/// Per-game repertoire deviation: walk one game against the designated "my
/// repertoire" chapters and report where it last left book.
///
/// This is the per-game complement of the aggregate draft flow
/// (`RepertoireDiff` merges games into an `OpeningTree` and loses game
/// identity). Three rules, each learned from a real course export checked
/// against real games:
///
/// * **Choosing another opening is not a repertoire mistake.** Matching
///   must reach the first full opening pair in the book. Black playing c5 instead
///   of an e5 repertoire has not entered that repertoire merely by sharing
///   White's e4. A later transposition into it still establishes membership.
/// * **A book is a set of positions, not of move orders.** Every root-to-leaf
///   path of every chapter game — mainlines and variations alike — is played
///   out and each position it reaches is keyed by its FEN (counters dropped).
///   A game is in book at a ply when the position after that ply is one the
///   book reaches by *any* order, so `1.Nf3 c5 2.c4` is inside a book that
///   starts `1.c4 c5 2.Nf3`, and a game that leaves and transposes back is
///   reported at the fork it never came back from. Ten to forty percent of
///   Black games re-entered the book that way in the sample this was built
///   on; a move-prefix walk called every one of them "left book at move 1".
/// * **A bracket at our own move is commentary.** A course author writes
///   `3.Nc3 (3.e5 is the Advance, not covered)`: the bracket at the
///   opponent's move is a line the book answers, the bracket at ours is what
///   the author does *not* recommend. Following it made "3.e5" in book and
///   reported "book ends at move 4" for a third of one player's White games
///   instead of "you played 3.e5, the book plays 3.Nc3". Such moves are kept
///   as [DeviationReport.mentionedAlternative] so the verdict can say the
///   book knows the move without pretending it is the repertoire.
/// * **Someone else's game is not the book.** Model games and lines from a
///   custom start position are skipped (see `matchingBookLines`).
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../../services/storage/storage_factory.dart';
import 'book_move_keys.dart';
import 'my_repertoire_settings.dart';
import 'repertoire_book_tree.dart';

/// Where one game last left one book, and what the book wanted there.
class DeviationReport {
  const DeviationReport({
    required this.matchedPlies,
    required this.chapterPath,
    required this.chapterName,
    required this.pathSans,
    this.playedSan,
    this.byMe,
    this.expectedSans = const [],
    this.lineName,
    this.gamePathSans,
    this.mentionedAlternative = false,
    this.differentOpening = false,
  });

  /// Plies of the game that were in book before it diverged (== the 0-based
  /// ply index of the deviating move). With transpositions this counts up to
  /// the *last* departure: a game that left and came back is measured from
  /// the fork it never returned from.
  final int matchedPlies;

  /// The deepest-matching chapter file — the deep-link target.
  final String chapterPath;
  final String chapterName;

  /// The book's own move order to the deviation position (length
  /// [matchedPlies]) — what the builder navigates to and what the book lines
  /// are looked up by. The same position the game reached, though the game
  /// may have got there by another order: see [gamePathSans].
  final List<String> pathSans;

  /// The game's moves up to the deviation, only when they differ from
  /// [pathSans] — the game transposed into the book.
  final List<String>? gamePathSans;

  /// The first off-book move, or null when the whole game stayed in book.
  final String? playedSan;

  /// Whether *my* move left book (null when [inBook]).
  final bool? byMe;

  /// Repertoire moves that were available at the deviation point, spelled
  /// the way the book spells them.
  final List<String> expectedSans;

  /// A book line through the deviation position, by its variation title
  /// ("31) Caro-Kann 4...Bf5 › Main Line #3") — the name a reader of the
  /// course knows the position by. Null for a hand-built chapter whose lines
  /// carry no title.
  final String? lineName;

  /// True when [playedSan] is a move the book *mentions* for my side without
  /// recommending it — the author's "also possible" or "not covered". Still
  /// a deviation from the repertoire, but not an unknown move.
  final bool mentionedAlternative;

  /// The game never matched the first full opening pair of this book.
  /// Sharing the initial position or only White's first move is not
  /// evidence that the player intended to play this repertoire.
  final bool differentOpening;

  bool get inBook => !differentOpening && playedSan == null;

  /// True when the game ran past the *end* of the prepared line — the book
  /// has no moves at all at the deviation point — as opposed to diverging
  /// from moves it does have. "Who left book" is meaningless here; this is
  /// an invitation to extend the prep, not a deviation.
  bool get bookEnded =>
      !differentOpening && playedSan != null && expectedSans.isEmpty;

  /// True when the game reached the book by a move order the book does not
  /// spell out.
  bool get transposed => gamePathSans != null;

  /// Full-move number of the deviating move (for "left prep at move 9").
  int get moveNumber => matchedPlies ~/ 2 + 1;
}

class _CachedChapter {
  const _CachedChapter(this.mtimeMs, this.tree);

  final int mtimeMs;
  final BookTree tree;
}

/// How far one chapter followed a game, and the node it was at when the
/// game last stood in its book.
typedef _ChapterMatch = ({
  String chapter,
  BookNode node,
  int matchedPlies,
  int firstOutPly,
});

class GameDeviationService {
  GameDeviationService({MyRepertoireSettings? settings})
    : _settings = settings ?? MyRepertoireSettings.instance;

  static final GameDeviationService instance = GameDeviationService();

  final MyRepertoireSettings _settings;

  /// Keyed by chapter path and the side it is read for: the same file read
  /// as a White book and as a Black book has different alternatives.
  final Map<String, _CachedChapter> _chapterCache = {};

  /// Whether any repertoire is designated for the side [white].
  Future<bool> hasRepertoireFor({required bool white}) async {
    await _settings.ensureLoaded();
    return _settings.pathsFor(white: white).isNotEmpty;
  }

  /// Where the game at [gameSans] last left the designated book for the
  /// side I played ([meWhite]). Returns null when no repertoire is
  /// designated for that color, or the game has no moves.
  ///
  /// With several books for one colour the deepest match wins; at equal
  /// depth a book that still has a move here beats one that ran out, so a
  /// real deviation is never reported as "prep ended" because another book
  /// happened to stop at the same place.
  Future<DeviationReport?> analyzeGame({
    required List<String> gameSans,
    required bool meWhite,
  }) async {
    final all = await analyzeGameByRepertoire(
      gameSans: gameSans,
      meWhite: meWhite,
    );
    DeviationReport? best;
    for (final report in all.values) {
      if (best == null || _outranks(report, best)) best = report;
    }
    return best;
  }

  static bool _outranks(DeviationReport report, DeviationReport best) =>
      report.matchedPlies > best.matchedPlies ||
      (report.matchedPlies == best.matchedPlies &&
          best.bookEnded &&
          !report.bookEnded);

  /// The same walk, but reported **per designated repertoire folder** instead
  /// of collapsed to the single deepest match.
  ///
  /// Two books for one colour is a supported setup ("I have two White things
  /// loaded"), and for a manual check against a game the interesting answer is
  /// what *each* of them says: the deepest match alone silently hides that the
  /// other book covers the line too, or doesn't. Keyed by repertoire folder
  /// path; folders with no usable chapter are absent.
  Future<Map<String, DeviationReport>> analyzeGameByRepertoire({
    required List<String> gameSans,
    required bool meWhite,
    List<String>? folders,
  }) async {
    if (gameSans.isEmpty) return const {};
    await _settings.ensureLoaded();
    final targets = folders ?? _settings.pathsFor(white: meWhite);
    if (targets.isEmpty) return const {};
    // One replay of the game serves every folder and chapter.
    final gameKeys = moveKeysFromStart(gameSans);
    final gamePositions = positionKeysFromStart(gameSans);
    final out = <String, DeviationReport>{};
    for (final folder in targets) {
      final best = await _bestInFolder(
        folder,
        gameSans,
        gameKeys,
        gamePositions,
        meWhite,
      );
      if (best != null) out[folder] = best;
    }
    return out;
  }

  /// The deepest match within one repertoire folder.
  ///
  /// Chapters that reach the same depth are read together: the moves the book
  /// offers at that point are the union of what each of them offers, and the
  /// chapter named is one that still has a move there when any does. A folder
  /// whose "Sicilian" chapter stops at move 6 while its "Najdorf" chapter
  /// continues has *not* run out of prep at move 6.
  Future<DeviationReport?> _bestInFolder(
    String folder,
    List<String> gameSans,
    List<String> gameKeys,
    List<String> gamePositions,
    bool meWhite,
  ) async {
    final deepest = <_ChapterMatch>[];
    for (final chapter in await _chapterPathsIn(folder)) {
      final tree = await _treeFor(chapter, ourSideWhite: meWhite);
      if (tree == null || tree.isEmpty) continue;
      final match = _matchGame(chapter, tree, gamePositions);
      if (deepest.isNotEmpty &&
          match.matchedPlies > deepest.first.matchedPlies) {
        deepest.clear();
      }
      if (deepest.isEmpty || match.matchedPlies == deepest.first.matchedPlies) {
        deepest.add(match);
      }
    }
    if (deepest.isEmpty) return null;
    return _reportFor(deepest, gameSans, gameKeys, meWhite);
  }

  /// How far [tree] follows the game: in book at a ply when its position is
  /// one the book reaches. The match runs to the last such ply; a departure
  /// the game transposed back from is not the deviation.
  static _ChapterMatch _matchGame(
    String chapter,
    BookTree tree,
    List<String> gamePositions,
  ) {
    var node = tree.root;
    var matched = 0;
    var firstOut = -1;
    for (var i = 0; i < gamePositions.length; i++) {
      final hit = tree.nodeAt(gamePositions[i]);
      if (hit != null) {
        node = hit;
        matched = i + 1;
      } else if (firstOut < 0) {
        firstOut = i;
      }
    }
    return (
      chapter: chapter,
      node: node,
      matchedPlies: matched,
      firstOutPly: firstOut,
    );
  }

  /// The report for the chapters in [atBest], which all matched the game to
  /// the same depth.
  static DeviationReport _reportFor(
    List<_ChapterMatch> atBest,
    List<String> gameSans,
    List<String> gameKeys,
    bool meWhite,
  ) {
    final matched = atBest.first.matchedPlies;
    final diverged = matched < gameSans.length;
    final playedKey = diverged && matched < gameKeys.length
        ? gameKeys[matched]
        : null;
    final expected = <String, String>{};
    String? lineName;
    var mentioned = false;
    for (final match in atBest) {
      final node = match.node;
      for (final entry in node.display.entries) {
        expected.putIfAbsent(entry.key, () => entry.value);
      }
      // Several chapters tie here (every one of a course's files reaches
      // 1.e4): take the first name that is a real chapter's, not the
      // introduction's.
      final candidate = node.lineName;
      if (candidate != null &&
          (lineName == null ||
              (isNonRepertoireTitle(lineName) &&
                  !isNonRepertoireTitle(candidate)))) {
        lineName = candidate;
      }
      if (playedKey != null && node.alternatives.containsKey(playedKey)) {
        mentioned = true;
      }
    }
    final named = atBest.firstWhere(
      (m) => m.node.hasMoves,
      orElse: () => atBest.first,
    );
    // Measured on the chapter that set the depth, like the depth itself.
    final firstOut = atBest.first.firstOutPly;
    final transposed = firstOut >= 0 && firstOut < matched;
    return DeviationReport(
      matchedPlies: matched,
      chapterPath: named.chapter,
      chapterName: _chapterDisplayName(named.chapter),
      pathSans: named.node.path,
      gamePathSans: transposed ? gameSans.sublist(0, matched) : null,
      playedSan: diverged ? gameSans[matched] : null,
      byMe: diverged ? (matched.isEven == meWhite) : null,
      expectedSans: diverged ? expected.values.toList() : const [],
      lineName: lineName,
      mentionedAlternative: mentioned,
      differentOpening: diverged && matched < 2,
    );
  }

  /// Drop cached chapter tries (e.g. after the designations change).
  void invalidateCache() => _chapterCache.clear();

  /// The chapter files of [folder]; empty when it cannot be listed.
  Future<List<String>> _chapterPathsIn(String folder) async {
    try {
      final chapters = await StorageFactory.instance.listChapters(folder);
      return [for (final c in chapters) c.filePath];
    } catch (_) {
      // A designation that no longer points at a book (deleted, unreadable)
      // is not a reason to fail the check of every game.
      return const [];
    }
  }

  /// The cached tree for [chapterPath], rebuilt when the file changed. Null
  /// when the file is gone or unreadable, which also drops its cache entry.
  Future<BookTree?> _treeFor(
    String chapterPath, {
    required bool ourSideWhite,
  }) async {
    final cacheKey = '${ourSideWhite ? 'w' : 'b'}:$chapterPath';
    final file = File(chapterPath);
    final int mtimeMs;
    final String content;
    try {
      mtimeMs = (await file.lastModified()).millisecondsSinceEpoch;
      final cached = _chapterCache[cacheKey];
      if (cached != null && cached.mtimeMs == mtimeMs) return cached.tree;
      content = await file.readAsString();
    } catch (_) {
      // Gone, unreadable or undecodable: the chapter simply contributes no
      // book, and a stale tree must not stand in for it.
      _chapterCache.remove(cacheKey);
      return null;
    }
    // A course export is tens of megabytes once its variations are written
    // out as lines; parsing that on the UI isolate froze the app for seconds
    // on every start.
    final chapterName = _chapterDisplayName(chapterPath);
    BookTree build() => BookTree.fromChapter(
      content,
      ourSideWhite: ourSideWhite,
      chapterName: chapterName,
    );
    final tree = content.length > kOffThreadChapterBytes
        ? await Isolate.run(build)
        : build();
    _chapterCache[cacheKey] = _CachedChapter(mtimeMs, tree);
    return tree;
  }

  static String _chapterDisplayName(String path) =>
      p.basenameWithoutExtension(path);
}
