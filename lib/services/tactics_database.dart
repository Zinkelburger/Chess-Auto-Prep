import 'package:csv/csv.dart';
import '../models/tactics_position.dart';
import 'storage/storage_factory.dart';

/// Manages tactical positions and review data
class TacticsDatabase {
  List<TacticsPosition> positions = [];
  Set<String> analyzedGameIds = {}; // Track which games have been analyzed
  ReviewSession currentSession = ReviewSession();
  int sessionPositionIndex = 0;

  /// Load positions from CSV file
  Future<int> loadPositions() async {
    positions.clear();
    analyzedGameIds.clear();

    try {
      final content = await StorageFactory.instance.readTacticsCsv();
      
      if (content == null || content.isEmpty) {
        // No CSV found, try to load analyzed games list (legacy or empty state)
        await _loadAnalyzedGameIds();
        return 0;
      }

      final rows = const CsvToListConverter().convert(content);

      if (rows.isEmpty) {
        await _loadAnalyzedGameIds();
        return 0;
      }

      // Skip header row
      for (int i = 1; i < rows.length; i++) {
        try {
          final position = _createPositionFromRow(rows[i]);
          if (position != null) {
            positions.add(position);
            // Track game IDs from positions
            if (position.gameId.isNotEmpty) {
              analyzedGameIds.add(position.gameId);
            }
          }
        } catch (e) {
          print('Error parsing position row $i: $e');
        }
      }

      // Also load the separate analyzed games list (includes games with no blunders)
      await _loadAnalyzedGameIds();

      print('Loaded ${positions.length} tactics positions from storage');
      print('Tracking ${analyzedGameIds.length} analyzed game IDs');
      return positions.length;
    } catch (e) {
      print('Error loading positions: $e');
      return 0;
    }
  }

  /// Load analyzed game IDs from storage
  Future<void> _loadAnalyzedGameIds() async {
    try {
      final ids = await StorageFactory.instance.readAnalyzedGameIds();
      if (ids.isNotEmpty) {
        analyzedGameIds.addAll(ids);
        print('Loaded ${ids.length} analyzed game IDs from storage');
      }
    } catch (e) {
      print('Error loading analyzed game IDs: $e');
    }
  }

  /// Save analyzed game IDs to storage
  Future<void> _saveAnalyzedGameIds() async {
    try {
      await StorageFactory.instance.saveAnalyzedGameIds(analyzedGameIds.toList());
      print('Saved ${analyzedGameIds.length} analyzed game IDs');
    } catch (e) {
      print('Error saving analyzed game IDs: $e');
    }
  }

  /// Mark a game as analyzed (even if no blunders found)
  Future<void> markGameAnalyzed(String gameId) async {
    if (gameId.isNotEmpty && !analyzedGameIds.contains(gameId)) {
      analyzedGameIds.add(gameId);
      await _saveAnalyzedGameIds();
    }
  }

  /// Mark multiple games as analyzed
  Future<void> markGamesAnalyzed(Iterable<String> gameIds) async {
    final newIds = gameIds.where((id) => id.isNotEmpty && !analyzedGameIds.contains(id));
    if (newIds.isNotEmpty) {
      analyzedGameIds.addAll(newIds);
      await _saveAnalyzedGameIds();
    }
  }

  /// Check if a game has already been analyzed
  bool isGameAnalyzed(String gameId) {
    return gameId.isNotEmpty && analyzedGameIds.contains(gameId);
  }

  /// Clear analyzed games tracking (for re-analysis)
  Future<void> clearAnalyzedGames() async {
    analyzedGameIds.clear();
    await StorageFactory.instance.saveAnalyzedGameIds([]);
    print('Cleared analyzed games tracking');
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

  /// Save positions back to CSV
  Future<void> savePositions() async {
    try {
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
      await StorageFactory.instance.saveTacticsCsv(csv);

      print('Saved ${positions.length} tactics positions to storage');
    } catch (e) {
      print('Error saving positions: $e');
    }
  }

  /// Clear all positions from database
  Future<void> clearPositions() async {
    positions.clear();
    await savePositions();
  }

  /// Start a new review session, starting at the least-reviewed position
  void startSession() {
    currentSession = ReviewSession();

    // Start at the least-reviewed position (pick up where you left off)
    if (positions.isNotEmpty) {
      int minReviews = positions.first.reviewCount;
      int minIndex = 0;
      for (int i = 1; i < positions.length; i++) {
        if (positions[i].reviewCount < minReviews) {
          minReviews = positions[i].reviewCount;
          minIndex = i;
        }
      }
      sessionPositionIndex = minIndex;
    }
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
    } else if (result == TacticsResult.incorrect) {
      currentSession.positionsIncorrect++;
    } else if (result == TacticsResult.hint) {
      currentSession.hintsUsed++;
    }

    // Save immediately
    await savePositions();
  }

  /// Import positions from Lichess/external source and save
  Future<void> importAndSave(List<TacticsPosition> newPositions) async {
    positions = newPositions;
    // Track game IDs from new positions
    for (final pos in newPositions) {
      if (pos.gameId.isNotEmpty) {
        analyzedGameIds.add(pos.gameId);
      }
    }
    await savePositions();
    await _saveAnalyzedGameIds();
  }

  /// Add a single position (for streaming/live import)
  Future<void> addPosition(TacticsPosition position) async {
    // Check for duplicates by FEN
    if (!positions.any((p) => p.fen == position.fen)) {
      positions.add(position);
      if (position.gameId.isNotEmpty) {
        analyzedGameIds.add(position.gameId);
      }
      await savePositions();
    }
  }

  /// Add multiple positions incrementally (for streaming/live import)
  Future<void> addPositions(List<TacticsPosition> newPositions) async {
    int added = 0;
    for (final position in newPositions) {
      // Check for duplicates by FEN
      if (!positions.any((p) => p.fen == position.fen)) {
        positions.add(position);
        if (position.gameId.isNotEmpty) {
          analyzedGameIds.add(position.gameId);
        }
        added++;
      }
    }
    if (added > 0) {
      await savePositions();
      await _saveAnalyzedGameIds();
      print('Added $added new positions (${newPositions.length - added} duplicates skipped)');
    }
  }
}

/// Result of attempting a tactical position
enum TacticsResult {
  correct,
  incorrect,
  hint,
  timeout,
}

/// Statistics for a review session
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
