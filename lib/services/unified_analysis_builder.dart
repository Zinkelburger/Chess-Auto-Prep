import 'dart:async';
import 'dart:isolate';

import 'package:dartchess_webok/dartchess_webok.dart';

import '../models/opening_tree.dart';
import '../models/position_analysis.dart';
import '../utils/fen_utils.dart';

/// Builds both [PositionAnalysis] and [OpeningTree] in a single pass over the
/// PGN list, eliminating the redundant parsing and mainline traversal that
/// occurred when [FenMapBuilder] and [OpeningTreeBuilder] ran independently.
///
/// Use [buildInIsolate] to run the work off the UI thread with per-game
/// progress reporting.
class UnifiedAnalysisBuilder {
  static const _repertoirePlayerPatterns = [
    'repertoire',
    'training',
    'me',
    'player',
    'study',
  ];

  /// Parse PGNs once, walk each mainline once, and populate both the opening
  /// tree and the FEN-map analysis.
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
    final fullPgnText = pgnList.join('\n\n');
    final pgnGames = PgnGame.parseMultiGamePgn(fullPgnText);
    final usernameLower = username.toLowerCase();
    final total = pgnGames.length;
    final progressInterval = (total / 100).ceil().clamp(1, 100);

    final tree = OpeningTree();
    final stats = <String, PositionStats>{};
    final fenToGameIndices = <String, List<int>>{};

    onProgress?.call(0, total);

    for (var i = 0; i < pgnGames.length; i++) {
      _processGame(
        game: pgnGames[i],
        gameIndex: i,
        tree: tree,
        stats: stats,
        fenToGameIndices: fenToGameIndices,
        usernameLower: usernameLower,
        userIsWhiteFilter: isWhite,
        maxDepth: maxDepth,
        strictPlayerMatching: strictPlayerMatching,
      );

      if (onProgress != null &&
          ((i + 1) % progressInterval == 0 || i == total - 1)) {
        onProgress(i + 1, total);
      }
    }

    final games = pgnList.map((p) => GameInfo.fromPgn(p)).toList();
    final analysis = PositionAnalysis(
      positionStats: stats,
      games: games,
      fenToGameIndices: fenToGameIndices,
    );

