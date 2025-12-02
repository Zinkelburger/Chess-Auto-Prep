import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import '../models/tactics_position.dart';

/// Manages tactical positions and review data - Flutter port of Python's TacticsDatabase
class TacticsDatabase {
  static const String _csvFileName = 'tactics_positions.csv';

  List<TacticsPosition> positions = [];
  ReviewSession currentSession = ReviewSession();
  int sessionPositionIndex = 0;

  /// Load positions from CSV file
  Future<int> loadPositions() async {
    positions.clear();

    try {
      final file = await _getCsvFile();
      if (!await file.exists()) {
        print('No tactics CSV file found at ${file.path}');
        return 0;
      }

      final content = await file.readAsString();
      final rows = const CsvToListConverter().convert(content);

      if (rows.isEmpty) return 0;

      // Skip header row
      for (int i = 1; i < rows.length; i++) {
        try {
          final position = _createPositionFromRow(rows[i]);
          if (position != null) {
            positions.add(position);
          }
        } catch (e) {
          print('Error parsing position row $i: $e');
        }
      }

      print('Loaded ${positions.length} tactics positions from CSV');
      return positions.length;
    } catch (e) {
      print('Error loading positions: $e');
      return 0;
    }
  }

  /// Create a TacticsPosition from a CSV row
  TacticsPosition? _createPositionFromRow(List<dynamic> row) {
    if (row.length < 18) {
      print('Row too short: ${row.length} fields');
      return null;
    }

    try {
      return TacticsPosition(
        fen: row[0].toString(),
        gameWhite: row[1].toString(),
        gameBlack: row[2].toString(),
        gameResult: row[3].toString(),
        gameDate: row[4].toString(),
        gameId: row[5].toString(),
        gameUrl: row[6].toString(),
        positionContext: row[7].toString(),
        userMove: row[8].toString(),
        correctLine: row[9].toString().split('|').where((s) => s.isNotEmpty).toList(),
        mistakeType: row[10].toString(),
        mistakeAnalysis: row[11].toString(),
        difficulty: int.tryParse(row[12].toString()) ?? 1,
        reviewCount: int.tryParse(row[13].toString()) ?? 0,
        successCount: int.tryParse(row[14].toString()) ?? 0,
        lastReviewed: row[15].toString().isNotEmpty
            ? DateTime.tryParse(row[15].toString())
            : null,
        timeToSolve: double.tryParse(row[16].toString()) ?? 0.0,
        hintsUsed: int.tryParse(row[17].toString()) ?? 0,
      );
    } catch (e) {
      print('Error creating position from row: $e');
      return null;
    }
  }

  /// Save positions back to CSV file
  Future<void> savePositions() async {
    try {
      final file = await _getCsvFile();

      // Create CSV data
      final List<List<dynamic>> csvData = [
        // Header row matching Python's field names
        [
          'fen', 'game_white', 'game_black', 'game_result', 'game_date',
          'game_id', 'game_url', 'position_context', 'user_move', 'correct_line',
          'mistake_type', 'mistake_analysis', 'difficulty', 'review_count',
          'success_count', 'last_reviewed', 'time_to_solve', 'hints_used'
        ]
      ];

      // Data rows
      for (final pos in positions) {
        csvData.add([
          pos.fen,
          pos.gameWhite,
          pos.gameBlack,
          pos.gameResult,
          pos.gameDate,
          pos.gameId,
          pos.gameUrl,
          pos.positionContext,
          pos.userMove,
          pos.correctLine.join('|'),
          pos.mistakeType,
          pos.mistakeAnalysis,
          pos.difficulty,
          pos.reviewCount,
          pos.successCount,
          pos.lastReviewed?.toIso8601String() ?? '',
          pos.timeToSolve,
          pos.hintsUsed,
        ]);
      }

      final csv = const ListToCsvConverter().convert(csvData);
      await file.writeAsString(csv);

      print('Saved ${positions.length} tactics positions to CSV');
    } catch (e) {
      print('Error saving positions: $e');
    }
  }

