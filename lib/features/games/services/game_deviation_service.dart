/// Per-game repertoire deviation: walk one game against the designated "my
/// repertoire" chapters and report where it last left book.
///
/// This is the per-game complement of the aggregate draft flow
/// (`RepertoireDiff` merges games into an `OpeningTree` and loses game
/// identity). Three rules, each learned from a real course export checked
/// against real games:
///
/// * **Choosing another opening is not a repertoire mistake.** Matching
///   must reach at least our first move in the book. Black playing c5 instead
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

import 'package:dartchess/dartchess.dart'
    show Chess, PgnNode, PgnNodeData, Position, Side;

import '../../../models/repertoire_line.dart';
import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/repertoire_service.dart';
import '../../../services/storage/storage_factory.dart';
import 'book_move_keys.dart';
import 'my_repertoire_settings.dart';

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

  /// The game never entered this book through our first opening choice.
  /// Sharing the initial position (or White's move in a Black book) is not
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

/// One position of a book, keyed by move (see [moveKey]). Shared by every
/// path that reaches the position, whatever their move order.
class _BookNode {
  _BookNode(this.path);

  /// The first move order the book used to reach this position.
  final List<String> path;

  final Map<String, _BookNode> children = {};

  /// Move key → the book's own SAN for it, for displaying expected moves.
  final Map<String, String> display = {};

  /// Our-side moves the book mentions here without recommending them.
  final Map<String, String> alternatives = {};

  /// A line through this position, by title.
  String? lineName;
}

class _BookTree {
  _BookTree(this.root, this.byPosition);

  final _BookNode root;

  /// Position key (see [positionKey]) → node.
  final Map<String, _BookNode> byPosition;
}

class _CachedChapter {
  _CachedChapter(this.mtimeMs, this.tree);

  final int mtimeMs;
  final _BookTree tree;
}

/// Chapter titles that are not lines of the repertoire even though they hold
/// moves: a course's introduction, its quick-start digest, its model games.
/// Used only to prefer a better *name* for a position; their moves are read
/// like anyone else's, since they never say anything the chapters do not.
final RegExp _nonRepertoireTitle = RegExp(
  r'introduction|quick\s*start|model\s*game',
  caseSensitive: false,
);

