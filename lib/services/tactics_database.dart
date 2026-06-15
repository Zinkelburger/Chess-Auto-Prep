import 'dart:math';

import 'package:csv/csv.dart';
import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import 'storage/storage_factory.dart';

/// Manages tactical positions and review data
class TacticsDatabase {
  List<TacticsPosition> positions = [];
  Set<String> analyzedGameIds = {}; // Track which games have been analyzed
  ReviewSession currentSession = ReviewSession();
  int sessionPositionIndex = 0;
  Future<void> _pendingWrite = Future<void>.value();

  /// The filtered + ordered queue for the active session.
  /// `null` when no session is active.
  List<int> _sessionQueue = [];

  /// Index into [_sessionQueue].
  int _sessionQueueIndex = 0;

  /// Settings for the current session (kept for mid-session rating logic).
  TacticsSessionSettings _sessionSettings = const TacticsSessionSettings();

  /// Load positions from CSV file
  Future<int> loadPositions() async {
    await _pendingWrite;
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
    await _enqueueWrite(() async {
      try {
        await StorageFactory.instance.saveAnalyzedGameIds(
          analyzedGameIds.toList(),
        );
        print('Saved ${analyzedGameIds.length} analyzed game IDs');
      } catch (e) {
        print('Error saving analyzed game IDs: $e');
      }
    });
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
    final newIds =
        gameIds.where((id) => id.isNotEmpty && !analyzedGameIds.contains(id));
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
    await _enqueueWrite(() async {
      await StorageFactory.instance.saveAnalyzedGameIds([]);
      print('Cleared analyzed games tracking');
    });
  }

  /// Create a TacticsPosition from a CSV row.
  TacticsPosition? _createPositionFromRow(List<dynamic> row) {
    if (row.length < 17) {
      print('Row too short: ${row.length} fields');
      return null;
    }

    try {
      return TacticsPosition.fromCsv(row);
    } catch (e) {
      print('Error creating position from row: $e');
      return null;
    }
  }

  /// Save positions back to CSV
  Future<void> savePositions() async {
    await _enqueueWrite(() async {
      try {
        // Create CSV data
        final List<List<dynamic>> csvData = [
          // Header row — must match toCsvRow() column order exactly.
          [
            'fen',
            'game_white',
            'game_black',
            'game_result',
            'game_date',
            'game_id',
            'game_url',
            'position_context',
            'user_move',
            'correct_line',
            'mistake_type',
            'mistake_analysis',
            'review_count',
            'success_count',
            'last_reviewed',
            'time_to_solve',
            'hints_used',
            'opponent_best_response',
            'rating',
          ]
        ];

        // Data rows
        for (final pos in positions) {
          csvData.add(pos.toCsvRow());
        }

        final csv = const ListToCsvConverter().convert(csvData);
        await StorageFactory.instance.saveTacticsCsv(csv);

        print('Saved ${positions.length} tactics positions to storage');
      } catch (e) {
        print('Error saving positions: $e');
      }
    });
  }

  /// Clear all positions from database
  Future<void> clearPositions() async {
    positions.clear();
    await savePositions();
  }

  /// Start a new review session with the given [settings].
  void startSession(
      [TacticsSessionSettings settings = const TacticsSessionSettings()]) {
    currentSession = ReviewSession();
    _sessionSettings = settings;

    // Build filtered queue of indices into [positions].
    _sessionQueue = <int>[];
    for (int i = 0; i < positions.length; i++) {
      if (settings.accepts(positions[i])) _sessionQueue.add(i);
    }

    // Sort / shuffle per ordering preference.
    switch (settings.order) {
      case TacticsSessionOrder.newestFirst:
        _sessionQueue.sort(
            (a, b) => positions[b].gameDate.compareTo(positions[a].gameDate));
      case TacticsSessionOrder.leastReviewed:
        _sessionQueue.sort((a, b) =>
            positions[a].reviewCount.compareTo(positions[b].reviewCount));
      case TacticsSessionOrder.worstSuccessRate:
        _sessionQueue.sort((a, b) =>
            positions[a].successRate.compareTo(positions[b].successRate));
      case TacticsSessionOrder.random:
        _sessionQueue.shuffle(Random());
    }

    _sessionQueueIndex = 0;
    sessionPositionIndex = _sessionQueue.isNotEmpty ? _sessionQueue.first : 0;
  }

  /// Number of positions in the current session queue.
  int get sessionQueueLength => _sessionQueue.length;

  /// Current 0-based position within the session queue.
  int get sessionQueuePosition => _sessionQueueIndex;

  /// Remove a position (by index into [positions]) from the live session queue.
  void removeFromSessionQueue(int positionIndex) {
    final queueIdx = _sessionQueue.indexOf(positionIndex);
    if (queueIdx == -1) return;
    _sessionQueue.removeAt(queueIdx);
    if (_sessionQueueIndex >= _sessionQueue.length &&
        _sessionQueue.isNotEmpty) {
      _sessionQueueIndex = 0;
    }
  }

  /// Advance to the next position in the session queue.  Returns the index
  /// into [positions], or `null` when the queue is exhausted.
  int? nextSessionPosition() {
    if (_sessionQueue.isEmpty) return null;
    _sessionQueueIndex = (_sessionQueueIndex + 1) % _sessionQueue.length;
    sessionPositionIndex = _sessionQueue[_sessionQueueIndex];
    return sessionPositionIndex;
  }

  /// Go to the previous position in the session queue.
  int? previousSessionPosition() {
    if (_sessionQueue.isEmpty) return null;
    _sessionQueueIndex--;
    if (_sessionQueueIndex < 0) {
      _sessionQueueIndex = _sessionQueue.length - 1;
    }
    sessionPositionIndex = _sessionQueue[_sessionQueueIndex];
    return sessionPositionIndex;
  }

  /// The current session settings.
  TacticsSessionSettings get sessionSettings => _sessionSettings;

  /// Set the star [rating] on the position matching [fen].
  Future<void> setRating(String fen, int rating) async {
    final index = positions.indexWhere((p) => p.fen == fen);
    if (index == -1) return;
    positions[index] = positions[index].copyWith(rating: rating);

    // If rated 1 and 1-star is excluded, remove from live session queue.
    if (rating == 1 && !_sessionSettings.includeOneStar) {
      removeFromSessionQueue(index);
    }

    await savePositions();
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

    // Update only the stats that changed — copyWith preserves everything else.
    final updatedPosition = position.copyWith(
      reviewCount: position.reviewCount + 1,
      successCount:
          position.successCount + (result == TacticsResult.correct ? 1 : 0),
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
      await _saveAnalyzedGameIds();
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
      print(
          'Added $added new positions (${newPositions.length - added} duplicates skipped)');
    }
  }

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final next = _pendingWrite.then((_) => operation());
    _pendingWrite = next.catchError((_) {});
    return next;
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

  double get accuracy =>
      positionsAttempted > 0 ? positionsCorrect / positionsAttempted : 0.0;
}
