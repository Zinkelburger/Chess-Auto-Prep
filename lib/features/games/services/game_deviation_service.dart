/// Per-game repertoire deviation: walk one game's mainline against the
/// designated "my repertoire" chapters and report where it first left book.
///
/// This is the per-game complement of the aggregate draft flow
/// (`RepertoireDiff` merges games into an `OpeningTree` and loses game
/// identity). A book is every root-to-leaf path in its chapters — mainlines
/// and variations alike, since an imported study keeps most of its theory in
/// brackets — and moves are compared as moves, not as SAN spellings (see
/// `book_move_keys.dart`). General transposition tolerance is a deliberate
/// non-goal, to stay consistent with the draft/merge pipeline — with one
/// exception: a generated line that ends with `[%transposes …]` is grafted
/// onto the line it names, so a game that follows the cut move order keeps
/// matching past the merge point exactly as the book intends.
library;

import 'dart:io';

import 'package:dartchess/dartchess.dart'
    show Chess, PgnNode, PgnNodeData, Position;

import '../../../models/repertoire_line.dart';
import '../../../services/pgn_parsing_service.dart' as pgn;
import '../../../services/repertoire_service.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../utils/pgn_comment_utils.dart';
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
  });

  /// Plies matched from the start before the game diverged (== the 0-based
  /// ply index of the deviating move).
  final int matchedPlies;

  /// The deepest-matching chapter file — the deep-link target.
  final String chapterPath;
  final String chapterName;

  /// The matched SAN prefix (length [matchedPlies]) — what the builder
  /// navigates to when the report is opened.
  final List<String> pathSans;

  /// The first off-book move, or null when the whole game stayed in book.
  final String? playedSan;

  /// Whether *my* move left book (null when [inBook]).
  final bool? byMe;

  /// Repertoire moves that were available at the deviation point, spelled
  /// the way the book spells them.
  final List<String> expectedSans;

  bool get inBook => playedSan == null;

  /// True when the game ran past the *end* of the prepared line — the book
  /// has no moves at all at the deviation point — as opposed to diverging
  /// from moves it does have. "Who left book" is meaningless here; this is
  /// an invitation to extend the prep, not a deviation.
  bool get bookEnded => playedSan != null && expectedSans.isEmpty;

  /// Full-move number of the deviating move (for "left prep at move 9").
  int get moveNumber => matchedPlies ~/ 2 + 1;
}

/// One position of a chapter's move tree, keyed by move (see [moveKey]).
class _BookNode {
  final Map<String, _BookNode> children = {};

  /// Move key → the book's own SAN for it, for displaying expected moves.
  final Map<String, String> display = {};
}

class _CachedChapter {
  _CachedChapter(this.mtimeMs, this.root);

  final int mtimeMs;
  final _BookNode root;
}

class GameDeviationService {
  GameDeviationService({MyRepertoireSettings? settings})
    : _settings = settings ?? MyRepertoireSettings.instance;

  static final GameDeviationService instance = GameDeviationService();

  final MyRepertoireSettings _settings;
  final Map<String, _CachedChapter> _chapterCache = {};

  /// Whether any repertoire is designated for the side [white].
  Future<bool> hasRepertoireFor({required bool white}) async {
    await _settings.ensureLoaded();
    return _settings.pathsFor(white: white).isNotEmpty;
  }

