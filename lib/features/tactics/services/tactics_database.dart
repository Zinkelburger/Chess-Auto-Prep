import 'dart:isolate';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import '../../../services/storage/storage_factory.dart';
import 'tactics_pgn_codec.dart';
import 'tactics_document.dart';
import 'package:chess_auto_prep/utils/log.dart';
import 'package:chess_auto_prep/utils/safe_change_notifier.dart';

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
class TacticsDatabase extends ChangeNotifier with SafeChangeNotifier {
  /// Name of the single set file backing the tactics database.
  static const String defaultSetName = 'Default';

  List<TacticsPosition> positions = [];
  Set<String> analyzedGameIds = {}; // Track which games have been analyzed
  ReviewSession currentSession = ReviewSession();
  int sessionPositionIndex = 0;
  Future<void> _pendingWrite = Future<void>.value();
  Future<void> _completedGameTail = Future<void>.value();

  /// Monotonic change counter, bumped with every notification. [positions]
  /// is mutated in place, so listeners that memoize something derived from
  /// it (the browse tab's filtered/sorted index list) can't use list
  /// identity as a dirty check — they compare this instead.
  int revision = 0;

  @override
  void notifyListeners() {
    revision++;
    super.notifyListeners();
  }

  /// Bumped on every [loadPositions] call.  The decode now runs off the UI
  /// isolate, so a set switch / import reload can start a second load while
  /// the first is still decoding; the load that owns the latest token clears
  /// and repopulates [positions], and any older in-flight load bails instead
  /// of appending its stale puzzles into the shared list.
  int _loadGeneration = 0;

  /// True while [loadPositions] is reading and decoding the set file, so the
  /// browse UI can show a loading state instead of "no tactics yet".
  bool isLoading = false;
  String? loadError;
  String? _persistedContent;
  bool _hasCheckpoint = false;

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
    final generation = ++_loadGeneration;
    // Flag synchronously (the first build after a load call must see it),
    // but notify only after the await: loadPositions is called from
    // initState, and a synchronous notify there lands mid-build.
    isLoading = true;
    await _completedGameTail;
    await _pendingWrite;
    if (generation != _loadGeneration) return positions.length;
    notifyListeners();

