import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart' hide File;

import '../constants/chess_constants.dart';
import '../models/opening_tree.dart';
import '../models/position_analysis.dart';
import '../utils/atomic_file.dart';
import '../utils/fen_utils.dart';
import '../utils/file_text_reader.dart';
import 'pgn_parsing_service.dart';
import 'pgn_tree_core.dart';

/// Both colours' analysis + tree, built from one pass over a player's games.
typedef AnalysisBundle = ({
  PositionAnalysis whiteAnalysis,
  OpeningTree whiteTree,
  PositionAnalysis blackAnalysis,
  OpeningTree blackTree,
});

/// Builds [PositionAnalysis] and [OpeningTree] in a single pass over the
/// PGN list, eliminating the redundant parsing and mainline traversal from the
/// old two-pass analysis/tree pipeline.
///
/// Heavy entry points run in background isolates and hand their results back
/// with [Isolate.exit], which transfers the built objects without copying or
/// a JSON round-trip, so the UI thread never decodes analysis data:
///   • [buildBothInIsolate] – read + split + parse the PGN file and build both
///     colours at once (the file never touches the main thread), persisting
///     the per-colour disk cache as a side effect.
///   • [loadCachedBundle]   – fast path that restores both colours from that
///     cache, validated against the PGN file's (size, modified) stat.
///   • [buildInIsolate]     – single-colour build from an in-memory PGN list.
class UnifiedAnalysisBuilder {
  /// Bump when the cache layout changes; older files are ignored (and then
  /// overwritten by the next build). Version 1 was the never-read legacy
  /// format that stored only the top-50 positions.
  static const _cacheVersion = 2;

  // ── Synchronous builds ───────────────────────────────────────────────

  /// Parse PGNs once, walk each mainline once, and populate both the opening
  /// tree and the FEN-map analysis for a single colour.
  ///
  /// [onProgress] is called periodically with (gamesProcessed, totalGames).
  static (PositionAnalysis, OpeningTree) build({
    required List<String> pgnList,
    required String username,
    required bool isWhite,
    bool strictPlayerMatching = true,
    int maxDepth = 30,
    void Function(int current, int total)? onProgress,
  }) {
    final pgnGames = PgnGame.parseMultiGamePgn(pgnList.join('\n\n'));
    final usernameLower = username.toLowerCase();
    final total = pgnGames.length;
    final progressInterval = (total / 100).ceil().clamp(1, 100);
    final acc = _ColorAccumulator();

    onProgress?.call(0, total);

    for (var i = 0; i < pgnGames.length; i++) {
      final game = pgnGames[i];

      bool isUserWhiteInGame;
      if (!strictPlayerMatching) {
        isUserWhiteInGame = isWhite;
      } else {
        final detected = _detectUser(game, usernameLower);
        if (detected.white && !detected.black) {
          isUserWhiteInGame = true;
        } else if (detected.black && !detected.white) {
          isUserWhiteInGame = false;
        } else {
          isUserWhiteInGame = isWhite;
        }
      }

      if (isUserWhiteInGame == isWhite) {
        _walkMainline(
          game: game,
          gameIndex: i,
          acc: acc,
          isUserWhite: isUserWhiteInGame,
          userResult: _userResult(game, isUserWhiteInGame),
          maxDepth: maxDepth,
        );
      }

      if (onProgress != null &&
          ((i + 1) % progressInterval == 0 || i == total - 1)) {
        onProgress(i + 1, total);
      }
    }

    final games = pgnList.map(GameInfo.fromPgn).toList();
    return (acc.toAnalysis(games), acc.tree);
  }

