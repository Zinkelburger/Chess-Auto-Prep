import 'dart:math';

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import 'storage/storage_factory.dart';
import 'tactics_pgn_codec.dart';
import 'package:chess_auto_prep/utils/log.dart';

/// Manages tactical positions and review data.
///
/// Tactics mode owns a single database — the mistakes mined from the user's
/// own games — stored as a multi-game PGN file
/// (`tactics_sets/<defaultSetName>.pgn`) via the lossless codec in
/// `tactics_pgn_codec.dart`; legacy CSV files are converted on first load.
/// An *external* PGN file (e.g. a study opened for flashcard review) can be
/// loaded temporarily instead — see [openExternalSet] / [closeExternalSet].
///
/// This is a [ChangeNotifier]: every mutation of the observable state
/// (the [positions] list, [analyzedGameIds], session stats) calls
/// [notifyListeners] so the UI can rebuild reactively instead of relying on
/// each call site remembering to `setState`. Mutate the data only through the
/// methods on this class — never poke [positions] directly from the UI.
class TacticsDatabase extends ChangeNotifier {
  /// Name of the single set file backing the tactics database.
  static const String defaultSetName = 'Default';

  List<TacticsPosition> positions = [];
  Set<String> analyzedGameIds = {}; // Track which games have been analyzed
  ReviewSession currentSession = ReviewSession();
  int sessionPositionIndex = 0;
  Future<void> _pendingWrite = Future<void>.value();

  /// Display name of what's loaded into [positions]: [defaultSetName] for
  /// the tactics database, or the external file's name during a review.
  String _activeSetName = defaultSetName;
  String get activeSetName => _activeSetName;

  /// When non-null, the active set is an external PGN file at this absolute
  /// path (e.g. a study reviewed as flashcards) instead of a named set in
  /// the sets directory.  Stats write back into that file's headers.
  String? _activeSetPath;
  String? get activeSetPath => _activeSetPath;
  bool get isExternalSet => _activeSetPath != null;

  /// Decode options for the active external set (see [openExternalSet]):
  /// restrict to one PGN game (chapter) and/or expand variations into cards.
  int? _externalGameIndex;
  bool _externalIncludeVariations = false;

  /// Absolute path of the file backing the active set.
  Future<String> activeSetFilePath() async =>
      _activeSetPath ??
      await StorageFactory.instance.tacticsSetPath(_activeSetName);

  /// Whether the one-time named-set → studies migration ran this launch.
  bool _setsMigrated = false;

  /// The filtered + ordered queue for the active session.
  /// `null` when no session is active.
  List<int> _sessionQueue = [];

  /// Index into [_sessionQueue].
  int _sessionQueueIndex = 0;

  /// Furthest queue index reached this session (the "head"). Navigating back
  /// with Previous doesn't lower it, so `_sessionQueueIndex < head` means the
  /// user is reviewing an already-seen puzzle.
  int _sessionMaxQueueIndex = 0;

  /// Settings for the current session (kept for mid-session rating logic).
  TacticsSessionSettings _sessionSettings = const TacticsSessionSettings();

