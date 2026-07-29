/// Per-game repertoire deviation: walk one game's mainline against the
/// designated "my repertoire" chapters and report where it first left book.
///
/// This is the per-game complement of the aggregate draft flow
/// (`RepertoireDiff` merges games into an `OpeningTree` and loses game
/// identity). Matching is SAN-prefix with check/mate-suffix tolerance, the
/// same definition of "in repertoire" the draft/merge pipeline uses;
/// transposition tolerance is a deliberate non-goal for now, to stay
/// consistent with it.
library;

import 'dart:io';

import 'package:dartchess/dartchess.dart' show Chess;

import '../../../models/repertoire_line.dart';
import '../../../services/repertoire_service.dart';
import '../../../services/storage/storage_factory.dart';
import 'game_moves.dart';
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

  /// Repertoire moves that were available at the deviation point.
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

class _SanTrieNode {
  final Map<String, _SanTrieNode> children = {};

  /// Normalized SAN → original SAN, for displaying expected moves.
  final Map<String, String> display = {};
}

class _CachedChapter {
  _CachedChapter(this.mtimeMs, this.root);

  final int mtimeMs;
  final _SanTrieNode root;
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
  Future<DeviationReport?> analyzeGame({
    required List<String> gameSans,
    required bool meWhite,
  }) async {
    if (gameSans.isEmpty) return null;
    await _settings.ensureLoaded();
    final folders = _settings.pathsFor(white: meWhite);
    if (folders.isEmpty) return null;

    DeviationReport? best;
    for (final folder in folders) {
      for (final chapter in await _chapterPathsIn(folder)) {
        final root = await _trieFor(chapter);
        if (root == null || root.children.isEmpty) continue;

        var node = root;
        var matched = 0;
        for (final san in gameSans) {
          final child = node.children[normalizeSan(san)];
          if (child == null) break;
          node = child;
          matched++;
        }

        if (best != null && matched <= best.matchedPlies) continue;
        final diverged = matched < gameSans.length;
        best = DeviationReport(
          matchedPlies: matched,
          chapterPath: chapter,
          chapterName: _chapterDisplayName(chapter),
          pathSans: gameSans.sublist(0, matched),
          playedSan: diverged ? gameSans[matched] : null,
          byMe: diverged ? (matched.isEven == meWhite) : null,
          expectedSans: diverged ? node.display.values.toList() : const [],
        );
      }
    }
    return best;
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

  Future<_SanTrieNode?> _trieFor(String chapterPath) async {
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
    final lines = RepertoireService().parseRepertoirePgn(content);
    final root = _buildTrie(lines);
    _chapterCache[chapterPath] = _CachedChapter(mtimeMs, root);
    return root;
  }

  static _SanTrieNode _buildTrie(List<RepertoireLine> lines) {
    final root = _SanTrieNode();
    for (final line in lines) {
      // Lines from a custom root can't be matched by a from-move-1 walk.
      if (line.startPosition.fen != Chess.initial.fen) continue;
      var node = root;
      for (final san in line.moves) {
        final key = normalizeSan(san);
        node.display.putIfAbsent(key, () => san);
        node = node.children.putIfAbsent(key, _SanTrieNode.new);
      }
    }
    return root;
  }

  static String _chapterDisplayName(String path) {
    final base = path.split(RegExp(r'[/\\]')).last;
    return base.toLowerCase().endsWith('.pgn')
        ? base.substring(0, base.length - 4)
        : base;
  }
}
