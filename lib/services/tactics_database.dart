import 'dart:math';

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import '../models/tactics_set_metadata.dart';
import 'storage/storage_factory.dart';
import 'package:chess_auto_prep/utils/log.dart';

/// Manages tactical positions and review data.
///
/// This is a [ChangeNotifier]: every mutation of the observable state
/// (the [positions] list, [analyzedGameIds], session stats) calls
/// [notifyListeners] so the UI can rebuild reactively instead of relying on
/// each call site remembering to `setState`. Mutate the data only through the
/// methods on this class — never poke [positions] directly from the UI.
class TacticsDatabase extends ChangeNotifier {
  /// Name of the set legacy single-file installs migrate into.
  static const String defaultSetName = 'Default';

  /// SharedPreferences key remembering the last active set across launches.
  static const String _activeSetPrefsKey = 'tactics_active_set';

  List<TacticsPosition> positions = [];
  Set<String> analyzedGameIds = {}; // Track which games have been analyzed
  ReviewSession currentSession = ReviewSession();
  int sessionPositionIndex = 0;
  Future<void> _pendingWrite = Future<void>.value();

  /// The named set currently loaded into [positions].
  String _activeSetName = defaultSetName;
  String get activeSetName => _activeSetName;

  /// Metadata for every set on disk (for the set picker).
  List<TacticsSetMetadata> availableSets = [];

  /// Whether the active-set name has been restored from prefs this run.
  bool _activeSetRestored = false;

  /// The filtered + ordered queue for the active session.
  /// `null` when no session is active.
  List<int> _sessionQueue = [];

  /// Index into [_sessionQueue].
  int _sessionQueueIndex = 0;

  /// Settings for the current session (kept for mid-session rating logic).
  TacticsSessionSettings _sessionSettings = const TacticsSessionSettings();

