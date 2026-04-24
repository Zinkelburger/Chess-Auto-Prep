/// Probability Service — tracks move probabilities from the Lichess Explorer
/// and exposes UI-facing notifiers for the engine pane and coverage widgets.
library;

import 'package:flutter/foundation.dart';
import 'package:dartchess/dartchess.dart';

import '../models/explorer_response.dart';
import 'lichess_api_client.dart';

// Re-export so existing `import 'probability_service.dart'` callers can
// still resolve these types without an extra import.
export '../models/explorer_response.dart' show ExplorerMove, ExplorerResponse;

/// Tracks a single move's probability in a line (for display breakdown).
class MoveInLineProbability {
  final int moveNumber;
  final String san;
  final bool isOpponentMove;
  final double? probability; // null when database data is unavailable
  final double cumulativeAfter;

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

  final ValueNotifier<ExplorerResponse?> currentPosition = ValueNotifier(null);
  final ValueNotifier<bool> isLoading = ValueNotifier(false);
  final ValueNotifier<String?> error = ValueNotifier(null);

  final Map<String, ExplorerResponse> _cache = {};

  String _cacheKey(
    String fen, {
    required String variant,
    required String speeds,
    required String ratings,
    bool useMasters = false,
  }) {
    final db = useMasters ? 'masters' : 'lichess';
    return '$db|$variant|$speeds|$ratings|$fen';
  }

  final ValueNotifier<double> cumulativeProbability = ValueNotifier(100.0);
  final ValueNotifier<List<MoveInLineProbability>> lineBreakdown =
      ValueNotifier([]);

  String startMoves = '';

  List<String> _parseStartMoves(String movesStr) {
    if (movesStr.trim().isEmpty) return [];
    final cleaned = movesStr
        .replaceAll(RegExp(r'\d+\.+\s*'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return [];
    return cleaned.split(' ').where((m) => m.isNotEmpty).toList();
  }

  String _getStartingFen(String movesStr) {
    final moves = _parseStartMoves(movesStr);
    if (moves.isEmpty) {
      return 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    }

    Position pos = Chess.initial;
    for (final san in moves) {
      final move = pos.parseSan(san);
      if (move == null) {
        if (kDebugMode) debugPrint('Invalid starting move: $san');
        break;
      }
      pos = pos.play(move);
    }
    return pos.fen;
  }

  /// Fetch move probabilities for a position from Lichess Explorer.
  ///
  /// Updates [currentPosition], [isLoading], and [error] notifiers.
  Future<ExplorerResponse?> fetchProbabilities(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '1800,2000,2200,2500',
    bool useMasters = false,
  }) async {
    final key = _cacheKey(
      fen,
      variant: variant,
      speeds: speeds,
      ratings: ratings,
      useMasters: useMasters,
    );
    if (_cache.containsKey(key)) {
      currentPosition.value = _cache[key];
      return _cache[key];
    }

    currentPosition.value = null;
    isLoading.value = true;
    error.value = null;

    try {
      final result = await _fetchInternal(
        fen,
        variant: variant,
        speeds: speeds,
        ratings: ratings,
        useMasters: useMasters,
      );

      currentPosition.value = result;
      isLoading.value = false;
      return result;
    } catch (e) {
      error.value = e.toString();
      isLoading.value = false;
      return null;
    }
  }

  /// Fetch probabilities for an arbitrary FEN without mutating UI state.
  ///
  /// Intended for background analysis (per-move ease, generation, etc.).
  Future<ExplorerResponse?> getProbabilitiesForFen(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '1800,2000,2200,2500',
    bool useMasters = false,
  }) {
    return _fetchInternal(
      fen,
      variant: variant,
      speeds: speeds,
      ratings: ratings,
      useMasters: useMasters,
    );
  }

