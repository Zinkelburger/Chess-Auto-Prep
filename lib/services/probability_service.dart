/// Probability Service - Tracks move probabilities based on database statistics
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:chess/chess.dart' as chess;

/// Stores probability data for a single move
class MoveProbability {
  final String san;
  final String uci;
  final int white;
  final int draws;
  final int black;
  final double probability; // Percentage of games with this move

  MoveProbability({
    required this.san,
    required this.uci,
    required this.white,
    required this.draws,
    required this.black,
    required this.probability,
  });

  int get total => white + draws + black;

  String get formattedProbability => '${probability.toStringAsFixed(1)}%';

  /// Format for PGN comment
  String toPgnComment() => '{Move probability: ${probability.toStringAsFixed(1)}%}';
}

/// Result of fetching position probabilities
class PositionProbabilities {
  final String fen;
  final List<MoveProbability> moves;
  final int totalGames;

  PositionProbabilities({
    required this.fen,
    required this.moves,
    required this.totalGames,
  });
}

/// Tracks a single move's probability in a line (for showing the breakdown)
class MoveInLineProbability {
  final int moveNumber;
  final String san;
  final bool isOpponentMove;
  final double probability; // 100 for user moves, database % for opponent moves
  final double cumulativeAfter; // Cumulative probability after this move

  MoveInLineProbability({
    required this.moveNumber,
    required this.san,
    required this.isOpponentMove,
    required this.probability,
    required this.cumulativeAfter,
  });
}

class ProbabilityService {
  static final ProbabilityService _instance = ProbabilityService._internal();
  factory ProbabilityService() => _instance;

  ProbabilityService._internal();

  final ValueNotifier<PositionProbabilities?> currentPosition = ValueNotifier(null);
  final ValueNotifier<bool> isLoading = ValueNotifier(false);
  final ValueNotifier<String?> error = ValueNotifier(null);

  // Cache for position data
  final Map<String, PositionProbabilities> _cache = {};

  // Stored cumulative probabilities for current line
  final ValueNotifier<double> cumulativeProbability = ValueNotifier(100.0);
  
  // Track individual move probabilities for the current line (for display)
  final ValueNotifier<List<MoveInLineProbability>> lineBreakdown = ValueNotifier([]);
  
  String _startMoves = '';
  
  set startMoves(String moves) {
    _startMoves = moves;
  }

  String get startMoves => _startMoves;
  
  /// Convert starting moves string to a list of SAN moves
  List<String> _parseStartMoves(String movesStr) {
    if (movesStr.trim().isEmpty) return [];
    
    // Remove move numbers and periods, keep just the moves
    // e.g., "1. d4 d5 2. Nf3" -> ["d4", "d5", "Nf3"]
    final cleaned = movesStr
        .replaceAll(RegExp(r'\d+\.+\s*'), ' ') // Remove "1." or "1..."
        .replaceAll(RegExp(r'\s+'), ' ')       // Normalize whitespace
        .trim();
    
    if (cleaned.isEmpty) return [];
    
    return cleaned.split(' ').where((m) => m.isNotEmpty).toList();
  }
  
  /// Get the FEN after playing starting moves
  String _getStartingFen(String movesStr) {
    final moves = _parseStartMoves(movesStr);
    if (moves.isEmpty) {
      return 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    }
    
    final game = chess.Chess();
    for (final san in moves) {
      if (!game.move(san)) {
        print('Invalid starting move: $san');
        break;
      }
    }
    return game.fen;
  }