  /// Build both colours from one parse + one mainline walk per game.
  ///
  /// Games where the user can't be identified (or appears on both sides)
  /// count for both colours, matching [build]'s fallback behaviour.
  static AnalysisBundle buildBoth({
    required List<String> pgnList,
    required String username,
    int maxDepth = 30,
    void Function(int current, int total)? onProgress,
  }) {
    final pgnGames = PgnGame.parseMultiGamePgn(pgnList.join('\n\n'));
    final usernameLower = username.toLowerCase();
    final total = pgnGames.length;
    final progressInterval = (total / 100).ceil().clamp(1, 100);

    final white = _ColorAccumulator();
    final black = _ColorAccumulator();

    onProgress?.call(0, total);

    for (var i = 0; i < pgnGames.length; i++) {
      final game = pgnGames[i];
      final detected = _detectUser(game, usernameLower);
      final colours = detected.white == detected.black
          ? const [true, false]
          : [detected.white];

      for (final asWhite in colours) {
        _walkMainline(
          game: game,
          gameIndex: i,
          acc: asWhite ? white : black,
          isUserWhite: asWhite,
          userResult: _userResult(game, asWhite),
          maxDepth: maxDepth,
        );
      }

      if (onProgress != null &&
          ((i + 1) % progressInterval == 0 || i == total - 1)) {
        onProgress(i + 1, total);
      }
    }

    // One shared GameInfo list: indices are positions in [pgnList], the same
    // for both colours.
    final games = pgnList.map(GameInfo.fromPgn).toList();
    return (
      whiteAnalysis: white.toAnalysis(games),
      whiteTree: white.tree,
      blackAnalysis: black.toAnalysis(games),
      blackTree: black.tree,
    );
  }

  // ── Isolate entry points ─────────────────────────────────────────────

  /// Run [build] inside a dedicated [Isolate] so the UI thread stays
  /// responsive. Progress updates stream back via [ReceivePort]; the final
  /// result transfers via [Isolate.exit] (no copy, no JSON).
  static Future<(PositionAnalysis, OpeningTree)> buildInIsolate({
    required List<String> pgnList,
    required String username,
    required bool isWhite,
    bool strictPlayerMatching = true,
    int maxDepth = 30,
    void Function(int current, int total)? onProgress,
  }) {
    return _runWithProgress<(PositionAnalysis, OpeningTree), _SingleColorArgs>(
      entryPoint: _singleColorEntry,
      makeArgs: (sendPort) => (
        sendPort: sendPort,
        pgnList: pgnList,
        username: username,
        isWhite: isWhite,
        strictPlayerMatching: strictPlayerMatching,
        maxDepth: maxDepth,
      ),
      onProgress: onProgress,
    );
  }

  /// Read, split, and parse the PGN file at [pgnFilePath] inside an isolate
  /// and build both colours in one pass. When [whiteCachePath] /
  /// [blackCachePath] are given, the per-colour disk cache is written there
  /// (also inside the isolate) so the next visit can use [loadCachedBundle].
  ///
  /// Throws if the file contains no games.
  static Future<AnalysisBundle> buildBothInIsolate({
    required String pgnFilePath,
    required String username,
    int maxDepth = 30,
    void Function(int current, int total)? onProgress,
    String? whiteCachePath,
    String? blackCachePath,
  }) {
    return _runWithProgress<AnalysisBundle, _BothColorsArgs>(
      entryPoint: _bothColorsEntry,
      makeArgs: (sendPort) => (
        sendPort: sendPort,
        pgnFilePath: pgnFilePath,
        username: username,
        maxDepth: maxDepth,
        whiteCachePath: whiteCachePath,
        blackCachePath: blackCachePath,
      ),
      onProgress: onProgress,
    );
  }

  /// Fast path: restore both colours from the cache files written by
  /// [buildBothInIsolate], entirely off the UI thread.
  ///
  /// Returns null when either colour's cache is missing, has an older format
  /// version, or is stale versus the PGN file's (size, modified) stat — the
  /// caller should fall back to [buildBothInIsolate].
  static Future<AnalysisBundle?> loadCachedBundle({
    required String pgnFilePath,
    required String whiteCachePath,
    required String blackCachePath,
  }) {
    return Isolate.run<AnalysisBundle?>(() {
      final pgnFile = File(pgnFilePath);
      if (!pgnFile.existsSync()) return null;
      final stat = pgnFile.statSync();

      final white = _decodeColorCacheFile(whiteCachePath, stat);
      if (white == null) return null;
      final black = _decodeColorCacheFile(blackCachePath, stat);
      if (black == null) return null;

      // The caches store only stats + tree; the shared games list is cheap
      // to rebuild from the PGN itself (headers only, no move replay).
      final pgnList = splitPgnIntoGames(stripBom(readTextFileSync(pgnFile)));
      final games = pgnList.map(GameInfo.fromPgn).toList();

      return (
        whiteAnalysis: white.toAnalysis(games),
        whiteTree: white.tree,
        blackAnalysis: black.toAnalysis(games),
        blackTree: black.tree,
      );
    });
  }

  // ── Isolate plumbing ─────────────────────────────────────────────────