    return (analysis, tree);
  }

  /// Run [build] inside a dedicated [Isolate] so the UI thread stays
  /// responsive.  Progress updates stream back via [ReceivePort].
  ///
  /// [onProgress] is called on the main isolate with (current, total).
  static Future<(PositionAnalysis, OpeningTree)> buildInIsolate({
    required List<String> pgnList,
    required String username,
    required bool isWhite,
    bool strictPlayerMatching = true,
    int maxDepth = 30,
    void Function(int current, int total)? onProgress,
  }) async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();

    await Isolate.spawn(
      _isolateEntryPoint,
      (
        sendPort: receivePort.sendPort,
        pgnList: pgnList,
        username: username,
        isWhite: isWhite,
        strictPlayerMatching: strictPlayerMatching,
        maxDepth: maxDepth,
      ),
      onError: errorPort.sendPort,
    );

    final completer = Completer<(PositionAnalysis, OpeningTree)>();

    errorPort.listen((message) {
      if (!completer.isCompleted) {
        final desc = message is List ? message.first : message;
        completer.completeError(Exception('Isolate error: $desc'));
      }
      receivePort.close();
      errorPort.close();
    });

    receivePort.listen((message) {
      if (message is List) {
        onProgress?.call(message[0] as int, message[1] as int);
      } else if (message is Map) {
        if (!completer.isCompleted) {
          final analysis = PositionAnalysis.fromJson(
              Map<String, dynamic>.from(message['analysis'] as Map));
          final tree = OpeningTree.fromTransferJson(
              Map<String, dynamic>.from(message['tree'] as Map));
          completer.complete((analysis, tree));
        }
        receivePort.close();
        errorPort.close();
      }
    });

    return completer.future;
  }

  // ── Isolate entry point ──────────────────────────────────────────────

  static void _isolateEntryPoint(
    ({
      SendPort sendPort,
      List<String> pgnList,
      String username,
      bool isWhite,
      bool strictPlayerMatching,
      int maxDepth,
    }) params,
  ) {
    final (analysis, tree) = build(
      pgnList: params.pgnList,
      username: params.username,
      isWhite: params.isWhite,
      strictPlayerMatching: params.strictPlayerMatching,
      maxDepth: params.maxDepth,
      onProgress: (current, total) {
        params.sendPort.send([current, total]);
      },
    );

    params.sendPort.send({
      'analysis': analysis.toJson(fullExport: true),
      'tree': tree.toTransferJson(),
    });
  }

  // ── Per-game processing ──────────────────────────────────────────────

  static void _processGame({
    required PgnGame<PgnNodeData> game,
    required int gameIndex,
    required OpeningTree tree,
    required Map<String, PositionStats> stats,
    required Map<String, List<int>> fenToGameIndices,
    required String usernameLower,
    required bool userIsWhiteFilter,
    required int maxDepth,
    required bool strictPlayerMatching,
  }) {
    final white = (game.headers['White'] ?? '').toLowerCase();
    final black = (game.headers['Black'] ?? '').toLowerCase();
    final result = game.headers['Result'] ?? '*';

    // ── Determine user colour in this game ──

    bool isUserWhiteInGame;

    if (!strictPlayerMatching) {
      isUserWhiteInGame = userIsWhiteFilter;
    } else {
      final whiteIsUser =
          white.contains(usernameLower) || _isRepertoirePlayer(white);
      final blackIsUser =
          black.contains(usernameLower) || _isRepertoirePlayer(black);

      if (whiteIsUser && !blackIsUser) {
        isUserWhiteInGame = true;
      } else if (blackIsUser && !whiteIsUser) {
        isUserWhiteInGame = false;
      } else {
        isUserWhiteInGame = userIsWhiteFilter;
      }

      if (userIsWhiteFilter != isUserWhiteInGame) return;
    }

    final bool isUserWhite = isUserWhiteInGame;
    final bool isUserBlack = !isUserWhiteInGame;

    // ── User result from their perspective ──

    final double userResult;
    if (result.contains('1-0')) {
      userResult = isUserWhite ? 1.0 : 0.0;
    } else if (result.contains('0-1')) {
      userResult = isUserWhite ? 0.0 : 1.0;
    } else {
      userResult = 0.5;
    }

    // ── Walk mainline once, updating both tree and FEN map ──

    final startFen = game.headers['FEN'] ??
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    Position position = Chess.fromSetup(Setup.parseFen(startFen));
    var currentNode = tree.root;
    currentNode.updateStats(userResult);

    int depth = 0;
    for (final nodeData in game.moves.mainline()) {
      if (depth >= maxDepth) break;

      // -- FEN map: link game + record stats for positions before the move --
      _linkGameToFen(fenToGameIndices, position.fen, gameIndex);

      final bool isUserTurn =
          (position.turn == Side.white && isUserWhite) ||
          (position.turn == Side.black && isUserBlack);
      if (isUserTurn) {
        _updateStats(stats, fenToGameIndices, position.fen, userResult,
            gameIndex);
      }

      // -- Parse and apply move --
      final moveSan = nodeData.san;
      final move = position.parseSan(moveSan);
      if (move == null) break;

      try {
        position = position.play(move);
      } catch (_) {
        break;
      }

      // -- Tree: grow the tree with this move --
      final childNode = currentNode.getOrCreateChild(moveSan, position.fen);
      childNode.updateStats(userResult);
      tree.indexNode(childNode);
      currentNode = childNode;

      depth++;
    }

    // Link final position to game index.
    _linkGameToFen(fenToGameIndices, position.fen, gameIndex);
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

  static void _linkGameToFen(
    Map<String, List<int>> fenToGameIndices,
    String fen,
    int gameIndex,
  ) {
    final key = normalizeFen(fen);
    final list = fenToGameIndices[key] ??= [];
    if (!list.contains(gameIndex)) {
      list.add(gameIndex);
    }
  }

  static bool _isRepertoirePlayer(String playerName) {
    final lowerName = playerName.toLowerCase();
    return _repertoirePlayerPatterns
        .any((pattern) => lowerName.contains(pattern));
  }
}
