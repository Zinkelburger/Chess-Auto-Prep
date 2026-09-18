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
/// matters (repaint before the disk write, not after).
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
  final void Function(Object)? onError;
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
  final Map<String, Map<String, RepertoireReviewEntry>> _pendingHeaders = {};
  Future<void>? _headerFlush;
  bool _disposed = false;

  void _queueHeaderWrite(
    String sourcePath,
    String lineId,
    RepertoireReviewEntry entry,
  ) {
    (_pendingHeaders[sourcePath] ??= {})[lineId] = entry;
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
  Future<void> flushHeaders() {
    _headerFlushTimer?.cancel();
    _headerFlushTimer = null;
    return _headerFlush ??= _flushHeaders().whenComplete(
      () => _headerFlush = null,
    );
  }

  Future<void> _flushHeaders() async {
    while (_pendingHeaders.isNotEmpty) {
      final path = _pendingHeaders.keys.first;
      final batch = Map<String, RepertoireReviewEntry>.of(
        _pendingHeaders[path]!,
      );
      try {
        if (path.isNotEmpty &&
            !await headers.updateManyLineReviewHeaders(path, batch)) {
          throw StateError('Training source could not be updated: $path');
        }
      } catch (e) {
        onError?.call(e);
        return;
      }
      final pending = _pendingHeaders[path]!;
      pending.removeWhere((key, value) => identical(batch[key], value));
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
    final sourcePath = line.sourcePath ?? repertoireId;
    final pending = _outcomes[(sourcePath, line.persistedId, attempt)];
    if (pending != null) {
      await _resumeOutcome(pending);
      _queueHeaderWrite(sourcePath, line.persistedId, pending.updated);
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
    _queueHeaderWrite(sourcePath, line.persistedId, updated);

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

  // Capture before joining this queue: another session may already have
  // rebound the store by the time the preceding write finishes.
  /// End retry admission when the owning session is cancelled. Queued writes
  /// still hold their captured outcomes and finish independently of this map.
  void abandonOutcomeRetries() => _outcomes.clear();

  /// Wait for admitted writes to settle before reading a source again.
  /// Settlement neither certifies success nor retries a failed write.
  Future<void> settleOutcomes() => _outcomeWrites;

  Future<void> _resumeOutcome(_TrainingOutcome outcome) {
    if (outcome.inFlight case final pending?) return pending;
    final write = _outcomeWrites.then((_) => _writeOutcome(outcome));
    final tracked = write.whenComplete(() => outcome.inFlight = null);
    outcome.inFlight = tracked;
    _outcomeWrites = tracked.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
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
    if (identical(_outcomes[outcome.key], outcome)) {
      _outcomes.remove(outcome.key);
    }
  }

  Future<void> setExcluded(RepertoireLine line, bool excluded) async {
    final sourcePath = line.sourcePath ?? repertoireId;
    final entry = byLine[line.id] ?? _freshEntry(line);
    byLine[line.id] = entry.copyWith(excluded: excluded);
    await reviewService.saveAll(
      byLine.values.toList(),
      repertoireId: sourcePath,
    );
  }

  // ── Bulk "I already know these" ──────────────────────────────────────

  /// Bulk-set which lines count as learned without training them — for lines
  /// the user already knows from elsewhere (another tool, over-the-board
  /// experience). Lines in [checkedLineIds] that are new get seeded as
  /// learned; learned lines left unchecked are reset to new. Returns how many
  /// lines changed state.
  ///
  /// [within] limits the pass to those line ids (the lines the user could
  /// actually see): with a chapter filter active, learned lines outside the
  /// chapter must not be reset just because they weren't on screen.
  ///
  /// [onApplied] runs once the in-memory state is updated but before anything
  /// is written, so the owner can repaint without waiting on disk.
  Future<int> applyLearnedSelection(
    List<RepertoireLine> lines,
    Set<String> checkedLineIds, {
    Set<String>? within,
    void Function()? onApplied,
  }) async {
    final sources = {for (final line in lines) line.sourcePath ?? repertoireId};
    if (sources.length > 1 ||
        (sources.isNotEmpty && sources.single != repertoireId)) {
      var changed = 0;
      for (final source in sources) {
        changed += await _applyLearnedSelectionForSource(
          lines
              .where((line) => (line.sourcePath ?? repertoireId) == source)
              .toList(),
          checkedLineIds,
          sourcePath: source,
          within: within,
          onApplied: onApplied,
        );
      }
      return changed;
    }
    return _applyLearnedSelectionForSource(
      lines,
      checkedLineIds,
      sourcePath: repertoireId,
      within: within,
      onApplied: onApplied,
    );
  }

  Future<int> _applyLearnedSelectionForSource(
    List<RepertoireLine> lines,
    Set<String> checkedLineIds, {
    required String sourcePath,
    Set<String>? within,
    void Function()? onApplied,
  }) async {
    final now = _now().toUtc();
    final history = <RepertoireReviewHistoryEntry>[];
    final headerUpdates = <String, RepertoireReviewEntry>{};
    int seeded = 0;

    for (final line in lines) {
      if (within != null && !within.contains(line.id)) continue;
      final entry = byLine[line.id];
      final isLearned = entry != null && !entry.isNew;
      final wantLearned = checkedLineIds.contains(line.id);
      if (wantLearned == isLearned) continue;

      final RepertoireReviewEntry updated;
      if (wantLearned) {
        final existing = entry ?? _freshEntry(line);
        // Stagger seeded intervals (1–3 days) so a big bulk import doesn't
        // dump every line into the same future review day.
        final interval = 1.0 + (seeded++ % 5) * 0.5;
        updated = existing.copyWith(
          intervalDays: interval,
          dueDateUtc: now.add(Duration(hours: (interval * 24).round())),
          lastRating: ReviewRating.good.name,
          lastReviewedUtc: now,
        );
      } else {
        // Back to new: scheduling cleared, pass/fail history kept. A fresh
        // entry rather than copyWith because copyWith can't null the dates.
        updated = RepertoireReviewEntry(
          repertoireId: sourcePath,
          lineId: line.persistedId,
          lineName: line.name,
          difficulty: entry!.difficulty,
          passCount: entry.passCount,
          failCount: entry.failCount,
          excluded: entry.excluded,
        );
      }
      byLine[line.id] = updated;
      headerUpdates[line.persistedId] = updated;
      history.add(
        RepertoireReviewHistoryEntry(
          repertoireId: sourcePath,
          lineId: line.persistedId,
          timestampUtc: now,
          rating: wantLearned ? ReviewRating.good.name : '',
          hadMistake: false,
          sessionType: 'marked',
        ),
      );
    }

    if (headerUpdates.isEmpty) return 0;

    onApplied?.call();

    final savedReviews = byLine.values.toList();
    await reviewService.saveAll(savedReviews, repertoireId: sourcePath);
    await reviewService.appendHistory(history);
    // Fold in anything still waiting so the two writes cannot race for the
    // same file, then write once.
    await flushHeaders();
    await headers.updateManyLineReviewHeaders(sourcePath, headerUpdates);
    return headerUpdates.length;
  }

  // ── Per-move streaks ─────────────────────────────────────────────────

  /// Record one answer for a single move. In-memory only; the streaks reach
  /// disk with the next [recordRating].
  void recordMove(
    RepertoireLine line,
    int moveIndex, {
    required bool wasCorrect,
  }) {
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
    required this.reviews,
    required this.moves,
    required this.history,
  });
  final (String, String, Object) key;
  final String sourcePath;
  final RepertoireReviewEntry updated;
  final List<RepertoireReviewEntry> reviews;
  final List<RepertoireMoveProgress> moves;
  final RepertoireReviewHistoryEntry history;
  Future<void>? inFlight;
  bool reviewsSaved = false;
  bool movesSaved = false;
}
