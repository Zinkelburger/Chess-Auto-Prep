import 'package:dartchess_webok/dartchess_webok.dart';
import '../models/opening_tree.dart';

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
    required bool? userIsWhite, // Nullable to allow "All Colors"
    int maxDepth = 30,
    bool strictPlayerMatching = true, // New parameter
  }) async {
    final tree = OpeningTree();
    final usernameLower = username.toLowerCase();

    // 1. Combine all PGNs into one block
    final fullPgnText = pgnList.join('\n\n');

    // 2. Parse everything at once using the library
    // This handles variations (..), comments {}, and headers automatically.
    final pgnGames = PgnGame.parseMultiGamePgn(fullPgnText);

    for (final game in pgnGames) {
      _processGame(tree, game, usernameLower, userIsWhite, maxDepth, strictPlayerMatching);
    }

    return tree;
  }

  /// Check if a player name matches any known repertoire player pattern
  static bool _isRepertoirePlayer(String playerName) {
    final lowerName = playerName.toLowerCase();
    return _repertoirePlayerPatterns.any((pattern) => lowerName.contains(pattern));
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
      final whiteIsUser = white.contains(usernameLower) || _isRepertoirePlayer(white);
      final blackIsUser = black.contains(usernameLower) || _isRepertoirePlayer(black);

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
    if (result.contains('1-0')) return userIsWhite ? 1.0 : 0.0;
    if (result.contains('0-1')) return userIsWhite ? 0.0 : 1.0;
    return 0.5; // Draws or '*'
  }
}