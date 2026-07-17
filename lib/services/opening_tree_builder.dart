import 'dart:async';
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';
import '../models/opening_tree.dart';
import 'package:chess_auto_prep/utils/log.dart';

import 'pgn_tree_core.dart';

class OpeningTreeBuilder {
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
    final isolate =
        await Isolate.spawn<Map<String, dynamic>>(_buildTreeSyncIsolateEntry, {
          'sendPort': receivePort.sendPort,
          'pgnList': pgnList,
          'username': username,
          'userIsWhite': userIsWhite,
          'maxDepth': maxDepth,
          'strictPlayerMatching': strictPlayerMatching,
        });

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
          completer.completeError(
            Exception(message['error'] ?? 'Unknown error'),
          );
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
          _processGame(
            tree,
            game,
            usernameLower,
            userIsWhite,
            maxDepth,
            strictPlayerMatching,
          );
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
        '[OpeningTreeBuilder] Skipped $skipped malformed games out of $total',
      );
    }

    return tree.toTransferJson();
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
    final white = game.headers['White'] ?? '';
    final black = game.headers['Black'] ?? '';
    final result = game.headers['Result'] ?? '*';

    // 2. Identify User. Games whose colour can't be determined are skipped.
    final isUserWhiteInGame = resolveUserColor(
      whiteHeader: white,
      blackHeader: black,
      usernameLower: usernameLower,
      userIsWhiteFilter: userIsWhiteFilter,
      strictPlayerMatching: strictPlayerMatching,
      unattributablePolicy: UnattributableGamePolicy.skip,
    );
    if (isUserWhiteInGame == null) return;

    // 3. Calculate Result
    final userResult = resultForUser(result, isUserWhiteInGame);

    // 4. Traverse Moves using mainline() iterator (always from the standard
    // initial position — this builder ignores any [FEN] start header).
    walkMainlineIntoTree(
      tree: tree,
      game: game,
      userResult: userResult,
      maxDepth: maxDepth,
    );
  }
}