  /// Fetch move probabilities for a position from Lichess Explorer
  Future<PositionProbabilities?> fetchProbabilities(String fen, {
    String variant = 'standard',
    String speeds = 'rapid,classical',
    String ratings = '1800,2000,2200,2500',
  }) async {
    // Check cache first
    final cacheKey = fen;
    if (_cache.containsKey(cacheKey)) {
      currentPosition.value = _cache[cacheKey];
      return _cache[cacheKey];
    }

    // Clear old position data immediately when fetching for a new FEN
    // This prevents showing stale data from a different position
    currentPosition.value = null;
    
    isLoading.value = true;
    error.value = null;

    try {
      final encodedFen = Uri.encodeComponent(fen);
      final url = 'https://explorer.lichess.ovh/lichess?'
          'variant=$variant&'
          'speeds=$speeds&'
          'ratings=$ratings&'
          'fen=$encodedFen';

      final response = await http.get(Uri.parse(url));

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch data: ${response.statusCode}');
      }

      final data = json.decode(response.body);

      final moves = <MoveProbability>[];
      int totalGames = 0;

      // Calculate total games across all moves
      for (final move in data['moves'] ?? []) {
        final white = move['white'] as int? ?? 0;
        final draws = move['draws'] as int? ?? 0;
        final black = move['black'] as int? ?? 0;
        totalGames += white + draws + black;
      }

      // Now calculate probability for each move
      for (final move in data['moves'] ?? []) {
        final white = move['white'] as int? ?? 0;
        final draws = move['draws'] as int? ?? 0;
        final black = move['black'] as int? ?? 0;
        final moveTotal = white + draws + black;

        final probability = totalGames > 0 ? (moveTotal / totalGames) * 100 : 0.0;

        moves.add(MoveProbability(
          san: move['san'] as String? ?? '',
          uci: move['uci'] as String? ?? '',
          white: white,
          draws: draws,
          black: black,
          probability: probability,
        ));
      }

      // Sort by probability descending
      moves.sort((a, b) => b.probability.compareTo(a.probability));

      final result = PositionProbabilities(
        fen: fen,
        moves: moves,
        totalGames: totalGames,
      );

      _cache[cacheKey] = result;
      currentPosition.value = result;
      isLoading.value = false;

      return result;

    } catch (e) {
      error.value = e.toString();
      isLoading.value = false;
      return null;
    }
  }

  /// Calculate cumulative probability for a move sequence
  /// Only opponent moves count against the probability
  Future<double> calculateCumulativeProbability(
    List<String> moves, {
    required bool isUserWhite,
    String? startingMoves,
  }) async {
    // Convert starting moves to FEN
    final startMovesStr = startingMoves ?? _startMoves;
    final startingFen = _getStartingFen(startMovesStr);
    final startMovesList = _parseStartMoves(startMovesStr);
    
    final game = chess.Chess.fromFEN(startingFen);
    
    double cumulative = 100.0;
    bool isWhiteTurn = startingFen.contains(' w ');
    final breakdown = <MoveInLineProbability>[];
    int moveNumber = startMovesList.length; // Start counting after the starting moves
    
    // Check if the moves list starts with the starting moves
    // If so, skip them since probability starts after those moves
    int skipCount = 0;
    if (startMovesList.isNotEmpty) {
      bool startsWithPrefix = true;
      for (int i = 0; i < startMovesList.length && i < moves.length; i++) {
        if (moves[i] != startMovesList[i]) {
          startsWithPrefix = false;
          break;
        }
      }
      if (startsWithPrefix) {
        skipCount = startMovesList.length;
      }
    }

    for (int i = 0; i < moves.length; i++) {
      final san = moves[i];
      moveNumber++;
      
      // Skip moves that are part of the starting moves prefix
      if (i < skipCount) {
        // Just advance the turn tracking
        isWhiteTurn = !isWhiteTurn;
        continue;
      }
      
      final isOpponentMove = (isWhiteTurn && !isUserWhite) || (!isWhiteTurn && isUserWhite);
      double moveProb = 100.0; // Default for user moves

      if (isOpponentMove) {
        // Fetch probabilities for this position (without updating currentPosition)
        final probs = await _fetchProbabilitiesInternal(game.fen);
        
        if (probs != null && probs.moves.isNotEmpty) {
          // Find the probability for this move
          final foundMove = probs.moves.firstWhere(
            (m) => m.san == san,
            orElse: () => MoveProbability(
              san: san, 
              uci: '', 
              white: 0, 
              draws: 0, 
              black: 0, 
              probability: 0,
            ),
          );

          if (foundMove.probability > 0) {
            // Normal case: use the database probability
            moveProb = foundMove.probability;
            cumulative *= moveProb / 100.0;
          } else {
            // Move not found in database - treat as rare (0.1%)
            moveProb = 0.1;
            cumulative *= 0.001;
          }
        } else {
          // No database data available - show as unknown
          moveProb = -1; // -1 indicates unknown
        }
      }

      // Track this move in the breakdown
      breakdown.add(MoveInLineProbability(
        moveNumber: moveNumber,
        san: san,
        isOpponentMove: isOpponentMove,
        probability: moveProb,
        cumulativeAfter: cumulative,
      ));

      // Make the move
      if (!game.move(san)) {
        break;
      }
      isWhiteTurn = !isWhiteTurn;
    }

    lineBreakdown.value = breakdown;
    cumulativeProbability.value = cumulative;
    return cumulative;
  }

  /// Internal fetch that doesn't update currentPosition (for cumulative calculations)
  Future<PositionProbabilities?> _fetchProbabilitiesInternal(String fen, {
    String variant = 'standard',
    String speeds = 'rapid,classical',
    String ratings = '1800,2000,2200,2500',
  }) async {
    // Check cache first
    final cacheKey = fen;
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    try {
      final encodedFen = Uri.encodeComponent(fen);
      final url = 'https://explorer.lichess.ovh/lichess?'
          'variant=$variant&'
          'speeds=$speeds&'
          'ratings=$ratings&'
          'fen=$encodedFen';

      final response = await http.get(Uri.parse(url));

      if (response.statusCode != 200) {
        return null;
      }

      final data = json.decode(response.body);

      final moves = <MoveProbability>[];
      int totalGames = 0;

      for (final move in data['moves'] ?? []) {
        final white = move['white'] as int? ?? 0;
        final draws = move['draws'] as int? ?? 0;
        final black = move['black'] as int? ?? 0;
        totalGames += white + draws + black;
      }

      for (final move in data['moves'] ?? []) {
        final white = move['white'] as int? ?? 0;
        final draws = move['draws'] as int? ?? 0;
        final black = move['black'] as int? ?? 0;
        final moveTotal = white + draws + black;

        final probability = totalGames > 0 ? (moveTotal / totalGames) * 100 : 0.0;

        moves.add(MoveProbability(
          san: move['san'] as String? ?? '',
          uci: move['uci'] as String? ?? '',
          white: white,
          draws: draws,
          black: black,
          probability: probability,
        ));
      }

      moves.sort((a, b) => b.probability.compareTo(a.probability));

      final result = PositionProbabilities(
        fen: fen,
        moves: moves,
        totalGames: totalGames,
      );

      _cache[cacheKey] = result;
      return result;

    } catch (e) {
      return null;
    }
  }

  /// Get probability for a specific move from the current position
  double? getMoveProbability(String san) {
    final pos = currentPosition.value;
    if (pos == null) return null;

    for (final move in pos.moves) {
      if (move.san == san) {
        return move.probability;
      }
    }
    return null;
  }

  /// Format a PGN with probability comments
  /// Adds comments like {Move probability: 45%} {Cumulative: 3%}
  String formatPgnWithProbabilities(
    String pgn,
    Map<String, double> moveProbabilities,
    Map<String, double> cumulativeProbabilities,
  ) {
    // This is a simplified version - you'd want to properly parse and format the PGN
    final lines = pgn.split('\n');
    final result = <String>[];

    for (final line in lines) {
      if (line.startsWith('[')) {
        result.add(line);
        continue;
      }

      // Process move text
      var processedLine = line;
      for (final entry in moveProbabilities.entries) {
        final move = entry.key;
        final prob = entry.value;
        final cumulative = cumulativeProbabilities[move] ?? 100.0;
        
        final comment = '{MoveProb: ${prob.toStringAsFixed(1)}% Cumulative: ${cumulative.toStringAsFixed(1)}%}';
        processedLine = processedLine.replaceFirst(
          move,
          '$move $comment',
        );
      }

      result.add(processedLine);
    }

    return result.join('\n');
  }

  void clearCache() {
    _cache.clear();
  }
}

