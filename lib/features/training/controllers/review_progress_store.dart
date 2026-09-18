/// The persisted side of training progress: spaced-repetition entries,
/// per-move streaks, and the review history trail.
///
/// Split out of [TrainingSessionController], which mixed "what does the user
/// see right now" (phase, queue, streak counters) with "what do we write to
/// disk when they answer". Everything here is about the latter — this class
/// holds no session state and never decides what to show next.
///
/// It deliberately does not notify: mutators return their result and the
/// owner decides when to rebuild the queue and repaint, because ordering
/// matters: commands publish only according to their acknowledged outcome.
library;

import 'dart:async';

import '../../../models/repertoire_line.dart';
import '../../../models/repertoire_move_progress.dart';
import '../../../models/repertoire_review_entry.dart'
    show RepertoireReviewEntry, ReviewRating;
import '../../../models/repertoire_review_history_entry.dart';
import '../models/training_settings.dart';
import '../repositories/training_review_repository.dart';

class ReviewProgressStore {
  ReviewProgressStore({
    required this.reviewService,
    required this.headers,
    required this._settings,
    required this._repertoireId,
    this.onError,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  void Function(Object)? onError;
  final TrainingReviewRepository reviewService;
  final TrainingHeaderRepository headers;

  /// Read through suppliers: the owner reassigns its settings object on a
  /// reload and its repertoire id on every source change.
  final TrainingSettings Function() _settings;
  final String Function() _repertoireId;

  TrainingSettings get settings => _settings();
  String get repertoireId => _repertoireId();

  /// Review entries for the loaded repertoire, keyed by line id.
  Map<String, RepertoireReviewEntry> byLine = {};

  /// Per-move streaks, keyed `"<lineId>:<moveIndex>"`.
  Map<String, RepertoireMoveProgress> moveProgress = {};

  /// Entries belonging to other repertoires, retained for caller inspection.
  /// Persistence merges only this repertoire into the latest stored rows.
  List<RepertoireReviewEntry> otherRepertoires = [];

  // ── Deferred PGN header writes ───────────────────────────────────────
  //
  // A line's schedule is also mirrored into its game's PGN headers, so
  // progress travels with the file. Doing that per rating meant reading a
  // multi-megabyte course, re-deriving every game's id to find one of them,
  // and writing the whole file back — a quarter-second stall between every
  // line, on the UI isolate. The reviews CSV is written immediately and is
  // the source of truth (headers only ever *seed* entries the CSV lacks), so
  // the mirror can be batched and lose nothing worse than a few seconds of
  // redundancy if the app dies mid-session.

  /// How long a header write waits for company before going to disk.
  static const headerFlushDelay = Duration(seconds: 4);

  Timer? _headerFlushTimer;
  final _pendingHeaders =
      <String, Map<String, ({RepertoireReviewEntry entry, Object owner})>>{};
  Future<void>? _headerFlush;
  bool _disposed = false;

  void _queueHeaderWrite(
    String sourcePath,
    String lineId,
    RepertoireReviewEntry entry,
    Object owner,
  ) {
    (_pendingHeaders[sourcePath] ??= {})[lineId] = (entry: entry, owner: owner);
    _headerFlushTimer?.cancel();
    if (_disposed) {
      unawaited(flushHeaders());
    } else {
      _headerFlushTimer = Timer(
        headerFlushDelay,
        () => unawaited(flushHeaders()),
      );
    }
  }

  /// Failed mirrors remain pending; the authoritative CSV outcome is preserved.
  Future<void> flushHeaders({Set<String>? sources}) {
    _headerFlushTimer?.cancel();
    _headerFlushTimer = null;
    final pending = _headerFlush;
    if (pending != null) {
      return sources == null
          ? pending
          : pending.then((_) => flushHeaders(sources: sources));
    }
    return _headerFlush = _flushHeaders(
      sources,
    ).whenComplete(() => _headerFlush = null);
  }

  Future<void> _flushHeaders(Set<String>? sources) async {
    while (true) {
      final path = _pendingHeaders.keys
          .where((path) => sources == null || sources.contains(path))
          .firstOrNull;
      if (path == null) return;
      final batch = Map.of(_pendingHeaders[path]!);
      final report = onError;
      try {
        if (path.isNotEmpty &&
            !await headers.updateManyLineReviewHeaders(path, {
              for (final entry in batch.entries) entry.key: entry.value.entry,
            })) {
          throw StateError('Training source could not be updated: $path');
        }
      } catch (e) {
        if (!_disposed &&
            batch.values.any((value) => identical(value.owner, byLine))) {
          report?.call(e);
        }
        return;
      }
      final pending = _pendingHeaders[path]!;
      pending.removeWhere(
        (key, value) =>
            identical(batch[key]?.entry, value.entry) &&
            identical(batch[key]?.owner, value.owner),
      );
      if (pending.isEmpty) _pendingHeaders.remove(path);
    }
  }

  void dispose() {
    _disposed = true;
    _headerFlushTimer?.cancel();
    _headerFlushTimer = null;
  }

  /// Install the state for a freshly loaded source.
  void adopt({
    required Map<String, RepertoireReviewEntry> byLine,
    required Map<String, RepertoireMoveProgress> moveProgress,
    required List<RepertoireReviewEntry> otherRepertoires,
  }) {
    // Whatever the previous source owed its own file, it owes now.
    unawaited(flushHeaders());
    this.byLine = byLine;
    _requiresReload = false;
    this.moveProgress = moveProgress;
    this.otherRepertoires = otherRepertoires;
  }

  // ── Rating a completed line ──────────────────────────────────────────

  /// Apply [rating] to [line], persist the new schedule, and append a history
  /// row. Returns the updated entry. Reuse [attempt] only to retry this result.
  ///
  /// [hadMistake] steers the pass/fail tallies, which are kept separately from
  /// the interval so "how well do I know this" survives a schedule reset.
  Future<RepertoireReviewEntry> recordRating(
    RepertoireLine line,
    ReviewRating rating, {
    required Object attempt,
    required bool hadMistake,
    String sessionType = 'trainer',
  }) async {
    _checkWritable();
    final sourcePath = line.sourcePath ?? repertoireId;
    final pending = _outcomes[(sourcePath, line.persistedId, attempt)];
    if (pending != null) {
      await _resumeOutcome(pending);
      return pending.updated;
    }
    final existing = byLine[line.id] ?? _freshEntry(line);
    final updated = reviewService
        .applyRating(existing, rating)
        .copyWith(
          passCount: hadMistake ? existing.passCount : existing.passCount + 1,
          failCount: hadMistake ? existing.failCount + 1 : existing.failCount,
        );
    byLine[line.id] = updated;

    await _persistLineOutcome(
      line,
      sourcePath: sourcePath,
      attempt: attempt,
      rating: rating.name,
      hadMistake: hadMistake,
      sessionType: sessionType,
    );

    return updated;
  }

  /// Record that [line] was completed without rating it.
  ///
  /// Linear mode has no spaced-repetition schedule, so the pass/fail tallies
  /// and the history row are updated but the interval and due date are left
  /// untouched — the line stays "new" as far as SRS is concerned.
  Future<void> recordCompletion(
    RepertoireLine line, {
    required Object attempt,
    required bool hadMistake,
    String sessionType = 'linear',
  }) async {
    _checkWritable();
    final sourcePath = line.sourcePath ?? repertoireId;
    final pending = _outcomes[(sourcePath, line.persistedId, attempt)];
    if (pending != null) {
      await _resumeOutcome(pending);
      return;
    }
    final existing = byLine[line.id] ?? _freshEntry(line);
    byLine[line.id] = existing.copyWith(
      passCount: hadMistake ? existing.passCount : existing.passCount + 1,
      failCount: hadMistake ? existing.failCount + 1 : existing.failCount,
    );

    await _persistLineOutcome(
      line,
      sourcePath: sourcePath,
      attempt: attempt,
      rating: '',
      hadMistake: hadMistake,
      sessionType: sessionType,
    );
  }

  /// Write the reviews and move streaks for [sourcePath], then append one
  /// history row for [line]. [rating] is empty for an unrated completion.
  Future<void> _persistLineOutcome(
    RepertoireLine line, {
    required String sourcePath,
    required Object attempt,
    required String rating,
    required bool hadMistake,
    required String sessionType,
  }) async {
    final outcome = _TrainingOutcome(
      key: (sourcePath, line.persistedId, attempt),
      sourcePath: sourcePath,
      updated: byLine[line.id]!,
      owner: byLine,
      reviews: byLine.values.toList(),
      moves: moveProgress.values.toList(),
      history: RepertoireReviewHistoryEntry(
        repertoireId: sourcePath,
        lineId: line.persistedId,
        timestampUtc: _now().toUtc(),
        rating: rating,
        hadMistake: hadMistake,
        sessionType: sessionType,
      ),
    );
    _outcomes[outcome.key] = outcome;
    await _resumeOutcome(outcome);
  }

  final Map<(String, String, Object), _TrainingOutcome> _outcomes = {};
  Future<void> _outcomeWrites = Future<void>.value();
  int _pendingWrites = 0;
  bool _editBusy = false;
  bool get editBusy => _editBusy;
  bool _requiresReload = false;
  bool get requiresReload => _requiresReload;
  bool get editsBlocked => editBusy || requiresReload || _disposed;

  void _checkWritable() {
    if (editsBlocked) {
      throw StateError('Training progress needs to settle or reload');
    }
  }

  void _admitEdit() {
    _checkWritable();
    if (_pendingWrites != 0 || _outcomes.isNotEmpty) {
      throw StateError('A training outcome is still unresolved');
    }
  }

  Future<T> _queueWrite<T>(Future<T> Function() action) {
    _pendingWrites++;
    final write = _outcomeWrites
        .then((_) => action())
        .whenComplete(() => _pendingWrites--);
    _outcomeWrites = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  // Non-resumable edits have one acknowledgement boundary. A partial failure
  // requires a durable read, never another attempt with the same selection.
  Future<T> _edit<T>(
    Map<String, RepertoireReviewEntry> owner,
    Future<T> Function() write,
  ) {
    _editBusy = true;
    return _queueWrite(() async {
      try {
        return await write();
      } catch (_) {
        if (identical(byLine, owner)) _requiresReload = true;
        rethrow;
      } finally {
        _editBusy = false;
      }
    });
  }

  // Capture before joining this queue: another session may already have
  // rebound the store by the time the preceding write finishes.
  /// End retry admission when the owning session is cancelled. Queued writes
  /// still hold their captured outcomes and finish independently of this map.
  void abandonOutcomeRetries() {
    if (_outcomes.values.any(
      (outcome) => outcome.inFlight == null && identical(outcome.owner, byLine),
    )) {
      _requiresReload = true;
    }
    _outcomes.clear();
  }

  /// Wait for admitted writes to settle before reading a source again.
  /// Settlement neither certifies success nor retries a failed write.
  Future<void> settleOutcomes() => _outcomeWrites;

  Future<void> _resumeOutcome(_TrainingOutcome outcome) {
    if (outcome.inFlight case final pending?) return pending;
    final write = _queueWrite(() async {
      try {
        await _writeOutcome(outcome);
      } catch (_) {
        if (!identical(_outcomes[outcome.key], outcome) &&
            identical(byLine, outcome.owner)) {
          _requiresReload = true;
        }
        rethrow;
      }
    });
    final tracked = write.whenComplete(() => outcome.inFlight = null);
    outcome.inFlight = tracked;
    return tracked;
  }

  Future<void> _writeOutcome(_TrainingOutcome outcome) async {
    if (!outcome.reviewsSaved) {
      await reviewService.saveAll(
        outcome.reviews,
        repertoireId: outcome.sourcePath,
      );
      outcome.reviewsSaved = true;
    }
    if (!outcome.movesSaved) {
      await reviewService.saveMoveProgress(
        outcome.moves,
        repertoireId: outcome.sourcePath,
      );
      outcome.movesSaved = true;
    }
    await reviewService.appendHistory([outcome.history]);
    if (outcome.history.rating.isNotEmpty) {
      _queueHeaderWrite(
        outcome.sourcePath,
        outcome.key.$2,
        outcome.updated,
        outcome.owner,
      );
    }
    if (identical(_outcomes[outcome.key], outcome)) {
      _outcomes.remove(outcome.key);
    }
  }

  Future<void> setExcluded(RepertoireLine line, bool excluded) async {
    _admitEdit();
    final sourcePath = line.sourcePath ?? repertoireId;
    final owner = byLine;
    final updated = (owner[line.id] ?? _freshEntry(line)).copyWith(
      excluded: excluded,
    );
    final proposed = {...owner, line.id: updated};
    await _edit(owner, () async {
      await reviewService.saveAll(
        proposed.values.toList(),
        repertoireId: sourcePath,
      );
      if (!_disposed && identical(byLine, owner)) owner[line.id] = updated;
    });
  }

  // ── Bulk "I already know these" ──────────────────────────────────────

  /// Capture the entire selected scope before joining the write queue. Nothing
  /// is published until every source's schedule, history and headers acknowledge.
  /// Failure can be partial on disk and requires reload before another edit.
  Future<int> applyLearnedSelection(
    List<RepertoireLine> lines,
    Set<String> checkedLineIds, {
    Set<String>? within,
  }) async {
    _admitEdit();
    final owner = byLine;
    final sourcePath = repertoireId;
    final proposed = Map.of(owner);
    final now = _now().toUtc();
    final batches =
        <
          ({
            String path,
            List<RepertoireReviewEntry> reviews,
            Map<String, RepertoireReviewEntry> headers,
            List<RepertoireReviewHistoryEntry> history,
          })
        >[];
    final sources = {for (final line in lines) line.sourcePath ?? sourcePath};
    for (final source in sources) {
      final history = <RepertoireReviewHistoryEntry>[];
      final updates = <String, RepertoireReviewEntry>{};
      int seeded = 0;
      for (final line in lines) {
        if ((line.sourcePath ?? sourcePath) != source ||
            (within != null && !within.contains(line.id))) {
          continue;
        }
        final entry = owner[line.id];
        final isLearned = entry != null && !entry.isNew;
        final wantLearned = checkedLineIds.contains(line.id);
        if (wantLearned == isLearned) continue;
        final RepertoireReviewEntry updated;
        if (wantLearned) {
          final existing = entry ?? _freshEntry(line);
          final interval = 1.0 + (seeded++ % 5) * 0.5;
          updated = existing.copyWith(
            intervalDays: interval,
            dueDateUtc: now.add(Duration(hours: (interval * 24).round())),
            lastRating: ReviewRating.good.name,
            lastReviewedUtc: now,
          );
        } else {
          updated = RepertoireReviewEntry(
            repertoireId: source,
            lineId: line.persistedId,
            lineName: line.name,
            difficulty: entry!.difficulty,
            passCount: entry.passCount,
            failCount: entry.failCount,
            excluded: entry.excluded,
          );
        }
        proposed[line.id] = updated;
        updates[line.persistedId] = updated;
        history.add(
          RepertoireReviewHistoryEntry(
            repertoireId: source,
            lineId: line.persistedId,
            timestampUtc: now,
            rating: wantLearned ? ReviewRating.good.name : '',
            hadMistake: false,
            sessionType: 'marked',
          ),
        );
      }
      if (updates.isNotEmpty) {
        batches.add((
          path: source,
          reviews: List.unmodifiable(
            proposed.values.where((entry) => entry.repertoireId == source),
          ),
          headers: Map.unmodifiable(updates),
          history: List.unmodifiable(history),
        ));
      }
    }
    if (batches.isEmpty) return 0;
    return _edit(owner, () async {
      // Never let an older retained mirror overwrite these newer schedules.
      final paths = batches.map((batch) => batch.path).toSet();
      await flushHeaders(sources: paths);
      if (_pendingHeaders.keys.any(paths.contains)) {
        throw StateError('Earlier PGN mirrors remain unconfirmed');
      }
      for (final batch in batches) {
        await reviewService.saveAll(batch.reviews, repertoireId: batch.path);
        await reviewService.appendHistory(batch.history);
        if (!await headers.updateManyLineReviewHeaders(
          batch.path,
          batch.headers,
        )) {
          throw StateError(
            'Training source could not be updated: ${batch.path}',
          );
        }
      }
      if (!_disposed && identical(byLine, owner)) {
        owner
          ..clear()
          ..addAll(proposed);
      }
      return batches.fold<int>(
        0,
        (count, batch) => count + batch.headers.length,
      );
    });
  }

  // ── Per-move streaks ─────────────────────────────────────────────────

  /// Record one answer for a single move. In-memory only; the streaks reach
  /// disk with the next [recordRating].
  void recordMove(
    RepertoireLine line,
    int moveIndex, {
    required bool wasCorrect,
  }) {
    _checkWritable();
    final key = _moveKey(line, moveIndex);
    final threshold = settings.correctStreakThreshold;

    if (!wasCorrect) {
      moveProgress[key] = RepertoireMoveProgress(
        repertoireId: line.sourcePath ?? repertoireId,
        lineId: line.persistedId,
        moveIndex: moveIndex,
        correctStreak: 0,
        learned: false,
      );
      return;
    }

    final newStreak = (moveProgress[key]?.correctStreak ?? 0) + 1;
    final learned = newStreak >= threshold;
    moveProgress[key] = RepertoireMoveProgress(
      repertoireId: line.sourcePath ?? repertoireId,
      lineId: line.persistedId,
      moveIndex: moveIndex,
      // Cap at the threshold so a long streak doesn't inflate difficulty
      // past 1.0 once the move counts as learned.
      correctStreak: learned ? threshold : newStreak,
      learned: learned,
    );
  }

  /// How well a single move is known, 0 (untouched) to 1 (learned).
  double moveDifficulty(RepertoireLine line, int moveIndex) {
    final progress = moveProgress[_moveKey(line, moveIndex)];
    if (progress == null) return 0;
    return progress.correctStreak / settings.correctStreakThreshold;
  }

  String _moveKey(RepertoireLine line, int moveIndex) =>
      '${line.id}:$moveIndex';

  RepertoireReviewEntry _freshEntry(RepertoireLine line) =>
      RepertoireReviewEntry(
        repertoireId: line.sourcePath ?? repertoireId,
        lineId: line.persistedId,
        lineName: line.name,
      );
}

/// A retry resumes only failed persistence stages, without applying SM-2 twice.
class _TrainingOutcome {
  _TrainingOutcome({
    required this.key,
    required this.sourcePath,
    required this.updated,
    required this.owner,
    required this.reviews,
    required this.moves,
    required this.history,
  });
  final (String, String, Object) key;
  final String sourcePath;
  final Object owner;
  final RepertoireReviewEntry updated;
  final List<RepertoireReviewEntry> reviews;
  final List<RepertoireMoveProgress> moves;
  final RepertoireReviewHistoryEntry history;
  Future<void>? inFlight;
  bool reviewsSaved = false;
  bool movesSaved = false;
}