    try {
      final storage = StorageFactory.instance;
      await storage.migrateLegacyTacticsCsv(defaultSetName);
      await _migrateCsvSetsToPgn();
      await _migrateNamedSetsToStudies();

      final content = await storage.readFile(await activeSetFilePath());
      if (generation != _loadGeneration) return positions.length;
      _persistedContent = content;
      loadError = null;
      final document = readTacticsDocument(content ?? '');
      _hasCheckpoint = document.analyzed != null;
      final puzzleText = document.pgn;
      if (generation != _loadGeneration) return positions.length;

      if (content == null || content.trim().isEmpty) {
        // No set file yet — load analyzed games list (legacy or empty state).
        positions.clear();
        analyzedGameIds.clear();
        await _loadAnalyzedGameIds();
        if (generation != _loadGeneration) return positions.length;
        isLoading = false;
        notifyListeners();
        return 0;
      }

      // External files (studies) may hold chapters from the standard start;
      // our own set files always carry [FEN].
      // Decode replays every puzzle's moves with dartchess — off the UI
      // isolate so opening Tactics mode doesn't freeze the frame.
      final requireFen = !isExternalSet;
      final includeVariations = isExternalSet && _externalIncludeVariations;
      final onlyGame = isExternalSet ? _externalGameIndex : null;
      final decoded = await Isolate.run(
        () => decodePuzzlesFromPgn(
          puzzleText,
          requireFen: requireFen,
          includeVariations: includeVariations,
          onlyGame: onlyGame,
        ),
      );
      // A newer load (set switch, import reload) started while we decoded —
      // it now owns [positions]; drop this stale decode instead of appending
      // it onto the newer load's list.
      if (generation != _loadGeneration) return positions.length;

      // Clear + repopulate with no await in between, so an overlapping load
      // can never interleave its puzzles into the list.
      positions.clear();
      analyzedGameIds.clear();
      if (!isExternalSet && decoded.errors.isNotEmpty) {
        loadError =
            'Some tactics records could not be read. Saving and cleanup are disabled to preserve the original file: ${decoded.errors.join('; ')}';
      }
      for (final warning in decoded.errors) {
        log.w('Set "$_activeSetName": $warning');
      }
      for (final position in decoded.puzzles) {
        positions.add(position);
      }

      if (document.analyzed != null) {
        analyzedGameIds
          ..clear()
          ..addAll(document.analyzed!);
      }
      // Also load the separate analyzed games list (includes games with no blunders)
      await _loadAnalyzedGameIds();
      if (generation != _loadGeneration) return positions.length;

      log.i(
        'Loaded ${positions.length} tactics positions from set "$_activeSetName"',
      );
      log.i('Tracking ${analyzedGameIds.length} analyzed game IDs');
      isLoading = false;
      notifyListeners();
      return positions.length;
    } catch (e) {
      log.e('Error loading positions: $e');
      if (generation != _loadGeneration) return positions.length;
      loadError = 'Tactics could not be read. Saving is disabled: $e';
      positions.clear();
      analyzedGameIds.clear();
      isLoading = false;
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
        if (parsed.warnings.isNotEmpty) {
          throw StateError('Legacy tactics CSV needs repair before migration');
        }
        for (final warning in parsed.warnings) {
          log.w('CSV set "${legacy.name}": $warning');
        }
        final encoded = encodePuzzlesToPgn(legacy.name, parsed.positions);
        if (encoded.dropped != 0) {
          throw StateError('Refusing a lossy tactics migration');
        }
        await storage.writeFile(pgnPath, encoded.pgn, createOnly: true);
        await storage.renameFile(legacy.path, '${legacy.path}.bak');
        log.i(
          'Converted tactics set "${legacy.name}" from CSV to PGN (${parsed.positions.length} positions)',
        );
      } catch (e) {
        log.e('Error converting CSV set "${legacy.name}": $e');
        rethrow;
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
        while (await storage.fileExists(
          await storage.studyFilePath(targetName),
        )) {
          suffix++;
          targetName = '${set.name} (tactics${suffix > 2 ? ' $suffix' : ''})';
        }
        await storage.renameFile(
          set.filePath,
          await storage.studyFilePath(targetName),
        );
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
    await _completedGameTail;
    await _pendingWrite;
    _activeSetPath = path;
    _externalGameIndex = gameIndex;
    _externalIncludeVariations = includeVariations;
    _activeSetName =
        displayName ??
        path
            .split('/')
            .last
            .replaceAll(RegExp(r'\.pgn$', caseSensitive: false), '');
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
    await _completedGameTail;
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
    if (_hasCheckpoint || isExternalSet) return;
    try {
      final ids = await StorageFactory.instance.readAnalyzedGameIds();
      if (ids.isNotEmpty) {
        analyzedGameIds.addAll(ids);
        log.i('Loaded ${ids.length} analyzed game IDs from storage');
      }
    } catch (e) {
      log.e('Error loading analyzed game IDs: $e');
      rethrow;
    }
  }

  /// One durable commit for a completed game, including games with no puzzles.
  Future<void> commitAnalyzedGame(String gameId, List<TacticsPosition> found) =>
      _commitCompletedGames([gameId], List.of(found));

