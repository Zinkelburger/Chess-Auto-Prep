import 'dart:async';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';
import '../models/opening_tree.dart';
import 'package:chess_auto_prep/utils/log.dart';

class OpeningTreeBuilder {
  /// Common player name patterns used in repertoire files
  static const _repertoirePlayerPatterns = [
    'repertoire',
    'training',
    'me',
    'player',
    'study',
  ];

  static Future<OpeningTree> buildTree({
    required List<String> pgnList,
    required String username,
    required bool? userIsWhite,
    int maxDepth = 30,
    bool strictPlayerMatching = true,
    void Function(int processed, int total)? onProgress,
  }) async {
    final transferJson = onProgress == null
        ? await Isolate.run(() {
            return _buildTreeSync(
              pgnList: pgnList,
              username: username,
              userIsWhite: userIsWhite,
              maxDepth: maxDepth,
              strictPlayerMatching: strictPlayerMatching,
            );
          })
        : await _buildTreeWithProgress(
            pgnList: pgnList,
            username: username,
            userIsWhite: userIsWhite,
            maxDepth: maxDepth,
            strictPlayerMatching: strictPlayerMatching,
            onProgress: onProgress,
          );
    return OpeningTree.fromTransferJson(transferJson);
  }

  static Future<Map<String, dynamic>> _buildTreeWithProgress({
    required List<String> pgnList,
    required String username,
    required bool? userIsWhite,
    required int maxDepth,
    required bool strictPlayerMatching,
    required void Function(int processed, int total) onProgress,
  }) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, dynamic>>(
      _buildTreeSyncIsolateEntry,
      {
        'sendPort': receivePort.sendPort,
        'pgnList': pgnList,
        'username': username,
        'userIsWhite': userIsWhite,
        'maxDepth': maxDepth,
        'strictPlayerMatching': strictPlayerMatching,
      },
    );

    final completer = Completer<Map<String, dynamic>>();
    late final StreamSubscription<dynamic> sub;
    sub = receivePort.listen((dynamic message) {
      if (message is! Map) return;
      final type = message['type'];
      if (type == 'progress') {
        final processed = message['processed'] as int? ?? 0;
        final total = message['total'] as int? ?? 0;
        onProgress(processed, total);
      } else if (type == 'result') {
        final payload = message['payload'];
        if (!completer.isCompleted && payload is Map) {
          completer.complete(Map<String, dynamic>.from(payload));
        }
      } else if (type == 'error') {
        if (!completer.isCompleted) {
          completer
              .completeError(Exception(message['error'] ?? 'Unknown error'));
        }
      }
    });

