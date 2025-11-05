/// FenMapBuilder service - Flutter port of Python's fen_map_builder.py
/// Builds a mapping of FEN positions to aggregate statistics

import 'package:chess/chess.dart' as chess;
import '../models/position_analysis.dart';

class FenMapBuilder {
  final Map<String, PositionStats> fenMap = {};

  /// Process PGN list and update FEN statistics
  /// If userIsWhite is true/false, only process games where user color matches
  Future<void> processPgns(
    List<String> pgnList,
    String username,
    bool userIsWhite,
  ) async {
    final usernameLower = username.toLowerCase();

    for (final pgnText in pgnList) {
      try {
        final game = chess.Chess();
        final lines = pgnText.split('\n');

        // Parse headers
        String? white;
        String? black;
        String? result;
        String? site;

        for (final line in lines) {
          if (line.startsWith('[White "')) {
            white = _extractHeader(line);
          } else if (line.startsWith('[Black "')) {
            black = _extractHeader(line);
          } else if (line.startsWith('[Result "')) {
            result = _extractHeader(line);
          } else if (line.startsWith('[Site "')) {
            site = _extractHeader(line);
          }
        }

        if (white == null || result == null) continue;

        // Determine user color for this game
        final gameUserWhite = white.toLowerCase() == usernameLower;

        // Skip if color doesn't match filter
        if (userIsWhite != gameUserWhite) continue;

        // Extract moves from PGN
        final moves = _extractMoves(pgnText);

        _updateFenMapForGame(moves, result, gameUserWhite, site ?? '');
      } catch (e) {
        // Skip malformed PGNs
        continue;
      }
    }
  }

  /// Update FEN map for all positions in a single game
  void _updateFenMapForGame(
    List<String> moves,
    String finalResult,
    bool isUserWhite,
    String gameUrl,
  ) {
    final board = chess.Chess();
    final positionsSeen = <String>{};

    for (int i = 0; i < moves.length && i < 30; i++) {
      try {
        board.move(moves[i]);
        final fenKey = _fenKeyFromBoard(board);

        if (!positionsSeen.contains(fenKey)) {
          positionsSeen.add(fenKey);
          _updateFenStats(fenKey, finalResult, isUserWhite, gameUrl);
        }
      } catch (e) {
        // Skip invalid moves
        break;
      }
    }
  }

  /// Convert board to shortened FEN key (without move counters)
  String _fenKeyFromBoard(chess.Chess board) {
    final fenFull = board.fen;
    final parts = fenFull.split(' ');
    if (parts.length >= 4) {
      return '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]}';
    }
    return fenFull;
  }

  /// Update stats for a single FEN position
  void _updateFenStats(
    String fenKey,
    String finalResult,
    bool isUserWhite,
    String gameUrl,
  ) {
    if (!fenMap.containsKey(fenKey)) {
      fenMap[fenKey] = PositionStats(fen: fenKey);
    }

    final node = fenMap[fenKey]!;
    node.games++;

    // Add game URL if not already there
    if (gameUrl.isNotEmpty && !node.gameUrls.contains(gameUrl)) {
      node.gameUrls.add(gameUrl);
    }

    // Update win/loss/draw stats
    if (finalResult == '1-0') {
      if (isUserWhite) {
        node.wins++;
      } else {
        node.losses++;
      }
    } else if (finalResult == '0-1') {
      if (isUserWhite) {
        node.losses++;
      } else {
        node.wins++;
      }
    } else if (finalResult == '1/2-1/2') {
      node.draws++;
    }
  }

  /// Create PositionAnalysis from FenMapBuilder results
  static Future<PositionAnalysis> fromFenMapBuilder(
    FenMapBuilder fenBuilder,
    List<String> pgnList,
  ) async {
    final analysis = PositionAnalysis();

    // Add all position stats
    for (final entry in fenBuilder.fenMap.entries) {
      analysis.addPositionStats(entry.value);
    }

    // Add games and create mappings
    for (final pgnText in pgnList) {
      try {
        final gameInfo = GameInfo.fromPgn(pgnText);
        final gameIndex = analysis.addGame(gameInfo);

        // Parse game to find which FENs it contains
        final board = chess.Chess();
        final moves = _extractMoves(pgnText);
        final seenFens = <String>{};

        for (final move in moves) {
          try {
            board.move(move);
            final fenKey = _fenKeyFromBoardStatic(board);

            if (analysis.positionStats.containsKey(fenKey) &&
                !seenFens.contains(fenKey)) {
              analysis.linkFenToGame(fenKey, gameIndex);
              seenFens.add(fenKey);
            }
          } catch (e) {
            break;
          }
        }
      } catch (e) {
        continue;
      }
    }

    return analysis;
  }

  static String _fenKeyFromBoardStatic(chess.Chess board) {
    final fenFull = board.fen;
    final parts = fenFull.split(' ');
    if (parts.length >= 4) {
      return '${parts[0]} ${parts[1]} ${parts[2]} ${parts[3]}';
    }
    return fenFull;
  }

  static String _extractHeader(String line) {
    final start = line.indexOf('"') + 1;
    final end = line.lastIndexOf('"');
    if (start > 0 && end > start) {
      return line.substring(start, end);
    }
    return '';
  }

  static List<String> _extractMoves(String pgnText) {
    final moves = <String>[];
    final lines = pgnText.split('\n');

    // Find move text (after headers)
    bool inMoves = false;
    final moveText = StringBuffer();

    for (final line in lines) {
      if (line.trim().isEmpty) {
        inMoves = true;
        continue;
      }
      if (inMoves && !line.startsWith('[')) {
        moveText.write(line);
        moveText.write(' ');
      }
    }

    // Parse moves from move text
    final text = moveText.toString();
    // Remove move numbers, comments, and result
    final cleaned = text
        .replaceAll(RegExp(r'\d+\.'), '')
        .replaceAll(RegExp(r'\{[^}]*\}'), '')
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .replaceAll(RegExp(r'1-0|0-1|1/2-1/2|\*'), '')
        .trim();

    // Split by whitespace and filter empty
    final tokens = cleaned.split(RegExp(r'\s+'));
    for (final token in tokens) {
      if (token.isNotEmpty) {
        moves.add(token);
      }
    }

    return moves;
  }

  /// Get worst performing positions
  List<String> getWorstPerformingPositions({
    int topN = 5,
    int minOccurrences = 4,
  }) {
    final qualifying = fenMap.entries
        .where((e) => e.value.games >= minOccurrences)
        .toList();

    if (qualifying.isEmpty) return [];

    // Sort by win rate (ascending - worst first)
    qualifying.sort((a, b) => a.value.winRate.compareTo(b.value.winRate));

    return qualifying.take(topN).map((e) => e.key).toList();
  }
}