  /// Where the game at [gameSans] first left the designated book for the
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
    final out = <String, DeviationReport>{};
    for (final folder in targets) {
      final best = await _bestInFolder(folder, gameSans, gameKeys, meWhite);
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
    bool meWhite,
  ) async {
    var bestDepth = -1;
    final atBest = <(String chapter, _BookNode node)>[];
    for (final chapter in await _chapterPathsIn(folder)) {
      final root = await _trieFor(chapter);
      if (root == null || root.children.isEmpty) continue;

      var node = root;
      var matched = 0;
      for (final key in gameKeys) {
        final child = node.children[key];
        if (child == null) break;
        node = child;
        matched++;
      }
      if (matched > bestDepth) {
        bestDepth = matched;
        atBest.clear();
      }
      if (matched == bestDepth) atBest.add((chapter, node));
    }
    if (atBest.isEmpty) return null;

    final matched = bestDepth;
    final diverged = matched < gameSans.length;
    final expected = <String, String>{};
    for (final (_, node) in atBest) {
      for (final entry in node.display.entries) {
        expected.putIfAbsent(entry.key, () => entry.value);
      }
    }
    final chapter = atBest
        .firstWhere((c) => c.$2.children.isNotEmpty, orElse: () => atBest.first)
        .$1;
    return DeviationReport(
      matchedPlies: matched,
      chapterPath: chapter,
      chapterName: _chapterDisplayName(chapter),
      pathSans: gameSans.sublist(0, matched),
      playedSan: diverged ? gameSans[matched] : null,
      byMe: diverged ? (matched.isEven == meWhite) : null,
      expectedSans: diverged ? expected.values.toList() : const [],
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

  Future<_BookNode?> _trieFor(String chapterPath) async {
    final file = File(chapterPath);
    final int mtimeMs;
    try {
      mtimeMs = (await file.lastModified()).millisecondsSinceEpoch;
    } catch (_) {
      _chapterCache.remove(chapterPath);
      return null;
    }
    final cached = _chapterCache[chapterPath];
    if (cached != null && cached.mtimeMs == mtimeMs) return cached.root;

    final String content;
    try {
      content = await file.readAsString();
    } catch (_) {
      _chapterCache.remove(chapterPath);
      return null;
    }
    final root = _buildBookTree(content);
    _chapterCache[chapterPath] = _CachedChapter(mtimeMs, root);
    return root;
  }

  /// The book one chapter file describes, as a move tree from the initial
  /// position.
  static _BookNode _buildBookTree(String chapterContent) {
    final service = RepertoireService();
    final text = pgn.stripBom(chapterContent);
    final parsed = service.parseGames(pgn.splitPgnIntoGames(text));
    // The same lines the trainer and the builder see, so the model-game and
    // custom-start rules are applied exactly once, in one place.
    final lines = service.linesFromParsedGames(
      parsed,
      declaredColor: pgn.extractRepertoireColor(text),
    );
    final treeByIndex = {for (final p in parsed) p.index: p.game.moves};
    return _buildTrie(lines, treeByIndex);
  }

  static _BookNode _buildTrie(
    List<RepertoireLine> lines,
    Map<int, PgnNode<PgnNodeData>> treeByIndex,
  ) {
    final root = _BookNode();
    final grafts = <(_BookNode end, List<String> owner)>[];
    for (final line in lines) {
      // Someone else's game illustrating the repertoire is not the
      // repertoire: its moves would extend the book far past where your own
      // preparation actually ends, and hide the deviation.
      if (line.isModelGame) continue;
      // Lines from a custom root can't be matched by a from-move-1 walk.
      if (line.startPosition.fen != Chess.initial.fen) continue;
      final tree = treeByIndex[line.gameIndex];
      if (tree != null) {
        _addTree(root, tree, Chess.initial, grafts);
      } else {
        _addMainline(root, line, grafts);
      }
    }
    // Graft after every line is in, so the owner's continuation is complete
    // whichever order the chapter lists them in.  The end node shares the
    // owner node's children rather than copying them: a later graft onto
    // the owner is then seen through this one too.
    for (final (end, owner) in grafts) {
      _BookNode? target = root;
      Position pos = Chess.initial;
      for (final san in owner) {
        final move = pos.parseSan(san);
        if (move == null) {
          target = null;
          break;
        }
        target = target!.children[moveKey(pos, san)];
        if (target == null) break;
        pos = pos.play(move);
      }
      if (target == null || identical(target, end)) continue;
      for (final entry in target.children.entries) {
        end.children.putIfAbsent(entry.key, () => entry.value);
        final shown = target.display[entry.key];
        if (shown != null) end.display.putIfAbsent(entry.key, () => shown);
      }
    }
    return root;
  }

  /// Every path of [pgnNode] — the mainline and each variation — into the
  /// trie under [node]. A move that is illegal where it stands ends its
  /// branch: nothing after it can be compared with a real game anyway.
  static void _addTree(
    _BookNode node,
    PgnNode<PgnNodeData> pgnNode,
    Position pos,
    List<(_BookNode, List<String>)> grafts,
  ) {
    for (final child in pgnNode.children) {
      final san = child.data.san;
      final move = pos.parseSan(san);
      if (move == null) continue;
      final key = moveKey(pos, san)!;
      node.display.putIfAbsent(key, () => san);
      final next = node.children.putIfAbsent(key, _BookNode.new);
      if (child.children.isEmpty) {
        final owner = parseTransposesToken(child.data.comments?.join(' '));
        if (owner != null) grafts.add((next, owner));
      }
      _addTree(next, child, pos.play(move), grafts);
    }
  }

  /// A line whose parse tree is not at hand (only its mainline is known).
  static void _addMainline(
    _BookNode root,
    RepertoireLine line,
    List<(_BookNode, List<String>)> grafts,
  ) {
    var node = root;
    Position pos = Chess.initial;
    for (final san in line.moves) {
      final move = pos.parseSan(san);
      if (move == null) return;
      final key = moveKey(pos, san)!;
      node.display.putIfAbsent(key, () => san);
      node = node.children.putIfAbsent(key, _BookNode.new);
      pos = pos.play(move);
    }
    if (line.moves.isEmpty) return;
    final owner = parseTransposesToken(
      line.comments['${line.moves.length - 1}'],
    );
    if (owner != null) grafts.add((node, owner));
  }

  static String _chapterDisplayName(String path) {
    final base = path.split(RegExp(r'[/\\]')).last;
    return base.toLowerCase().endsWith('.pgn')
        ? base.substring(0, base.length - 4)
        : base;
  }
}