  /// Spawn [entryPoint], forward `[current, total]` progress lists to
  /// [onProgress], and complete with the entry point's [Isolate.exit] value.
  static Future<R> _runWithProgress<R, A>({
    required void Function(A) entryPoint,
    required A Function(SendPort sendPort) makeArgs,
    void Function(int current, int total)? onProgress,
  }) async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();

    final isolate = await Isolate.spawn(
      entryPoint,
      makeArgs(receivePort.sendPort),
      onError: errorPort.sendPort,
    );

    final completer = Completer<R>();

    final errorSub = errorPort.listen((message) {
      if (!completer.isCompleted) {
        final desc = message is List ? message.first : message;
        completer.completeError(Exception('Isolate error: $desc'));
      }
    });

    final receiveSub = receivePort.listen((message) {
      if (message is List) {
        onProgress?.call(message[0] as int, message[1] as int);
      } else if (message is R && !completer.isCompleted) {
        completer.complete(message);
      }
    });

    try {
      return await completer.future.timeout(const Duration(minutes: 5));
    } finally {
      await errorSub.cancel();
      await receiveSub.cancel();
      receivePort.close();
      errorPort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  static void _singleColorEntry(_SingleColorArgs args) {
    final result = build(
      pgnList: args.pgnList,
      username: args.username,
      isWhite: args.isWhite,
      strictPlayerMatching: args.strictPlayerMatching,
      maxDepth: args.maxDepth,
      onProgress: (current, total) => args.sendPort.send([current, total]),
    );
    Isolate.exit(args.sendPort, result);
  }

  static Future<void> _bothColorsEntry(_BothColorsArgs args) async {
    final pgnFile = File(args.pgnFilePath);
    final pgnList = splitPgnIntoGames(stripBom(await readTextFile(pgnFile)));
    if (pgnList.isEmpty) {
      throw StateError('No games found in ${args.pgnFilePath}');
    }

    final bundle = buildBoth(
      pgnList: pgnList,
      username: args.username,
      maxDepth: args.maxDepth,
      onProgress: (current, total) => args.sendPort.send([current, total]),
    );

    // Persist the colour caches here, off the UI thread. Best effort: a
    // failed cache write must not fail the build.
    try {
      final stat = await pgnFile.stat();
      if (args.whiteCachePath != null) {
        await writeTextFileAtomically(
          File(args.whiteCachePath!),
          jsonEncode(
            _encodeColorCache(bundle.whiteAnalysis, bundle.whiteTree, stat),
          ),
        );
      }
      if (args.blackCachePath != null) {
        await writeTextFileAtomically(
          File(args.blackCachePath!),
          jsonEncode(
            _encodeColorCache(bundle.blackAnalysis, bundle.blackTree, stat),
          ),
        );
      }
    } catch (_) {
      // Ignore; the next visit simply rebuilds.
    }

    Isolate.exit(args.sendPort, bundle);
  }

  // ── Disk cache codec ─────────────────────────────────────────────────

  static Map<String, dynamic> _encodeColorCache(
    PositionAnalysis analysis,
    OpeningTree tree,
    FileStat pgnStat,
  ) {
    return {
      'version': _cacheVersion,
      'pgnSize': pgnStat.size,
      'pgnModifiedMs': pgnStat.modified.millisecondsSinceEpoch,
      'positionStats': analysis.positionStats.values
          .map((s) => s.toJson())
          .toList(),
      'fenToGameIndices': analysis.fenToGameIndices,
      'tree': tree.toTransferJson(),
    };
  }

  static _ColorAccumulator? _decodeColorCacheFile(
    String path,
    FileStat pgnStat,
  ) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map<String, dynamic>) return null;
      if (data['version'] != _cacheVersion) return null;
      if (data['pgnSize'] != pgnStat.size ||
          data['pgnModifiedMs'] != pgnStat.modified.millisecondsSinceEpoch) {
        return null;
      }