/// Chapters larger than this are parsed on a worker isolate. Below it the
/// parse is a few milliseconds and the tests that drive it pump fake time,
/// under which an isolate's answer never arrives.
const int _offThreadBytes = 512 * 1024;

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
      if (best == null ||
          report.matchedPlies > best.matchedPlies ||
          (report.matchedPlies == best.matchedPlies &&
              best.bookEnded &&
              !report.bookEnded)) {
        best = report;
      }
    }
    return best;
  }

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
    var bestDepth = -1;
    var bestFirstOut = -1;
    final atBest = <(String chapter, _BookNode node)>[];
    for (final chapter in await _chapterPathsIn(folder)) {
      final tree = await _treeFor(chapter, ourSideWhite: meWhite);
      if (tree == null || tree.root.children.isEmpty) continue;

      // In book at a ply when its position is one the book reaches. The
      // match runs to the last such ply; a departure the game transposed
      // back from is not the deviation.
      var node = tree.root;
      var matched = 0;
      var firstOut = -1;
      for (var i = 0; i < gamePositions.length; i++) {
        final hit = tree.byPosition[gamePositions[i]];
        if (hit != null) {
          node = hit;
          matched = i + 1;
        } else if (firstOut < 0) {
          firstOut = i;
        }
      }
      if (matched > bestDepth) {
        bestDepth = matched;
        bestFirstOut = firstOut;
        atBest.clear();
      }
      if (matched == bestDepth) atBest.add((chapter, node));
    }
    if (atBest.isEmpty) return null;

    final matched = bestDepth;
    final diverged = matched < gameSans.length;
    final expected = <String, String>{};
    String? lineName;
    var mentioned = false;
    for (final (_, node) in atBest) {
      for (final entry in node.display.entries) {
        expected.putIfAbsent(entry.key, () => entry.value);
      }
      // Several chapters tie here (every one of a course's files reaches
      // 1.e4): take the first name that is a real chapter's, not the
      // introduction's.
      final candidate = node.lineName;
      if (candidate != null &&
          (lineName == null ||
              (_nonRepertoireTitle.hasMatch(lineName) &&
                  !_nonRepertoireTitle.hasMatch(candidate)))) {
        lineName = candidate;
      }
      if (diverged &&
          matched < gameKeys.length &&
          node.alternatives.containsKey(gameKeys[matched])) {
        mentioned = true;
      }
    }
    final (chapter, node) = atBest.firstWhere(
      (c) => c.$2.children.isNotEmpty,
      orElse: () => atBest.first,
    );
    final transposed = bestFirstOut >= 0 && bestFirstOut < matched;
    return DeviationReport(
      matchedPlies: matched,
      chapterPath: chapter,
      chapterName: _chapterDisplayName(chapter),
      pathSans: node.path,
      gamePathSans: transposed ? gameSans.sublist(0, matched) : null,
      playedSan: diverged ? gameSans[matched] : null,
      byMe: diverged ? (matched.isEven == meWhite) : null,
      expectedSans: diverged ? expected.values.toList() : const [],
      lineName: lineName,
      mentionedAlternative: mentioned,
      differentOpening: diverged && matched < (meWhite ? 1 : 2),
    );
  }

  /// Drop cached chapter tries (e.g. after the designations change).
  void invalidateCache() => _chapterCache.clear();

  Future<List<String>> _chapterPathsIn(String folder) async {
    try {
      final chapters = await StorageFactory.instance.listChapters(folder);
      return [for (final c in chapters) c.filePath];
    } catch (_) {
      return const [];
    }
  }

  Future<_BookTree?> _treeFor(
    String chapterPath, {
    required bool ourSideWhite,
  }) async {
    final cacheKey = '${ourSideWhite ? 'w' : 'b'}:$chapterPath';
    final file = File(chapterPath);
    final int mtimeMs;
    try {
      mtimeMs = (await file.lastModified()).millisecondsSinceEpoch;
    } catch (_) {
      _chapterCache.remove(cacheKey);
      return null;
    }
    final cached = _chapterCache[cacheKey];
    if (cached != null && cached.mtimeMs == mtimeMs) return cached.tree;

    final String content;
    try {
      content = await file.readAsString();
    } catch (_) {
      _chapterCache.remove(cacheKey);
      return null;
    }
    // A course export is tens of megabytes once its variations are written
    // out as lines; parsing that on the UI isolate froze the app for seconds
    // on every start.
    final chapterName = _chapterDisplayName(chapterPath);
    final tree = content.length > _offThreadBytes
        ? await Isolate.run(
            () => _buildBookTree(content, ourSideWhite, chapterName),
          )
        : _buildBookTree(content, ourSideWhite, chapterName);
    _chapterCache[cacheKey] = _CachedChapter(mtimeMs, tree);
    return tree;
  }

  /// The book one chapter file describes, as positions reached from the
  /// initial one, read for the side [ourSideWhite].
  static _BookTree _buildBookTree(
    String chapterContent,
    bool ourSideWhite,
    String chapterName,
  ) {
    final service = RepertoireService();
    final text = pgn.stripBom(chapterContent);
    final parsed = service.parseGames(pgn.splitPgnIntoGames(text));
    // The same lines the trainer and the builder see, so the model-game and
    // custom-start rules are applied exactly once, in one place.
    final lines = service.linesFromParsedGames(
      parsed,
      declaredColor: pgn.extractRepertoireColor(text),
      courseChapter: pgn.extractCourseChapter(text),
    );
    final treeByIndex = {for (final p in parsed) p.index: p.game.moves};
    return _buildTree(lines, treeByIndex, ourSideWhite, chapterName);
  }

  /// What to call a line: its course chapter and title when the file still
  /// groups by title, else the chapter *file* and the title — an imported
  /// course is split into one file per chapter, and "Main Line #3" on its
  /// own does not say which opening. A hand-built "Main" chapter adds
  /// nothing and is left off.
  static String _lineNameFor(RepertoireLine line, String chapterName) {
    if (line.chapter != null) return line.qualifiedName;
    if (chapterName == 'Main' ||
        line.name.toLowerCase().startsWith(chapterName.toLowerCase())) {
      return line.name;
    }
    return '$chapterName › ${line.name}';
  }

  static _BookTree _buildTree(
    List<RepertoireLine> lines,
    Map<int, PgnNode<PgnNodeData>> treeByIndex,
    bool ourSideWhite,
    String chapterName,
  ) {
    final root = _BookNode(const []);
    final tree = _BookTree(root, {positionKey(Chess.initial): root});
    for (final line in lines) {
      // Someone else's game illustrating the repertoire is not the
      // repertoire: its moves would extend the book far past where your own
      // preparation actually ends, and hide the deviation.
      if (line.isModelGame) continue;
      // Lines from a custom root can't be matched by a from-move-1 walk.
      if (line.startPosition.fen != Chess.initial.fen) continue;
      final pgnTree = treeByIndex[line.gameIndex];
      if (pgnTree == null) continue;
      _addTree(
        tree,
        root,
        pgnTree,
        Chess.initial,
        ply: 0,
        ourSideWhite: ourSideWhite,
        commentaryFrom: line.firstBranchOnSide(white: ourSideWhite),
        lineName: _lineNameFor(line, chapterName),
      );
    }
    return tree;
  }

  /// Every path of [pgnNode] into the book under [node]. A move that is
  /// illegal where it stands ends its branch: nothing after it can be
  /// compared with a real game anyway.
  ///
  /// Two things are read as commentary rather than book: at a position where
  /// it is our move, every child after the first (the author's alternatives
  /// in brackets), and — for a line already written out one path per game —
  /// the move at [commentaryFrom], the ply where its path took such a
  /// bracket. Both are recorded as the node's [_BookNode.alternatives] and
  /// not followed.
  static void _addTree(
    _BookTree tree,
    _BookNode node,
    PgnNode<PgnNodeData> pgnNode,
    Position pos, {
    required int ply,
    required bool ourSideWhite,
    required int? commentaryFrom,
    required String lineName,
  }) {
    _nameNode(node, lineName);
    final ourMove = (pos.turn == Side.white) == ourSideWhite;
    for (var i = 0; i < pgnNode.children.length; i++) {
      final child = pgnNode.children[i];
      final san = child.data.san;
      final move = pos.parseSan(san);
      if (move == null) continue;
      final key = moveKey(pos, san)!;
      if ((ourMove && i > 0) || ply == commentaryFrom) {
        node.alternatives.putIfAbsent(key, () => san);
        continue;
      }
      node.display.putIfAbsent(key, () => san);
      final nextPos = pos.play(move);
      final next = node.children.putIfAbsent(
        key,
        () => tree.byPosition.putIfAbsent(
          positionKey(nextPos),
          () => _BookNode([...node.path, san]),
        ),
      );
      _addTree(
        tree,
        next,
        child,
        nextPos,
        ply: ply + 1,
        ourSideWhite: ourSideWhite,
        commentaryFrom: commentaryFrom,
        lineName: lineName,
      );
    }
  }

  /// The first line through a position names it, unless that line is a
  /// course's introduction or digest and a real chapter comes along later.
  static void _nameNode(_BookNode node, String lineName) {
    final current = node.lineName;
    if (current == null) {
      node.lineName = lineName;
    } else if (_nonRepertoireTitle.hasMatch(current) &&
        !_nonRepertoireTitle.hasMatch(lineName)) {
      node.lineName = lineName;
    }
  }

  static String _chapterDisplayName(String path) =>
      p.basenameWithoutExtension(path);
}