  /// Calculate cumulative probability for a move sequence.
  /// Only opponent moves count against the probability.
  Future<double> calculateCumulativeProbability(
    List<String> moves, {
    required bool isUserWhite,
    String? startingMoves,
  }) async {
    final startMovesStr = startingMoves ?? startMoves;
    final startingFen = _getStartingFen(startMovesStr);
    final startMovesList = _parseStartMoves(startMovesStr);

    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(startingFen));
    } catch (_) {
      lineBreakdown.value = [];
      cumulativeProbability.value = 0.0;
      return 0.0;
    }

    double cumulative = 100.0;
    bool isWhiteTurn = startingFen.contains(' w ');
    final breakdown = <MoveInLineProbability>[];
    int moveNumber = startMovesList.length;

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

      if (i < skipCount) {
        // pos already starts at the position after the starting moves,
        // so don't toggle isWhiteTurn or advance pos for skipped moves.
        continue;
      }

      final isOpponentMove =
          (isWhiteTurn && !isUserWhite) || (!isWhiteTurn && isUserWhite);
      double? moveProb = 100.0;

      if (isOpponentMove) {
        final probs = await _fetchInternal(pos.fen);

        if (probs != null && probs.moves.isNotEmpty) {
          final foundMove = probs.moves.cast<ExplorerMove?>().firstWhere(
                (m) => m!.san == san,
                orElse: () => null,
              );

          if (foundMove != null && foundMove.playRate > 0) {
            moveProb = foundMove.playRate;
            cumulative *= moveProb / 100.0;
          } else {
            moveProb = 0.1;
            cumulative *= 0.001;
          }
        } else {
          moveProb = null;
        }
      }

      breakdown.add(MoveInLineProbability(
        moveNumber: moveNumber,
        san: san,
        isOpponentMove: isOpponentMove,
        probability: moveProb,
        cumulativeAfter: cumulative,
      ));

      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
      isWhiteTurn = !isWhiteTurn;
    }

    lineBreakdown.value = breakdown;
    cumulativeProbability.value = cumulative;
    return cumulative;
  }

  /// Internal fetch with caching.  Delegates HTTP + JSON parsing to
  /// [LichessApiClient.fetchExplorer] so there is exactly one parser.
  Future<ExplorerResponse?> _fetchInternal(
    String fen, {
    String variant = 'standard',
    String speeds = 'blitz,rapid,classical',
    String ratings = '1800,2000,2200,2500',
    bool useMasters = false,
  }) async {
    final key = _cacheKey(
      fen,
      variant: variant,
      speeds: speeds,
      ratings: ratings,
      useMasters: useMasters,
    );
    if (_cache.containsKey(key)) return _cache[key];

    final sw = Stopwatch()..start();
    final result = await LichessApiClient().fetchExplorer(
      fen,
      variant: variant,
      speeds: speeds,
      ratings: ratings,
      useMasters: useMasters,
    );
    final ms = sw.elapsedMilliseconds;

    if (kDebugMode && result != null) {
      debugPrint('[ProbService] ${ms}ms  ${result.moves.length} moves');
    }

    if (result != null) _cache[key] = result;
    return result;
  }

  /// Get probability for a specific move from the current position.
  double? getMoveProbability(String san) {
    final pos = currentPosition.value;
    if (pos == null) return null;
    for (final move in pos.moves) {
      if (move.san == san) return move.playRate;
    }
    return null;
  }

  /// Format a PGN with probability comments.
  String formatPgnWithProbabilities(
    String pgn,
    Map<String, double> moveProbabilities,
    Map<String, double> cumulativeProbabilities,
  ) {
    final lines = pgn.split('\n');
    final result = <String>[];

    for (final line in lines) {
      if (line.startsWith('[')) {
        result.add(line);
        continue;
      }

      var processedLine = line;
      for (final entry in moveProbabilities.entries) {
        final move = entry.key;
        final prob = entry.value;
        final cumulative = cumulativeProbabilities[move] ?? 100.0;
        final comment = '{MoveProb: ${prob.toStringAsFixed(1)}% '
            'Cumulative: ${cumulative.toStringAsFixed(1)}%}';
        processedLine = processedLine.replaceFirst(move, '$move $comment');
      }

      result.add(processedLine);
    }

    return result.join('\n');
  }

  void clearCache() => _cache.clear();
}
