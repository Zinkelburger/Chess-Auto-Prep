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

import '../../models/repertoire_line.dart';
import '../../models/repertoire_move_progress.dart';
import '../../models/repertoire_review_entry.dart'
    show RepertoireReviewEntry, ReviewRating;
import '../../models/repertoire_review_history_entry.dart';
import '../../models/training_settings.dart';
import '../repertoire_review_service.dart';
import '../repertoire_service.dart';

class ReviewProgressStore {
  ReviewProgressStore({
    required this.reviewService,
    required this.repertoireService,
    required this._settings,
    required this._repertoireId,
  });

  final RepertoireReviewService reviewService;
  final RepertoireService repertoireService;

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

  /// Entries belonging to *other* repertoires. Held because the review file is
  /// written whole: dropping these would wipe every other repertoire's
  /// schedule on the next save.
  List<RepertoireReviewEntry> otherRepertoires = [];

  /// Install the state for a freshly loaded source.
  void adopt({
    required Map<String, RepertoireReviewEntry> byLine,
    required Map<String, RepertoireMoveProgress> moveProgress,
    required List<RepertoireReviewEntry> otherRepertoires,
  }) {
    this.byLine = byLine;
    this.moveProgress = moveProgress;
    this.otherRepertoires = otherRepertoires;
  }

  /// Every entry that must be written when saving, this repertoire's and all
  /// the others'.
  List<RepertoireReviewEntry> get _allEntries => [
    ...otherRepertoires,
    ...byLine.values,
  ];

  // ── Rating a completed line ──────────────────────────────────────────

  /// Apply [rating] to [line], persist the new schedule, and append a history
  /// row. Returns the updated entry.
  ///
  /// [hadMistake] steers the pass/fail tallies, which are kept separately from
  /// the interval so "how well do I know this" survives a schedule reset.
  Future<RepertoireReviewEntry> recordRating(
    RepertoireLine line,
    ReviewRating rating, {
    required bool hadMistake,
    String sessionType = 'trainer',
  }) async {
    final existing = byLine[line.id] ?? _freshEntry(line);
    final updated = reviewService
        .applyRating(existing, rating)
        .copyWith(
          passCount: hadMistake ? existing.passCount : existing.passCount + 1,
          failCount: hadMistake ? existing.failCount + 1 : existing.failCount,
        );
    byLine[line.id] = updated;

    await reviewService.saveAll(_allEntries);
    await reviewService.saveMoveProgress(
      moveProgress.values.toList(),
      repertoireId: repertoireId,
    );
    await reviewService.appendHistory([
      RepertoireReviewHistoryEntry(
        repertoireId: repertoireId,
        lineId: line.id,
        timestampUtc: DateTime.now().toUtc(),
        rating: rating.name,
        hadMistake: hadMistake,
        sessionType: sessionType,
      ),
    ]);

    await repertoireService.updateLineReviewHeaders(
      repertoireId,
      line.id,
      lastReview: updated.lastReviewedUtc,
      difficulty: updated.difficulty,
      intervalDays: updated.intervalDays,
      dueDate: updated.dueDateUtc,
      passCount: updated.passCount,
      failCount: updated.failCount,
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
    required bool hadMistake,
    String sessionType = 'linear',
  }) async {
    final existing = byLine[line.id] ?? _freshEntry(line);
    byLine[line.id] = existing.copyWith(
      passCount: hadMistake ? existing.passCount : existing.passCount + 1,
      failCount: hadMistake ? existing.failCount + 1 : existing.failCount,
    );

    await reviewService.saveAll(_allEntries);
    await reviewService.saveMoveProgress(
      moveProgress.values.toList(),
      repertoireId: repertoireId,
    );
    await reviewService.appendHistory([
      RepertoireReviewHistoryEntry(
        repertoireId: repertoireId,
        lineId: line.id,
        timestampUtc: DateTime.now().toUtc(),
        rating: '',
        hadMistake: hadMistake,
        sessionType: sessionType,
      ),
    ]);
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
    final now = DateTime.now().toUtc();
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
          repertoireId: repertoireId,
          lineId: line.id,
          lineName: line.name,
          difficulty: entry!.difficulty,
          passCount: entry.passCount,
          failCount: entry.failCount,
        );
      }
      byLine[line.id] = updated;
      headerUpdates[line.id] = updated;
      history.add(
        RepertoireReviewHistoryEntry(
          repertoireId: repertoireId,
          lineId: line.id,
          timestampUtc: now,
          rating: wantLearned ? ReviewRating.good.name : '',
          hadMistake: false,
          sessionType: 'marked',
        ),
      );
    }

    if (headerUpdates.isEmpty) return 0;

    onApplied?.call();

    await reviewService.saveAll(_allEntries);
    await reviewService.appendHistory(history);
    await repertoireService.updateManyLineReviewHeaders(
      repertoireId,
      headerUpdates,
    );
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
        repertoireId: repertoireId,
        lineId: line.id,
        moveIndex: moveIndex,
        correctStreak: 0,
        learned: false,
      );
      return;
    }

    final newStreak = (moveProgress[key]?.correctStreak ?? 0) + 1;
    final learned = newStreak >= threshold;
    moveProgress[key] = RepertoireMoveProgress(
      repertoireId: repertoireId,
      lineId: line.id,
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
        repertoireId: repertoireId,
        lineId: line.id,
        lineName: line.name,
      );
}
