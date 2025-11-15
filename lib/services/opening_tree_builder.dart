/// Opening tree builder - Builds a move tree from PGN games
/// Similar to how openingtree.com builds its database

import 'package:dartchess_webok/dartchess_webok.dart';
import '../models/opening_tree.dart';

class OpeningTreeBuilder {
  /// Build an opening tree from a list of PGN strings
  ///
  /// Parameters:
  /// - pgnList: List of PGN game strings
  /// - username: Player's username to track
  /// - userIsWhite: Whether the user plays white (null = include all games)
  /// - maxDepth: Maximum ply depth to analyze (default: 30)
  static Future<OpeningTree> buildTree({
    required List<String> pgnList,
    required String username,
    required bool userIsWhite,
    int maxDepth = 30,
  }) async {
    final tree = OpeningTree();
    final usernameLower = username.toLowerCase();

    for (final pgnText in pgnList) {
      try {
        await _processGame(
          tree,
          pgnText,
          usernameLower,
          userIsWhite,
          maxDepth,
        );
      } catch (e) {
        // Skip malformed PGNs
        continue;
      }
    }

    return tree;
  }

  /// Process a single game and add it to the tree
  static Future<void> _processGame(
    OpeningTree tree,
    String pgnText,
    String usernameLower,
    bool userIsWhite,
    int maxDepth,
  ) async {
    final lines = pgnText.split('\n');

    // Parse headers
    String? white;
    String? black;
    String? result;

    for (final line in lines) {
      if (line.startsWith('[White "')) {
        white = _extractHeader(line);
      } else if (line.startsWith('[Black "')) {
        black = _extractHeader(line);
      } else if (line.startsWith('[Result "')) {
        result = _extractHeader(line);
      }
    }

    if (white == null || black == null || result == null) return;

    // Determine if user played this game and their color
    final whiteIsUser = white.toLowerCase() == usernameLower;
    final blackIsUser = black.toLowerCase() == usernameLower;

    // Skip if user didn't play in this game
    if (!whiteIsUser && !blackIsUser) return;

    // Determine user's color in this game
    final gameUserWhite = whiteIsUser;

    // Skip if color doesn't match filter
    if (userIsWhite != gameUserWhite) return;

    // Extract moves from PGN
    final moves = _extractMoves(pgnText);
    if (moves.isEmpty) return;

    // Calculate result from user's perspective (1.0 = win, 0.5 = draw, 0.0 = loss)
    final userResult = _calculateUserResult(result, gameUserWhite);

    // Traverse tree and add/update nodes using dartchess
    Position position = Chess.initial;
    var currentNode = tree.root;

    // Update root node stats
    currentNode.updateStats(userResult);

    // Process moves
    for (int i = 0; i < moves.length && i < maxDepth; i++) {
      try {
        // The move string from PGN is already in SAN format
        final moveSan = moves[i];

        // Try to parse the move using dartchess
        final move = position.parseSan(moveSan);
        if (move == null) break;

        // Make the move
        position = position.play(move);

        // Get FEN after the move
        final fenAfterMove = position.fen;

        // Get or create child node
        final childNode = currentNode.getOrCreateChild(moveSan, fenAfterMove);

        // Update statistics
        childNode.updateStats(userResult);

        // Index this node by FEN for quick lookup
        tree.indexNode(childNode);

        // Move to child node
        currentNode = childNode;
      } catch (e) {
        // Invalid move, stop processing this game
        break;
      }
    }
  }

  /// Extract header value from PGN header line
  static String _extractHeader(String line) {
    final start = line.indexOf('"') + 1;
    final end = line.lastIndexOf('"');
    if (start > 0 && end > start) {
      return line.substring(start, end);
    }
    return '';
  }

  /// Extract moves from PGN text
  static List<String> _extractMoves(String pgnText) {
    final moves = <String>[];
    final lines = pgnText.split('\n');

    // Find the moves section (after headers, before result)
    final moveBuffer = StringBuffer();

    for (final line in lines) {
      if (line.startsWith('[')) {
        continue;
      }

      // Non-empty, non-header line = moves
      if (line.trim().isNotEmpty) {
        moveBuffer.write(line);
        moveBuffer.write(' ');
      }
    }

    // Parse moves from buffer
    final moveText = moveBuffer.toString();

    // Remove move numbers and result notation
    var cleaned = moveText
        .replaceAll(RegExp(r'\d+\.'), ' ') // Remove move numbers
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ') // Remove comments in braces
        .replaceAll(RegExp(r'1-0|0-1|1/2-1/2|\*'), '') // Remove result
        .replaceAll(RegExp(r'\s+'), ' ') // Normalize whitespace
        .trim();

    // Split into individual moves
    final tokens = cleaned.split(' ');

    for (final token in tokens) {
      final trimmed = token.trim();
      // Skip empty tokens, brackets, and PGN ellipsis notation (.., ...)
      if (trimmed.isNotEmpty &&
          !trimmed.contains('[') &&
          !trimmed.contains(']') &&
          trimmed != '..' &&
          trimmed != '...') {
        moves.add(trimmed);
      }
    }

    return moves;
  }

  /// Calculate game result from user's perspective
  static double _calculateUserResult(String result, bool userIsWhite) {
    if (result == '1-0') {
      return userIsWhite ? 1.0 : 0.0;
    } else if (result == '0-1') {
      return userIsWhite ? 0.0 : 1.0;
    } else {
      // Draw or unknown
      return 0.5;
    }
  }

  /// Get shortened FEN key (without move counters)
  static String _getFenKey(Position position) {
    final fen = position.fen;
    final parts = fen.split(' ');
    if (parts.length >= 4) {
      return '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]}';
    }
    return fen;
  }
}