  Future<void> _commitCompletedGames(
    Iterable<String> ids,
    List<TacticsPosition> found,
  ) {
    final completed = ids.where((id) => id.isNotEmpty).toSet();
    final next = _completedGameTail.then((_) async {
      if (isExternalSet) {
        throw StateError('Cannot mine games into an external study.');
      }
      if (loadError != null) throw StateError(loadError!);
      final previousIds = Set<String>.of(analyzedGameIds);
      for (final position in found) {
        if (!positions.any((p) => p.fen == position.fen)) {
          positions.add(position);
        }
      }
      analyzedGameIds.addAll(completed);
      notifyListeners();
      try {
        await savePositions();
      } catch (_) {
        analyzedGameIds = previousIds;
        notifyListeners();
        rethrow;
      }
    });
    _completedGameTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> markGameAnalyzed(String gameId) =>
      commitAnalyzedGame(gameId, const []);

  Future<void> markGamesAnalyzed(Iterable<String> gameIds) =>
      _commitCompletedGames(gameIds, const []);

  /// Check if a game has already been analyzed
  bool isGameAnalyzed(String gameId) {
    return gameId.isNotEmpty && analyzedGameIds.contains(gameId);
  }

  /// Clear analyzed games tracking (for re-analysis)
  Future<void> clearAnalyzedGames() async {
    analyzedGameIds.clear();
    notifyListeners();
    await savePositions();
  }

  /// Parse tactics-CSV [content] (with header row) into positions.
  /// Bad rows are reported as warnings instead of failing the whole file.
  static ({List<TacticsPosition> positions, List<String> warnings}) parseCsv(
    String content,
  ) {
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
    final completed = Set<String>.of(analyzedGameIds);
    await _enqueueWrite(() async {
      try {
        if (loadError != null) throw StateError(loadError!);
        final storage = StorageFactory.instance;
        if (externalPath != null) {
          final existing = await storage.readFile(externalPath);
          if (existing == null) {
            throw StateError('External set file vanished: $externalPath');
          }
          if (existing != _persistedContent) {
            throw StateError(
              'The study changed on disk. Reload before saving review statistics.',
            );
          }
          final patched = await compute(_patchTacticsStats, (
            existing,
            snapshot,
          ));
          await storage.writeFile(
            externalPath,
            patched,
            expectedContent: existing,
          );
          _persistedContent = patched;
        } else {
          // Encoding replays every stored puzzle with dartchess (lineToSan),
          // so it is O(database) CPU — run it off the UI isolate.
          final encoded = await compute(_encodeTactics, (setName, snapshot));
          if (encoded.fallback > 0) {
            log.w(
              '${encoded.fallback} position(s) stored with raw [CorrectLine] fallback',
            );
          }
          if (encoded.dropped > 0) {
            throw StateError(
              '${encoded.dropped} invalid tactics records; refusing a lossy save.',
            );
          }
          final document = writeTacticsDocument(encoded.pgn, completed);
          await storage.writeFile(
            await storage.tacticsSetPath(setName),
            document,
            createOnly: _persistedContent == null,
            expectedContent: _persistedContent,
          );
          _persistedContent = document;
          _hasCheckpoint = true;
        }
        log.i('Saved ${snapshot.length} tactics positions to set "$setName"');
      } catch (e) {
        log.e('Error saving positions: $e');
        rethrow;
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

  /// Delete several positions in one mutation: one notify, one file write —
  /// batch delete from the browse list must not re-encode the whole set once
  /// per selected row.
  ///
  /// [indices] may arrive in any order and may repeat; they are deduplicated
  /// and applied highest-first here, so earlier removals cannot shift the
  /// ones still to come. That used to be the caller's contract, kept only by
  /// a doc comment on an operation whose own dialog says "cannot be undone" —
  /// an ascending or duplicated list silently deleted the wrong puzzles.
  Future<void> deletePositionsAt(List<int> indices) async {
    final ordered = indices.toSet().toList()..sort((a, b) => b.compareTo(a));
    var removed = 0;
    for (final index in ordered) {
      if (index < 0 || index >= positions.length) continue;
      positions.removeAt(index);
      removed++;
    }
    if (removed == 0) return;
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
  void startSession([
    TacticsSessionSettings settings = const TacticsSessionSettings(),
  ]) {
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
          (a, b) => positions[b].gameDate.compareTo(positions[a].gameDate),
        );
      case TacticsSessionOrder.leastReviewed:
        _sessionQueue.sort(
          (a, b) =>
              positions[a].reviewCount.compareTo(positions[b].reviewCount),
        );
      case TacticsSessionOrder.worstSuccessRate:
        _sessionQueue.sort(
          (a, b) =>
              positions[a].successRate.compareTo(positions[b].successRate),
        );
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

  /// Add a single position (streaming import, puzzle creator).  Returns
  /// `true` when the position was added (`false` = duplicate FEN).
  Future<bool> addPosition(TacticsPosition position) async {
    // Check for duplicates by FEN
    if (positions.any((p) => p.fen == position.fen)) return false;
    positions.add(position);
    notifyListeners();
    await savePositions();
    return true;
  }

  /// Add multiple positions incrementally (for streaming/live import)
  Future<void> addPositions(List<TacticsPosition> newPositions) async {
    int added = 0;
    for (final position in newPositions) {
      // Check for duplicates by FEN
      if (!positions.any((p) => p.fen == position.fen)) {
        positions.add(position);
        added++;
      }
    }
    if (added > 0) {
      notifyListeners();
      await savePositions();
      log.w(
        'Added $added new positions (${newPositions.length - added} duplicates skipped)',
      );
    }
  }

  String? lastWriteError;

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final next = _pendingWrite.then((_) => operation());
    _pendingWrite = next.then(
      (_) {
        if (lastWriteError != null) {
          lastWriteError = null;
          notifyListeners();
        }
      },
      onError: (Object e, StackTrace st) {
        lastWriteError = '$e';
        log.e(
          'Tactics database write failed',
          name: 'TacticsDatabase',
          error: e,
          stackTrace: st,
        );
        notifyListeners();
      },
    );
    return next;
  }
}

/// Result of attempting a tactical position
enum TacticsResult { correct, incorrect, hint, timeout }

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

({String pgn, int encoded, int fallback, int dropped}) _encodeTactics(
  (String, List<TacticsPosition>) input,
) => encodePuzzlesToPgn(input.$1, input.$2);

String _patchTacticsStats((String, List<TacticsPosition>) input) =>
    patchStatsInPgn(input.$1, input.$2);
