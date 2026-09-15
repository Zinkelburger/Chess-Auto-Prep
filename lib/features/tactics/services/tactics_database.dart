import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/storage_factory.dart';
import '../../../utils/log.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/tactics_position.dart';
import '../models/tactics_session_settings.dart';
import 'tactics_document.dart';
import 'tactics_pgn_codec.dart';
import 'tactics_session_queue.dart';
import 'tactics_set_migrations.dart';

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

  /// Games whose puzzles have been mined, so they are never analyzed twice.
  Set<String> analyzedGameIds = {};
  ReviewSession currentSession = ReviewSession();
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

  /// Why the set could not be read, when it could not; saving is disabled
  /// while set so a partial decode can never overwrite the original file.
  String? loadError;

  /// Why the last queued write failed, cleared by the next successful one.
  String? lastWriteError;

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

  final _sessionQueue = TacticsSessionQueue();

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
      await _runMigrations();

      final content = await StorageFactory.instance.readFile(
        await activeSetFilePath(),
      );
      if (generation != _loadGeneration) return positions.length;
      _persistedContent = content;
      loadError = null;
      final document = readTacticsDocument(content ?? '');
      _hasCheckpoint = document.analyzed != null;

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

      final decoded = await _decodeOffIsolate(document.pgn);
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
            'Some tactics records could not be read. Saving and cleanup are '
            'disabled to preserve the original file: '
            '${decoded.errors.join('; ')}';
      }
      for (final warning in decoded.errors) {
        log.w('Set "$_activeSetName": $warning');
      }
      positions.addAll(decoded.puzzles);

      final checkpoint = document.analyzed;
      if (checkpoint != null) analyzedGameIds.addAll(checkpoint);
      // Also load the separate analyzed games list (includes games with no
      // blunders).
      await _loadAnalyzedGameIds();
      if (generation != _loadGeneration) return positions.length;

      log.i(
        'Loaded ${positions.length} tactics positions from set '
        '"$_activeSetName"',
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

  Future<void> _runMigrations() async {
    final storage = StorageFactory.instance;
    await storage.migrateLegacyTacticsCsv(defaultSetName);
    final migrations = TacticsSetMigrations(
      storage,
      defaultSetName: defaultSetName,
    );
    await migrations.convertCsvSetsToPgn();
    if (!_setsMigrated) {
      _setsMigrated = true;
      await migrations.moveNamedSetsToStudies();
    }
  }

  /// Decode [puzzleText] off the UI isolate: decoding replays every puzzle's
  /// moves with dartchess, so opening Tactics mode must not freeze the frame.
  ///
  /// External files (studies) may hold chapters from the standard start; our
  /// own set files always carry `[FEN]`.
  Future<({List<TacticsPosition> puzzles, List<String> errors})>
  _decodeOffIsolate(String puzzleText) {
    final requireFen = !isExternalSet;
    final includeVariations = isExternalSet && _externalIncludeVariations;
    final onlyGame = isExternalSet ? _externalGameIndex : null;
    return Isolate.run(
      () => decodePuzzlesFromPgn(
        puzzleText,
        requireFen: requireFen,
        includeVariations: includeVariations,
        onlyGame: onlyGame,
      ),
    );
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
    _activeSetName = displayName ?? _setNameForFile(path);
    _resetSession();
    return loadPositions();
  }

  /// The file's name without a `.pgn` extension (any other extension stays).
  static String _setNameForFile(String path) =>
      p.extension(path).toLowerCase() == '.pgn'
      ? p.basenameWithoutExtension(path)
      : p.basename(path);

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
    _resetSession();
    await loadPositions();
  }

  void _resetSession() {
    _sessionQueue.clear();
    currentSession = ReviewSession();
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

  /// One durable commit for a completed game, including games with no
  /// puzzles: the puzzles join [positions] (duplicate FENs skipped), the game
  /// joins [analyzedGameIds], and both are written in one save. A failed
  /// save rolls the analyzed mark back so the game is looked at again.
  ///
  /// Commits are serialized in call order, and the whole chain waits for
  /// [loadPositions] to finish before it reads the list.
  Future<void> commitAnalyzedGame(String gameId, List<TacticsPosition> found) {
    final puzzles = List.of(found);
    final next = _completedGameTail.then((_) async {
      if (isExternalSet) {
        throw StateError('Cannot mine games into an external study.');
      }
      final loadError = this.loadError;
      if (loadError != null) throw StateError(loadError);
      final previousIds = Set<String>.of(analyzedGameIds);
      for (final position in puzzles) {
        if (!positions.any((p) => p.fen == position.fen)) {
          positions.add(position);
        }
      }
      if (gameId.isNotEmpty) analyzedGameIds.add(gameId);
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
        final loadError = this.loadError;
        if (loadError != null) throw StateError(loadError);
        if (externalPath != null) {
          await _patchExternalSet(externalPath, snapshot);
        } else {
          await _rewriteSet(setName, snapshot, completed);
        }
        log.i('Saved ${snapshot.length} tactics positions to set "$setName"');
      } catch (e) {
        log.e('Error saving positions: $e');
        rethrow;
      }
    });
  }

  Future<void> _patchExternalSet(
    String externalPath,
    List<TacticsPosition> snapshot,
  ) async {
    final storage = StorageFactory.instance;
    final existing = await storage.readFile(externalPath);
    if (existing == null) {
      throw StateError('External set file vanished: $externalPath');
    }
    if (existing != _persistedContent) {
      throw StateError(
        'The study changed on disk. Reload before saving review statistics.',
      );
    }
    final patched = await compute(_patchTacticsStats, (existing, snapshot));
    await storage.writeFile(externalPath, patched, expectedContent: existing);
    _persistedContent = patched;
  }

  Future<void> _rewriteSet(
    String setName,
    List<TacticsPosition> snapshot,
    Set<String> completed,
  ) async {
    final storage = StorageFactory.instance;
    // Encoding replays every stored puzzle with dartchess (lineToSan), so it
    // is O(database) CPU — run it off the UI isolate.
    final encoded = await compute(_encodeTactics, (setName, snapshot));
    if (encoded.fallback > 0) {
      log.w(
        '${encoded.fallback} position(s) stored with raw [CorrectLine] '
        'fallback',
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
  /// ones still to come.
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

  // ── Session queue ──────────────────────────────────────────────────────

  /// Start a new review session with the given [settings].
  void startSession([
    TacticsSessionSettings settings = const TacticsSessionSettings(),
  ]) {
    currentSession = ReviewSession();
    _sessionSettings = settings;
    _sessionQueue.start(positions, settings);
  }

  /// Start a session over exactly [subset], in the given order — e.g.
  /// "Retry mistakes" from the session recap.  Positions are matched by FEN
  /// against the loaded database; unknown FENs are skipped.
  void startSessionWithPositions(List<TacticsPosition> subset) {
    currentSession = ReviewSession();
    _sessionQueue.startWith(positions, subset);
  }

  /// Index into [positions] of the puzzle the session sits on.
  int get sessionPositionIndex => _sessionQueue.currentPositionIndex;

  /// Number of positions in the current session queue.
  int get sessionQueueLength => _sessionQueue.length;

  /// Current 0-based position within the session queue.
  int get sessionQueuePosition => _sessionQueue.cursor;

  /// True while the user has navigated back below the session head — i.e.
  /// the shown puzzle was already completed or skipped this session.
  bool get isViewingPastSessionPuzzle => _sessionQueue.isViewingPast;

  /// Remove a position (by index into [positions]) from the live session queue.
  void removeFromSessionQueue(int positionIndex) =>
      _sessionQueue.remove(positionIndex);

  /// Advance to the next position in the session queue.  Returns the index
  /// into [positions], or `null` when the last position has been reached —
  /// the session is over (no wrap-around).
  int? nextSessionPosition() => _sessionQueue.next();

  /// Go to the previous position in the session queue, stopping at the first
  /// position (no wrap-around).
  int? previousSessionPosition() => _sessionQueue.previous();

  // ── Review stats ───────────────────────────────────────────────────────

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
    final index = positions.indexWhere((p) => p.fen == position.fen);
    if (index == -1) return;

    // Update only the stats that changed — copyWith preserves everything else.
    positions[index] = position.copyWith(
      reviewCount: position.reviewCount + 1,
      successCount:
          position.successCount + (result == TacticsResult.correct ? 1 : 0),
      lastReviewed: DateTime.now(),
      timeToSolve: timeTaken,
      hintsUsed: position.hintsUsed + hintsUsed,
    );
    currentSession.record(result, timeTaken);
    notifyListeners();
    await savePositions();
  }

  /// Add a single position (streaming import, puzzle creator).  Returns
  /// `true` when the position was added (`false` = duplicate FEN).
  Future<bool> addPosition(TacticsPosition position) async {
    if (positions.any((p) => p.fen == position.fen)) return false;
    positions.add(position);
    notifyListeners();
    await savePositions();
    return true;
  }

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

  /// Count one attempt with its outcome.
  void record(TacticsResult result, double timeTaken) {
    positionsAttempted++;
    totalTime += timeTaken;
    switch (result) {
      case TacticsResult.correct:
        positionsCorrect++;
      case TacticsResult.incorrect:
        positionsIncorrect++;
      case TacticsResult.hint:
        hintsUsed++;
      case TacticsResult.timeout:
        break;
    }
  }
}

({String pgn, int encoded, int fallback, int dropped}) _encodeTactics(
  (String, List<TacticsPosition>) input,
) => encodePuzzlesToPgn(input.$1, input.$2);

String _patchTacticsStats((String, List<TacticsPosition>) input) =>
    patchStatsInPgn(input.$1, input.$2);