  /// Load positions for the active set from its PGN file.
  ///
  /// On first call this also migrates a legacy root-level
  /// `tactics_positions.csv` into the [defaultSetName] set, converts any
  /// legacy per-set CSV files to PGN, and moves leftover named sets from the
  /// multi-set era into the studies directory.
  Future<int> loadPositions() async {
    await _pendingWrite;
    positions.clear();
    analyzedGameIds.clear();

    try {
      final storage = StorageFactory.instance;
      await storage.migrateLegacyTacticsCsv(defaultSetName);
      await _migrateCsvSetsToPgn();
      await _migrateNamedSetsToStudies();

      final content = await storage.readFile(await activeSetFilePath());

      if (content == null || content.trim().isEmpty) {
        // No set file yet — load analyzed games list (legacy or empty state).
        await _loadAnalyzedGameIds();
        notifyListeners();
        return 0;
      }

      // External files (studies) may hold chapters from the standard start;
      // our own set files always carry [FEN].
      final decoded = await compute(_decodePuzzlesEntry, (
        content: content,
        requireFen: !isExternalSet,
        includeVariations: isExternalSet && _externalIncludeVariations,
        onlyGame: isExternalSet ? _externalGameIndex : null,
      ));
      for (final warning in decoded.errors) {
        log.w('Set "$_activeSetName": $warning');
      }
      for (final position in decoded.puzzles) {
        positions.add(position);
        if (position.gameId.isNotEmpty) {
          analyzedGameIds.add(position.gameId);
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

  /// Convert legacy `.csv` set files (pre-PGN installs) to `.pgn`.  The CSV
  /// is renamed to `.csv.bak` after a successful conversion; a name that
  /// already has a `.pgn` file is left alone.
  Future<void> _migrateCsvSetsToPgn() async {
    final storage = StorageFactory.instance;
    for (final legacy in await storage.listLegacyTacticsCsvSets()) {
      try {
        final pgnPath = await storage.tacticsSetPath(legacy.name);
        if (await storage.fileExists(pgnPath)) continue;
        final content = await storage.readFile(legacy.path);
        if (content == null) continue;
        final parsed = parseCsv(content);
        for (final warning in parsed.warnings) {
          log.w('CSV set "${legacy.name}": $warning');
        }
        final encoded = encodePuzzlesToPgn(legacy.name, parsed.positions);
        await storage.writeFile(pgnPath, encoded.pgn);
        await storage.renameFile(legacy.path, '${legacy.path}.bak');
        log.i(
            'Converted tactics set "${legacy.name}" from CSV to PGN (${parsed.positions.length} positions)');
      } catch (e) {
        log.e('Error converting CSV set "${legacy.name}": $e');
      }
    }
  }

  /// One-time cleanup from the multi-set era: tactics mode now owns a single
  /// database (the [defaultSetName] set), so any other set file is moved into
  /// the studies directory, where it stays reachable — studies are the
  /// curated-collection concept and can be reviewed as flashcards from
  /// Study mode.
  Future<void> _migrateNamedSetsToStudies() async {
    if (_setsMigrated) return;
    _setsMigrated = true;
    final storage = StorageFactory.instance;
    for (final set in await storage.listTacticsSets()) {
      if (set.name == defaultSetName) continue;
      try {
        var targetName = set.name;
        var suffix = 1;
        while (
            await storage.fileExists(await storage.studyFilePath(targetName))) {
          suffix++;
          targetName = '${set.name} (tactics${suffix > 2 ? ' $suffix' : ''})';
        }
        await storage.renameFile(
            set.filePath, await storage.studyFilePath(targetName));
        log.i('Moved tactics set "${set.name}" to studies as "$targetName"');
      } catch (e) {
        log.e('Error moving tactics set "${set.name}" to studies: $e');
      }
    }
  }

  // ── External review (study flashcards) ─────────────────────────────────

  /// Open an arbitrary PGN file (e.g. a study) as the active set for
  /// flashcard review.  Review stats write back into that file's custom
  /// headers.  [gameIndex] restricts the set to one game/chapter;
  /// [includeVariations] expands variations into extra (stat-less) cards.
  /// Returns the number of loaded puzzles.
  Future<int> openExternalSet(
    String path, {
    String? displayName,
    int? gameIndex,
    bool includeVariations = false,
  }) async {
    await _pendingWrite;
    _activeSetPath = path;
    _externalGameIndex = gameIndex;
    _externalIncludeVariations = includeVariations;
    _activeSetName = displayName ??
        path.split('/').last.replaceAll(RegExp(r'\.pgn$', caseSensitive: false), '');
    _sessionQueue = [];
    _sessionQueueIndex = 0;
    _sessionMaxQueueIndex = 0;
    currentSession = ReviewSession();
    return loadPositions();
  }

  /// Leave an external review and return to the tactics database.  Waits for
  /// pending stat writes to the external file first.  No-op when no external
  /// set is active.
  Future<void> closeExternalSet() async {
    if (!isExternalSet) return;
    await _pendingWrite;
    _activeSetPath = null;
    _externalGameIndex = null;
    _externalIncludeVariations = false;
    _activeSetName = defaultSetName;
    _sessionQueue = [];
    _sessionQueueIndex = 0;
    _sessionMaxQueueIndex = 0;
    currentSession = ReviewSession();
    await loadPositions();
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

  /// Parse tactics-CSV [content] (with header row) into positions.
  /// Bad rows are reported as warnings instead of failing the whole file.
  static ({List<TacticsPosition> positions, List<String> warnings}) parseCsv(
      String content) {
    final positions = <TacticsPosition>[];
    final warnings = <String>[];
    if (content.trim().isEmpty) {
      return (positions: positions, warnings: warnings);
    }
    final rows = Csv().decode(content);
    for (int i = 1; i < rows.length; i++) {
      try {
        positions.add(TacticsPosition.fromCsv(rows[i]));
      } catch (e) {
        warnings.add('Row $i: $e');
      }
    }
    return (positions: positions, warnings: warnings);
  }

  /// Save positions back to the active set's PGN file.
  ///
  /// Named sets are fully rewritten (they are flat puzzle files owned by the
  /// trainer).  External sets (studies) are *patched*: only the stat headers
  /// change, so variations and annotations survive — structural edits to a
  /// study belong in Study mode.
  Future<void> savePositions() async {
    // Capture the target set now: a switchSet() while this write is queued
    // must not redirect the old set's data into the new file.
    final setName = _activeSetName;
    final externalPath = _activeSetPath;
    final snapshot = List<TacticsPosition>.of(positions);
    await _enqueueWrite(() async {
      try {
        final storage = StorageFactory.instance;
        if (externalPath != null) {
          final existing = await storage.readFile(externalPath);
          if (existing == null) {
            log.e('External set file vanished: $externalPath');
            return;
          }
          await storage.writeFile(externalPath,
              await compute(_patchStatsEntry, (existing, snapshot)));
        } else {
          final encoded =
              await compute(_encodePuzzlesEntry, (setName, snapshot));
          if (encoded.fallback > 0) {
            log.w(
                '${encoded.fallback} position(s) stored with raw [CorrectLine] fallback');
          }
          if (encoded.dropped > 0) {
            log.w(
                '${encoded.dropped} position(s) with unparsable FEN dropped on save');
          }
          await storage.writeFile(
              await storage.tacticsSetPath(setName), encoded.pgn);
        }
        log.i('Saved ${snapshot.length} tactics positions to set "$setName"');
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
    _sessionMaxQueueIndex = 0;
    sessionPositionIndex = _sessionQueue.isNotEmpty ? _sessionQueue.first : 0;
  }

  /// Start a session over exactly [subset], in the given order — e.g.
  /// "Retry mistakes" from the session recap.  Positions are matched by FEN
  /// against the loaded database; unknown FENs are skipped.
  void startSessionWithPositions(List<TacticsPosition> subset) {
    currentSession = ReviewSession();
    _sessionQueue = <int>[];
    for (final pos in subset) {
      final idx = positions.indexWhere((p) => p.fen == pos.fen);
      if (idx != -1 && !_sessionQueue.contains(idx)) _sessionQueue.add(idx);
    }
    _sessionQueueIndex = 0;
    _sessionMaxQueueIndex = 0;
    sessionPositionIndex = _sessionQueue.isNotEmpty ? _sessionQueue.first : 0;
  }

  /// Number of positions in the current session queue.
  int get sessionQueueLength => _sessionQueue.length;

  /// Current 0-based position within the session queue.
  int get sessionQueuePosition => _sessionQueueIndex;

  /// True while the user has navigated back below the session head — i.e.
  /// the shown puzzle was already completed or skipped this session.
  bool get isViewingPastSessionPuzzle =>
      _sessionQueue.isNotEmpty && _sessionQueueIndex < _sessionMaxQueueIndex;

  /// Remove a position (by index into [positions]) from the live session queue.
  void removeFromSessionQueue(int positionIndex) {
    final queueIdx = _sessionQueue.indexOf(positionIndex);
    if (queueIdx == -1) return;
    _sessionQueue.removeAt(queueIdx);
    if (queueIdx < _sessionQueueIndex) {
      _sessionQueueIndex--;
    } else if (_sessionQueueIndex >= _sessionQueue.length &&
        _sessionQueue.isNotEmpty) {
      _sessionQueueIndex = _sessionQueue.length - 1;
    }
    if (queueIdx < _sessionMaxQueueIndex) _sessionMaxQueueIndex--;
    if (_sessionMaxQueueIndex < _sessionQueueIndex) {
      _sessionMaxQueueIndex = _sessionQueueIndex;
    }
  }

  /// Advance to the next position in the session queue.  Returns the index
  /// into [positions], or `null` when the last position has been reached —
  /// the session is over (no wrap-around).
  int? nextSessionPosition() {
    if (_sessionQueue.isEmpty) return null;
    if (_sessionQueueIndex >= _sessionQueue.length - 1) return null;
    _sessionQueueIndex++;
    if (_sessionQueueIndex > _sessionMaxQueueIndex) {
      _sessionMaxQueueIndex = _sessionQueueIndex;
    }
    sessionPositionIndex = _sessionQueue[_sessionQueueIndex];
    return sessionPositionIndex;
  }

  /// Go to the previous position in the session queue, stopping at the first
  /// position (no wrap-around).
  int? previousSessionPosition() {
    if (_sessionQueue.isEmpty) return null;
    if (_sessionQueueIndex > 0) _sessionQueueIndex--;
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

  /// Add [position] to the tactics database (the [defaultSetName] file).
  ///
  /// Normally this is [addPosition]; during an external review the loaded
  /// positions belong to the study file, so the puzzle is written through
  /// to the database's own file on disk instead (an external save only
  /// patches stat headers and would silently drop a new position).
  /// Returns `true` when added (`false` = duplicate FEN).
  Future<bool> addPositionToDatabase(TacticsPosition position) async {
    if (!isExternalSet) return addPosition(position);

    final storage = StorageFactory.instance;
    final path = await storage.tacticsSetPath(defaultSetName);
    final content = await storage.readFile(path);
    final existing = <TacticsPosition>[];
    if (content != null && content.trim().isNotEmpty) {
      final decoded = await compute(_decodePuzzlesEntry, (
        content: content,
        requireFen: true,
        includeVariations: false,
        onlyGame: null,
      ));
      existing.addAll(decoded.puzzles);
    }
    if (existing.any((p) => p.fen == position.fen)) return false;
    existing.add(position);
    final encoded =
        await compute(_encodePuzzlesEntry, (defaultSetName, existing));
    await storage.writeFile(path, encoded.pgn);
    return true;
  }

  /// Add a single position (streaming import, puzzle creator).  Returns
  /// `true` when the position was added (`false` = duplicate FEN).
  Future<bool> addPosition(TacticsPosition position) async {
    // Check for duplicates by FEN
    if (positions.any((p) => p.fen == position.fen)) return false;
    positions.add(position);
    if (position.gameId.isNotEmpty) {
      analyzedGameIds.add(position.gameId);
    }
    notifyListeners();
    await savePositions();
    await _saveAnalyzedGameIds();
    return true;
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

// ── compute() entry points ─────────────────────────────────────────────────
// The PGN codec is pure CPU work: on a set of hundreds of puzzles a decode
// or full re-encode blocks long enough to drop frames, and savePositions()
// runs once per streamed tactic during imports.  These wrappers let the
// database run the codec off the UI isolate.

({List<TacticsPosition> puzzles, List<String> errors}) _decodePuzzlesEntry(
        ({
          String content,
          bool requireFen,
          bool includeVariations,
          int? onlyGame,
        }) args) =>
    decodePuzzlesFromPgn(
      args.content,
      requireFen: args.requireFen,
      includeVariations: args.includeVariations,
      onlyGame: args.onlyGame,
    );

({String pgn, int encoded, int fallback, int dropped}) _encodePuzzlesEntry(
        (String, List<TacticsPosition>) args) =>
    encodePuzzlesToPgn(args.$1, args.$2);

String _patchStatsEntry((String, List<TacticsPosition>) args) =>
    patchStatsInPgn(args.$1, args.$2);

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