  /// Load positions for the active set from its CSV file.
  ///
  /// On first call this also migrates a legacy root-level
  /// `tactics_positions.csv` into the [defaultSetName] set and restores the
  /// last active set name from preferences.
  Future<int> loadPositions() async {
    await _pendingWrite;
    positions.clear();
    analyzedGameIds.clear();

    try {
      final storage = StorageFactory.instance;
      await storage.migrateLegacyTacticsCsv(defaultSetName);
      final restoredNow = !_activeSetRestored;
      await _restoreActiveSetName();
      availableSets = await storage.listTacticsSets();

      // If the *remembered* set vanished (deleted externally), fall back.
      // Only on the prefs-restore load: an explicitly chosen set (switchSet /
      // createSet) may legitimately have no file until its first save.
      if (restoredNow &&
          availableSets.isNotEmpty &&
          !availableSets.any((s) => s.name == _activeSetName)) {
        _activeSetName = availableSets.any((s) => s.name == defaultSetName)
            ? defaultSetName
            : availableSets.first.name;
      }

      final content =
          await storage.readFile(await storage.tacticsSetPath(_activeSetName));

      if (content == null || content.isEmpty) {
        // No CSV found, try to load analyzed games list (legacy or empty state)
        await _loadAnalyzedGameIds();
        notifyListeners();
        return 0;
      }

      final rows = Csv().decode(content);

      if (rows.isEmpty) {
        await _loadAnalyzedGameIds();
        notifyListeners();
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
          log.e('Error parsing position row $i: $e');
        }
      }

      // Also load the separate analyzed games list (includes games with no blunders)
      await _loadAnalyzedGameIds();

      log.i(
          'Loaded ${positions.length} tactics positions from set "$_activeSetName"');
      log.i('Tracking ${analyzedGameIds.length} analyzed game IDs');
      notifyListeners();
      return positions.length;
    } catch (e) {
      log.e('Error loading positions: $e');
      notifyListeners();
      return 0;
    }
  }

  /// Restore the active set name from preferences (first load only).
  Future<void> _restoreActiveSetName() async {
    if (_activeSetRestored) return;
    _activeSetRestored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_activeSetPrefsKey);
      if (stored != null && stored.isNotEmpty) {
        _activeSetName = stored;
      }
    } catch (e) {
      log.e('Error restoring active tactics set: $e');
    }
  }

  Future<void> _persistActiveSetName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeSetPrefsKey, _activeSetName);
    } catch (e) {
      log.e('Error persisting active tactics set: $e');
    }
  }

  // ── Set management ─────────────────────────────────────────────────────

  /// Re-scan the sets directory (e.g. after external changes).
  Future<void> refreshSetList() async {
    availableSets = await StorageFactory.instance.listTacticsSets();
    notifyListeners();
  }

  /// Switch to another named set: waits for pending writes to the current
  /// set, then loads [name].  Any active session queue is discarded (its
  /// indices refer to the old set's positions).
  Future<void> switchSet(String name) async {
    if (name == _activeSetName) return;
    await _pendingWrite;
    _activeSetName = name;
    _sessionQueue = [];
    _sessionQueueIndex = 0;
    currentSession = ReviewSession();
    await _persistActiveSetName();
    await loadPositions();
  }

  /// Create a new empty set and switch to it.  Throws [ArgumentError] if a
  /// set with that name already exists.
  Future<void> createSet(String name) async {
    final storage = StorageFactory.instance;
    final path = await storage.tacticsSetPath(name);
    if (await storage.fileExists(path)) {
      throw ArgumentError('A set named "$name" already exists');
    }
    await storage.writeFile(path, _encodeCsv(const []));
    await switchSet(name);
  }

  /// Rename a set (the active one keeps its contents loaded).  Throws
  /// [ArgumentError] if the target name is taken.
  Future<void> renameSet(String oldName, String newName) async {
    if (oldName == newName) return;
    final storage = StorageFactory.instance;
    final oldPath = await storage.tacticsSetPath(oldName);
    final newPath = await storage.tacticsSetPath(newName);
    if (await storage.fileExists(newPath)) {
      throw ArgumentError('A set named "$newName" already exists');
    }
    await _pendingWrite;
    await storage.renameFile(oldPath, newPath);
    if (_activeSetName == oldName) {
      _activeSetName = newName;
      await _persistActiveSetName();
    }
    await refreshSetList();
  }

  /// Delete a set's file.  Deleting the active set clears the in-memory
  /// positions and switches to another set (or an empty [defaultSetName]).
  Future<void> deleteSetByName(String name) async {
    await _pendingWrite;
    await StorageFactory.instance.deleteTacticsSet(name);
    availableSets = await StorageFactory.instance.listTacticsSets();
    if (_activeSetName == name) {
      _activeSetName = availableSets.isNotEmpty
          ? availableSets.first.name
          : defaultSetName;
      _sessionQueue = [];
      _sessionQueueIndex = 0;
      currentSession = ReviewSession();
      await _persistActiveSetName();
      await loadPositions();
    } else {
      notifyListeners();
    }
  }

  /// Load analyzed game IDs from storage
  Future<void> _loadAnalyzedGameIds() async {
    try {
      final ids = await StorageFactory.instance.readAnalyzedGameIds();
      if (ids.isNotEmpty) {
        analyzedGameIds.addAll(ids);
        log.i('Loaded ${ids.length} analyzed game IDs from storage');
      }
    } catch (e) {
      log.e('Error loading analyzed game IDs: $e');
    }
  }

  /// Save analyzed game IDs to storage
  Future<void> _saveAnalyzedGameIds() async {
    await _enqueueWrite(() async {
      try {
        await StorageFactory.instance.saveAnalyzedGameIds(
          analyzedGameIds.toList(),
        );
        log.e('Saved ${analyzedGameIds.length} analyzed game IDs');
      } catch (e) {
        log.e('Error saving analyzed game IDs: $e');
      }
    });
  }

  /// Mark a game as analyzed (even if no blunders found)
  Future<void> markGameAnalyzed(String gameId) async {
    if (gameId.isNotEmpty && !analyzedGameIds.contains(gameId)) {
      analyzedGameIds.add(gameId);
      notifyListeners();
      await _saveAnalyzedGameIds();
    }
  }

  /// Mark multiple games as analyzed
  Future<void> markGamesAnalyzed(Iterable<String> gameIds) async {
    final newIds =
        gameIds.where((id) => id.isNotEmpty && !analyzedGameIds.contains(id));
    if (newIds.isNotEmpty) {
      analyzedGameIds.addAll(newIds);
      notifyListeners();
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
    notifyListeners();
    await _enqueueWrite(() async {
      await StorageFactory.instance.saveAnalyzedGameIds([]);
      log.i('Cleared analyzed games tracking');
    });
  }

  /// Create a TacticsPosition from a CSV row.
  TacticsPosition? _createPositionFromRow(List<dynamic> row) {
    if (row.length < 17) {
      log.w('Row too short: ${row.length} fields');
      return null;
    }

    try {
      return TacticsPosition.fromCsv(row);
    } catch (e) {
      log.e('Error creating position from row: $e');
      return null;
    }
  }

  /// Encode [rows] as the tactics CSV format (header + data rows).
  static String _encodeCsv(List<TacticsPosition> rows) {
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
      ],
      for (final pos in rows) pos.toCsvRow(),
    ];
    return Csv().encode(csvData);
  }

  /// Save positions back to the active set's CSV.
  Future<void> savePositions() async {
    // Capture the target set now: a switchSet() while this write is queued
    // must not redirect the old set's data into the new file.
    final setName = _activeSetName;
    await _enqueueWrite(() async {
      try {
        final storage = StorageFactory.instance;
        await storage.writeFile(
            await storage.tacticsSetPath(setName), _encodeCsv(positions));
        log.i('Saved ${positions.length} tactics positions to set "$setName"');
      } catch (e) {
        log.e('Error saving positions: $e');
      }
    });
  }

  /// Clear all positions from database
  Future<void> clearPositions() async {
    positions.clear();
    notifyListeners();
    await savePositions();
  }

  /// Delete the position at [index] (UI-facing; encapsulates list mutation so
  /// callers never touch [positions] directly).
  Future<void> deletePositionAt(int index) async {
    if (index < 0 || index >= positions.length) return;
    positions.removeAt(index);
    notifyListeners();
    await savePositions();
  }

  /// Replace the position at [index] with [updated] (e.g. after an edit).
  Future<void> updatePositionAt(int index, TacticsPosition updated) async {
    if (index < 0 || index >= positions.length) return;
    positions[index] = updated;
    notifyListeners();
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

    // Keep each game's positions together, in the order they occurred. The
    // sort above still decides which game comes first (via the game's first
    // position in that order).
    if (settings.groupByGame) {
      final gameRank = <String, int>{};
      for (final idx in _sessionQueue) {
        gameRank.putIfAbsent(positions[idx].gameId, () => gameRank.length);
      }
      _sessionQueue.sort((a, b) {
        final ra = gameRank[positions[a].gameId]!;
        final rb = gameRank[positions[b].gameId]!;
        if (ra != rb) return ra.compareTo(rb);
        return positions[a].moveNumber.compareTo(positions[b].moveNumber);
      });
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

    notifyListeners();
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

    notifyListeners();

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
    notifyListeners();
    await savePositions();
    await _saveAnalyzedGameIds();
  }

  /// Add [position] to the set named [setName].
  ///
  /// For the active set this is [addPosition].  For any other set it is a
  /// write-through: load that set's CSV, dedupe by FEN, append, write back —
  /// without disturbing the in-memory active set.  Returns `true` when the
  /// position was added (`false` = duplicate FEN).
  Future<bool> addPositionToSet(String setName, TacticsPosition position) async {
    if (setName == _activeSetName) {
      final before = positions.length;
      await addPosition(position);
      return positions.length > before;
    }

    final storage = StorageFactory.instance;
    final path = await storage.tacticsSetPath(setName);
    final content = await storage.readFile(path);

    final existing = <TacticsPosition>[];
    if (content != null && content.isNotEmpty) {
      final rows = Csv().decode(content);
      for (int i = 1; i < rows.length; i++) {
        final parsed = _createPositionFromRow(rows[i]);
        if (parsed != null) existing.add(parsed);
      }
    }
    if (existing.any((p) => p.fen == position.fen)) return false;

    existing.add(position);
    await storage.writeFile(path, _encodeCsv(existing));
    await refreshSetList();
    return true;
  }

  /// Add a single position (for streaming/live import)
  Future<void> addPosition(TacticsPosition position) async {
    // Check for duplicates by FEN
    if (!positions.any((p) => p.fen == position.fen)) {
      positions.add(position);
      if (position.gameId.isNotEmpty) {
        analyzedGameIds.add(position.gameId);
      }
      notifyListeners();
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
      notifyListeners();
      await savePositions();
      await _saveAnalyzedGameIds();
      log.w(
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