    try {
      return await completer.future.timeout(const Duration(minutes: 5));
    } finally {
      await sub.cancel();
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  static void _buildTreeSyncIsolateEntry(Map<String, dynamic> args) {
    final sendPort = args['sendPort'] as SendPort;
    try {
      final result = _buildTreeSync(
        pgnList: (args['pgnList'] as List).cast<String>(),
        username: args['username'] as String,
        userIsWhite: args['userIsWhite'] as bool?,
        maxDepth: args['maxDepth'] as int,
        strictPlayerMatching: args['strictPlayerMatching'] as bool,
        onProgress: (processed, total) {
          sendPort.send({
            'type': 'progress',
            'processed': processed,
            'total': total,
          });
        },
      );
      sendPort.send({'type': 'result', 'payload': result});
    } catch (e) {
      sendPort.send({'type': 'error', 'error': e.toString()});
    }
  }

  /// Build the tree synchronously from a list of individual PGN game strings.
  ///
  /// Each element of [pgnList] must contain exactly one game (headers + moves).
  /// Multi-game strings in a single element are **not** expanded — only the
  /// first game will be parsed. Callers should pre-split if needed.
  static Map<String, dynamic> _buildTreeSync({
    required List<String> pgnList,
    required String username,
    required bool? userIsWhite,
    int maxDepth = 30,
    bool strictPlayerMatching = true,
    void Function(int processed, int total)? onProgress,
  }) {
    final tree = OpeningTree();
    final usernameLower = username.toLowerCase();
    final total = pgnList.length;
    var processed = 0;
    var skipped = 0;

    if (onProgress != null) onProgress(0, total);

    for (final pgnText in pgnList) {
      final trimmed = pgnText.trim();
      if (trimmed.isNotEmpty) {
        try {
          final game = PgnGame.parsePgn(trimmed);
          _processGame(tree, game, usernameLower, userIsWhite, maxDepth,
              strictPlayerMatching);
        } catch (_) {
          skipped++;
        }
      }
      processed++;
      if (onProgress != null &&
          (processed == total || processed % 25 == 0 || processed == 1)) {
        onProgress(processed, total);
      }
    }

    if (skipped > 0) {
      // ignore: avoid_print
      log.w(
          '[OpeningTreeBuilder] Skipped $skipped malformed games out of $total');
    }

    return tree.toTransferJson();
  }

  /// Check if a player name matches any known repertoire player pattern
  static bool _isRepertoirePlayer(String playerName) {
    final lowerName = playerName.toLowerCase();
    return _repertoirePlayerPatterns
        .any((pattern) => lowerName.contains(pattern));
  }

  static void _processGame(
    OpeningTree tree,
    PgnGame<PgnNodeData> game,
    String usernameLower,
    bool? userIsWhiteFilter,
    int maxDepth,
    bool strictPlayerMatching,
  ) {
    // 1. Safe Header Access
    final white = (game.headers['White'] ?? '').toLowerCase();
    final black = (game.headers['Black'] ?? '').toLowerCase();
    final result = game.headers['Result'] ?? '*';

    bool isUserWhiteInGame;

    if (!strictPlayerMatching) {
      // In Repertoire Mode, we don't filter by name.
      // We assume the userIsWhiteFilter dictates the perspective.
      // If no filter, we assume White perspective for stats (arbitrary but consistent).
      isUserWhiteInGame = userIsWhiteFilter ?? true;
    } else {
      // 2. Identify User - match by username OR any repertoire player pattern
      final whiteIsUser =
          white.contains(usernameLower) || _isRepertoirePlayer(white);
      final blackIsUser =
          black.contains(usernameLower) || _isRepertoirePlayer(black);

      // For repertoire files, if neither matches, try to infer from userIsWhiteFilter
      if (whiteIsUser && !blackIsUser) {
        isUserWhiteInGame = true;
      } else if (blackIsUser && !whiteIsUser) {
        isUserWhiteInGame = false;
      } else if (userIsWhiteFilter != null) {
        // Both or neither match - use the filter to decide
        isUserWhiteInGame = userIsWhiteFilter;
      } else {
        // Can't determine - skip game
        return;
      }

      // Apply color filter if specified
      if (userIsWhiteFilter != null && userIsWhiteFilter != isUserWhiteInGame) {
        return;
      }
    }

    // 3. Calculate Result
    final userResult = _calculateUserResult(result, isUserWhiteInGame);

    // 4. Traverse Moves using mainline() iterator
    Position position = Chess.initial;
    var currentNode = tree.root;

    // Update root stats
    currentNode.updateStats(userResult);

    int depth = 0;
    for (final nodeData in game.moves.mainline()) {
      if (depth >= maxDepth) break;

      try {
        final moveSan = nodeData.san;

        // Parse SAN into a Move object for the engine
        final move = position.parseSan(moveSan);
        if (move == null) break;

        // Apply move
        position = position.play(move);

        // Tree Building
        final childNode = currentNode.getOrCreateChild(moveSan, position.fen);
        childNode.updateStats(userResult);
        tree.indexNode(childNode);

        // Advance
        currentNode = childNode;
        depth++;
      } catch (e) {
        break; // Stop if an illegal move is encountered
      }
    }
  }

  static double _calculateUserResult(String result, bool userIsWhite) {
    final normalizedResult = result.trim();
    if (normalizedResult == '1-0') return userIsWhite ? 1.0 : 0.0;
    if (normalizedResult == '0-1') return userIsWhite ? 0.0 : 1.0;
    return 0.5; // Draws or '*'
  }
}