  /// Clear all positions from database
  Future<void> clearPositions() async {
    positions.clear();
    await savePositions();
  }

  /// Get positions for linear review - matches Python logic
  List<TacticsPosition> getPositionsForReview(int limit) {
    if (positions.isEmpty) return [];

    if (sessionPositionIndex >= positions.length) {
      sessionPositionIndex = 0;
    }

    // Find starting point - first position with fewer reviews than max
    final maxReviews = positions.map((p) => p.reviewCount).reduce((a, b) => a > b ? a : b);

    // Start from current index and find first position with < max reviews
    final startingIndex = sessionPositionIndex;
    for (int i = 0; i < positions.length; i++) {
      final index = (startingIndex + i) % positions.length;
      if (positions[index].reviewCount < maxReviews) {
        sessionPositionIndex = index;
        return [positions[index]];
      }
    }

    // If all have max reviews, start from current index
    if (sessionPositionIndex >= positions.length) {
      sessionPositionIndex = 0;
    }

    return [positions[sessionPositionIndex]];
  }

  /// Start a new review session
  void startSession() {
    currentSession = ReviewSession();
  }

  /// Record an attempt at a position
  Future<void> recordAttempt(
    TacticsPosition position,
    TacticsResult result,
    double timeTaken, {
    int hintsUsed = 0,
  }) async {
    // Find the position in our list and update it
    final index = positions.indexWhere((p) => p.fen == position.fen);
    if (index == -1) return;

    // Create updated position with new stats
    final updatedPosition = TacticsPosition(
      fen: position.fen,
      gameWhite: position.gameWhite,
      gameBlack: position.gameBlack,
      gameResult: position.gameResult,
      gameDate: position.gameDate,
      gameId: position.gameId,
      gameUrl: position.gameUrl,
      positionContext: position.positionContext,
      userMove: position.userMove,
      correctLine: position.correctLine,
      mistakeType: position.mistakeType,
      mistakeAnalysis: position.mistakeAnalysis,
      difficulty: position.difficulty,
      reviewCount: position.reviewCount + 1,
      successCount: position.successCount + (result == TacticsResult.correct ? 1 : 0),
      lastReviewed: DateTime.now(),
      timeToSolve: timeTaken,
      hintsUsed: position.hintsUsed + hintsUsed,
    );

    positions[index] = updatedPosition;

    // Update session stats
    currentSession.positionsAttempted++;
    currentSession.totalTime += timeTaken;

    if (result == TacticsResult.correct) {
      currentSession.positionsCorrect++;
      // Advance to next position in linear sequence
      sessionPositionIndex = (sessionPositionIndex + 1) % positions.length;
    } else if (result == TacticsResult.incorrect) {
      currentSession.positionsIncorrect++;
    } else if (result == TacticsResult.hint) {
      currentSession.hintsUsed++;
    }

    // Save immediately like Python does
    await savePositions();
  }

  /// Get the CSV file path
  Future<File> _getCsvFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_csvFileName');
  }

  /// Import positions from Lichess/external source and save to CSV
  Future<void> importAndSave(List<TacticsPosition> newPositions) async {
    positions = newPositions;
    await savePositions();
  }
}

/// Result of attempting a tactical position - matches Python enum
enum TacticsResult {
  correct,
  incorrect,
  hint,
  timeout,
}

/// Statistics for a review session - matches Python's ReviewSession
class ReviewSession {
  int positionsAttempted = 0;
  int positionsCorrect = 0;
  int positionsIncorrect = 0;
  int hintsUsed = 0;
  double totalTime = 0.0;
  DateTime startTime = DateTime.now();

  double get accuracy => positionsAttempted > 0
      ? positionsCorrect / positionsAttempted
      : 0.0;
}