      final acc = _ColorAccumulator(
        tree: OpeningTree.fromTransferJson(
          Map<String, dynamic>.from(data['tree'] as Map),
        ),
      );
      for (final raw in data['positionStats'] as List<dynamic>) {
        final stats = PositionStats.fromJson(raw as Map<String, dynamic>);
        acc.stats[stats.fen] = stats;
      }
      (data['fenToGameIndices'] as Map<String, dynamic>).forEach((key, value) {
        acc.fenToGameIndices[key] = (value as List<dynamic>).cast<int>();
      });
      return acc;
    } catch (_) {
      return null;
    }
  }

  // ── Per-game processing ──────────────────────────────────────────────

  /// Which sides of this game the user was detected on (either may be false,
  /// or both true for e.g. repertoire self-play headers).
  static ({bool white, bool black}) _detectUser(
    PgnGame<PgnNodeData> game,
    String usernameLower,
  ) {
    final white = (game.headers['White'] ?? '').toLowerCase();
    final black = (game.headers['Black'] ?? '').toLowerCase();
    return (
      white:
          userNameMatchesHeader(white, usernameLower) ||
          isRepertoirePlayer(white),
      black:
          userNameMatchesHeader(black, usernameLower) ||
          isRepertoirePlayer(black),
    );
  }

  /// Game result from the user's perspective (1 win / 0.5 draw / 0 loss).
  static double _userResult(PgnGame<PgnNodeData> game, bool isUserWhite) =>
      resultForUser(game.headers['Result'] ?? '*', isUserWhite);

  /// Walk the game's mainline once, updating [acc]'s tree and FEN map.
  ///
  /// The walk itself is the shared [walkMainlineIntoTree]; this builder's
  /// additions are the FEN-map hooks and honouring a [FEN] start header.
  static void _walkMainline({
    required PgnGame<PgnNodeData> game,
    required int gameIndex,
    required _ColorAccumulator acc,
    required bool isUserWhite,
    required double userResult,
    required int maxDepth,
  }) {
    final startFen = game.headers['FEN'] ?? kStandardStartFen;

    walkMainlineIntoTree(
      tree: acc.tree,
      game: game,
      userResult: userResult,
      maxDepth: maxDepth,
      startPosition: Chess.fromSetup(Setup.parseFen(startFen)),
      onPositionBeforeMove: (position) {
        // FEN map: link game + record stats for positions before the move.
        _linkGameToFen(acc.fenToGameIndices, position.fen, gameIndex);

        final bool isUserTurn = (position.turn == Side.white) == isUserWhite;
        if (isUserTurn) {
          _updateStats(
            acc.stats,
            acc.fenToGameIndices,
            position.fen,
            userResult,
            gameIndex,
          );
        }
      },
      onWalkComplete: (finalPosition) {
        // Link final position to game index.
        _linkGameToFen(acc.fenToGameIndices, finalPosition.fen, gameIndex);
      },
    );
  }

  // ── FEN map helpers ──────────────────────────────────────────────────

  static void _updateStats(
    Map<String, PositionStats> stats,
    Map<String, List<int>> fenToGameIndices,
    String fen,
    double result,
    int gameIndex,
  ) {
    final key = normalizeFen(fen);
    final s = stats[key] ??= PositionStats(fen: key);
    s.games++;
    if (result == 1.0) {
      s.wins++;
    } else if (result == 0.0) {
      s.losses++;
    } else {
      s.draws++;
    }
    _linkGameToFen(fenToGameIndices, key, gameIndex);
  }

  /// Games arrive in ascending index order, so checking the last entry is
  /// enough to avoid duplicates — a `contains` scan here is quadratic on
  /// positions that occur in every game (e.g. the starting position).
  static void _linkGameToFen(
    Map<String, List<int>> fenToGameIndices,
    String fen,
    int gameIndex,
  ) {
    final key = normalizeFen(fen);
    final list = fenToGameIndices[key] ??= [];
    if (list.isEmpty || list.last != gameIndex) {
      list.add(gameIndex);
    }
  }
}

// ── Internal types ─────────────────────────────────────────────────────

typedef _SingleColorArgs = ({
  SendPort sendPort,
  List<String> pgnList,
  String username,
  bool isWhite,
  bool strictPlayerMatching,
  int maxDepth,
});

typedef _BothColorsArgs = ({
  SendPort sendPort,
  String pgnFilePath,
  String username,
  int maxDepth,
  String? whiteCachePath,
  String? blackCachePath,
});

/// One colour's accumulating build state (or decoded cache state).
class _ColorAccumulator {
  final OpeningTree tree;
  final Map<String, PositionStats> stats = {};
  final Map<String, List<int>> fenToGameIndices = {};

  _ColorAccumulator({OpeningTree? tree}) : tree = tree ?? OpeningTree();

  PositionAnalysis toAnalysis(List<GameInfo> games) => PositionAnalysis(
    positionStats: stats,
    games: games,
    fenToGameIndices: fenToGameIndices,
  );
}
