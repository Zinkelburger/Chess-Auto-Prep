import '../features/training/models/training_history_operation.dart';
import '../features/training/models/training_source_context.dart';
import '../infrastructure/training/training_source_admission.dart';
import 'dart:math';
import '../features/training/repositories/training_review_repository.dart';

import '../models/repertoire_line.dart';
import '../models/repertoire_move_progress.dart';
import '../models/repertoire_review_entry.dart';
import '../models/repertoire_review_history_entry.dart';
import '../features/training/models/training_settings.dart';
import '../utils/training_csv.dart';
import 'storage/storage_factory.dart';
import 'storage/storage_service.dart';
import '../infrastructure/training/move_attempt_store.dart';

/// Spaced-repetition scheduling for repertoire lines, and the CSV files
/// that keep line ratings, review history and per-move progress.
///
/// Saves are optimistic: the rows seen at the last load are remembered, and
/// a save that would overwrite a row another session changed since throws
/// instead of clobbering it.
class RepertoireReviewService implements TrainingReviewRepository {
  static const _header =
      'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded';
  static const _historyHeader =
      'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type';
  static const _moveProgressHeader =
      'repertoire_id,line_id,move_index,correct_streak,learned';

  static const _reviewsFile = 'repertoire_reviews.csv';
  static const _historyFile = 'repertoire_review_history.csv';
  static const _progressFile = 'repertoire_move_progress.csv';

  /// Smallest and largest ease a line can reach. [RepertoireReviewEntry.
  /// difficulty] *is* the ease factor — "higher = easier" — and SM-2 keeps it
  /// off the floor so a line you keep failing still eventually stretches out.
  static const double minEase = 1.3;
  static const double maxEase = 3.0;

  /// The ease a line starts with when its PGN headers carry none.
  static const double defaultEase = 2.5;

  /// How much one Again / Hard / Easy answer moves the ease.
  static const double _againEasePenalty = 0.20;
  static const double _hardEasePenalty = 0.15;
  static const double _easyEaseBonus = 0.15;

  /// An opening line is not worth a five-year interval; past a year you have
  /// either played it or forgotten it, and a cap keeps the schedule honest.
  static const double maxIntervalDays = 365;

  /// "Again" puts the line back in the queue you are working through right
  /// now, the way Anki's first learning step does.
  ///
  /// Zero, not "in an hour": the due-queue filter only keeps lines that are
  /// actually due, so any positive interval dropped a just-failed line out of
  /// the session — the one line you most need to see again was the one the
  /// run refused to show you.
  static const double againIntervalDays = 0;

  final StorageService _storage;

  /// Spread applied to a scheduled interval, Anki-style, so a course learned
  /// in one weekend does not come back as one 900-line day. Injectable so
  /// tests can pin it.
  final Random _fuzz;
  final DateTime Function() _now;

  /// Rows as of the last [loadAll] / [loadMoveProgress], keyed like the
  /// merge, so a save can tell its own edits from another session's.
  final Map<String, String> _loadedReviewRows = {};
  final Map<String, String> _loadedProgressRows = {};

  /// [storage] is injectable only so tests can hold the review CSVs in
  /// memory instead of writing to the user's real `~/Documents`; every
  /// caller outside a test passes nothing.
  RepertoireReviewService({
    Random? fuzz,
    StorageService? storage,
    DateTime Function()? now,
    this.validateSource = validateTrainingSource,
  }) : _now = now ?? DateTime.now,
       _fuzz = fuzz ?? Random(),
       _storage = storage ?? StorageFactory.instance;

  final Future<void> Function(TrainingSourceContext, String) validateSource;

  /// Administrative identity migration, separate from session-authorized saves.
  /// Each transform reads the latest rows inside storage's recovery guard.
  Future<void> repointLines({
    required String from,
    required Map<String, String> movedLinePaths,
  }) async {
    for (final table in [
      (_reviewsFile, _header, 11),
      (_progressFile, _moveProgressHeader, 5),
    ]) {
      if (await _storage.readFile(table.$1) == null) continue;
      await _preserveBeforeMigration(table.$1);
      await _storage.updateFile(table.$1, (raw) {
        var changed = false;
        final rows = <String>[];
        for (final row in trainingRows(raw)) {
          final cells = decodeTrainingRow(row, table.$3);
          final target = cells[0] == from ? movedLinePaths[cells[1]] : null;
          if (target != null) {
            cells[0] = target;
            changed = true;
          }
          rows.add(encodeTrainingRow(cells));
        }
        return changed ? '${table.$2}\n${rows.join('\n')}\n' : raw ?? '';
      });
    }
    await repointAttempts(from: from, movedLinePaths: movedLinePaths);
  }

  static String _reviewKey(RepertoireReviewEntry e) =>
      '${e.repertoireId.length}:${e.repertoireId}${e.lineId}';
  static String _progressKey(RepertoireMoveProgress e) =>
      '${e.repertoireId.length}:${e.repertoireId}${e.lineId}:${e.moveIndex}';

  // ── Move attempts ─────────────────────────────────────────────────────

  /// Append each answer immediately, independently of line ratings. A later
  /// correct replay must never erase what the user originally played.
  @override
  Future<void> recordAttempt({
    required String repertoireId,
    required TrainingSourceContext source,
    required String lineId,
    required int moveIndex,
    required String fen,
    required String playedSan,
    required String expectedSan,
    required bool correct,
    required String phase,
  }) => MoveAttemptStore(_storage, validateSource: validateSource).record(
    repertoireId: repertoireId,
    source: source,
    lineId: lineId,
    moveIndex: moveIndex,
    fen: fen,
    playedSan: playedSan,
    expectedSan: expectedSan,
    correct: correct,
    phase: phase,
  );

  @override
  Future<List<Map<String, dynamic>>> loadAttempts({String? repertoireId}) =>
      MoveAttemptStore(_storage).load(repertoireId: repertoireId);

  Future<void> repointAttempts({
    required String from,
    required Map<String, String> movedLinePaths,
  }) => MoveAttemptStore(
    _storage,
  ).repoint(from: from, movedLinePaths: movedLinePaths);

  // ── Line ratings ──────────────────────────────────────────────────────

  @override
  Future<List<RepertoireReviewEntry>> loadAll() async {
    final entries = trainingRows(
      await _storage.readRepertoireReviewsCsv(),
    ).map(RepertoireReviewEntry.fromCsvRow).toList();
    _loadedReviewRows
      ..clear()
      ..addEntries([
        for (final e in entries) MapEntry(_reviewKey(e), e.toCsvRow()),
      ]);
    return entries;
  }

  /// Merge the captured source's entries into the latest stored rows.
  /// Other source entries may be present in a folder snapshot and are ignored.
  /// Rows loaded for this source but absent from [entries] are removed.
  @override
  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    String? repertoireId,
    required TrainingSourceContext source,
  }) => source.run(() async {
    await _preserveBeforeMigration(_reviewsFile);
    final snapshot = {
      for (final e in entries)
        if (e.repertoireId == (repertoireId ?? source.path))
          _reviewKey(e): e.toCsvRow(),
    };
    bool inScope(String row) =>
        RepertoireReviewEntry.fromCsvRow(row).repertoireId ==
        (repertoireId ?? source.path);

    await _storage.updateFile(_reviewsFile, (raw) async {
      await validateSource(source, repertoireId ?? source.path);
      return _mergeRows(
        header: _header,
        current: {
          for (final e in trainingRows(
            raw,
          ).map(RepertoireReviewEntry.fromCsvRow))
            _reviewKey(e): e.toCsvRow(),
        },
        snapshot: snapshot,
        expected: _loadedReviewRows,
        inScope: inScope,
        conflict:
            'Training progress changed in another session. '
            'Reload before saving.',
        removalConflict:
            'Training progress changed before removal. '
            'Reload before saving.',
      );
    });
    _rememberSaved(_loadedReviewRows, snapshot, inScope);
  });

  // ── Review history ────────────────────────────────────────────────────

  @override
  Future<List<RepertoireReviewHistoryEntry>> loadHistory() async =>
      trainingRows(
        await _storage.readRepertoireReviewHistoryCsv(),
      ).map(RepertoireReviewHistoryEntry.fromCsvRow).toList();

  @override
  Future<void> appendHistory(
    List<RepertoireReviewHistoryEntry> entries, {
    required TrainingSourceContext source,
    required TrainingHistoryOperation operation,
  }) async {
    final additions = [
      for (final entry in entries) entry.toCsvRow(),
    ].join('\n');
    if (entries.any((entry) => entry.repertoireId != source.path)) {
      throw StateError('History spans another training source.');
    }
    final plan = _historyPlans[operation] ??= _HistoryAppend(
      _storage,
      source,
      additions,
    );
    if (!identical(plan.storage, _storage) ||
        !identical(plan.source, source) ||
        plan.additions != additions) {
      throw StateError(
        'A history retry must retain its original source and rows.',
      );
    }
    await source.run(() async {
      if (plan.complete) return;
      await _preserveBeforeMigration(_historyFile);
      await _storage.updateFile(_historyFile, (raw) async {
        await validateSource(source, source.path);
        if (plan.after case final prepared?) {
          if (raw == prepared) return prepared;
          if (raw == plan.before) return prepared;
          throw StateError(
            'Training history changed before recovery. Preserve the pending result.',
          );
        }
        final existing = trainingRows(
          raw,
        ).map(RepertoireReviewHistoryEntry.fromCsvRow);
        plan.before = raw;
        return plan.after =
            '$_historyHeader\n${[...existing.map((e) => e.toCsvRow()), if (additions.isNotEmpty) additions].join('\n')}\n';
      });
      plan.complete = true;
    });
  }

  // Weak keys keep the accepted operation alive only as long as its owner does.
  static final _historyPlans = Expando<_HistoryAppend>();

  // ── Move progress ─────────────────────────────────────────────────────

  @override
  Future<List<RepertoireMoveProgress>> loadMoveProgress() async {
    final entries = trainingRows(
      await _storage.readRepertoireMoveProgressCsv(),
    ).map(RepertoireMoveProgress.fromCsvRow).toList();
    _loadedProgressRows
      ..clear()
      ..addEntries([
        for (final e in entries) MapEntry(_progressKey(e), e.toCsvRow()),
      ]);
    return entries;
  }

  /// The move-progress counterpart of [saveAll].
  @override
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    String? repertoireId,
    required TrainingSourceContext source,
  }) => source.run(() async {
    await _preserveBeforeMigration(_progressFile);
    final snapshot = {
      for (final e in entries)
        if (e.repertoireId == (repertoireId ?? source.path))
          _progressKey(e): e.toCsvRow(),
    };
    bool inScope(String row) =>
        RepertoireMoveProgress.fromCsvRow(row).repertoireId ==
        (repertoireId ?? source.path);

    await _storage.updateFile(_progressFile, (raw) async {
      await validateSource(source, repertoireId ?? source.path);
      return _mergeRows(
        header: _moveProgressHeader,
        current: {
          for (final e in trainingRows(
            raw,
          ).map(RepertoireMoveProgress.fromCsvRow))
            _progressKey(e): e.toCsvRow(),
        },
        snapshot: snapshot,
        expected: _loadedProgressRows,
        inScope: inScope,
        conflict:
            'Move progress changed in another session. '
            'Reload before saving.',
        removalConflict:
            'Move progress changed before removal. '
            'Reload before saving.',
      );
    });
    _rememberSaved(_loadedProgressRows, snapshot, inScope);
  });

  // ── Optimistic CSV merge ──────────────────────────────────────────────

  /// Merge [snapshot] (key → row to save) into [current] (key → row the file
  /// holds now, normalised through the model), guarded by [expected] (key →
  /// row as of the last load):
  ///
  ///  * a snapshot row equal to its loaded row is left as the file has it;
  ///  * a changed row is written unless the file's row differs from *both*
  ///    the loaded row and the new one — another session's edit — which
  ///    throws [conflict];
  ///  * a loaded row in scope that is missing from the snapshot is removed,
  ///    unless the file's row no longer matches it, which throws
  ///    [removalConflict].
  static String _mergeRows({
    required String header,
    required Map<String, String> current,
    required Map<String, String> snapshot,
    required Map<String, String> expected,
    required bool Function(String row) inScope,
    required String conflict,
    required String removalConflict,
  }) {
    final merged = Map<String, String>.of(current);
    for (final MapEntry(:key, value: row) in snapshot.entries) {
      final loaded = expected[key];
      if (row == loaded) continue;
      final existing = merged[key];
      if (existing != loaded && existing != row) throw StateError(conflict);
      merged[key] = row;
    }
    for (final MapEntry(:key, value: loaded) in expected.entries) {
      if (!inScope(loaded) || snapshot.containsKey(key)) continue;
      if (merged[key] != loaded) throw StateError(removalConflict);
      merged.remove(key);
    }
    return '$header\n${merged.values.join('\n')}\n';
  }

  /// After a save, the rows in scope are exactly [snapshot].
  static void _rememberSaved(
    Map<String, String> loaded,
    Map<String, String> snapshot,
    bool Function(String row) inScope,
  ) {
    loaded
      ..removeWhere((_, row) => inScope(row))
      ..addAll(snapshot);
  }

  /// The first save after the CSV v2 migration keeps a copy of the old file.
  Future<void> _preserveBeforeMigration(String path) async {
    final old = await _storage.readFile(path);
    final backup = '$path.pre-csv-v2.bak';
    if (old != null && !await _storage.fileExists(backup)) {
      try {
        await _storage.writeFile(backup, old, createOnly: true);
      } catch (_) {
        // Another session may have written the backup first; only a backup
        // that is still missing is a real failure.
        if (!await _storage.fileExists(backup)) rethrow;
      }
    }
  }

  // ── Line selection ────────────────────────────────────────────────────

  /// Ensure every repertoire line has a review entry and return merged list.
  List<RepertoireReviewEntry> syncEntries({
    required String repertoireId,
    required List<RepertoireLine> lines,
    required List<RepertoireReviewEntry> existing,
  }) {
    final existingMap = {
      for (final e in existing) '${e.repertoireId}:${e.lineId}': e,
    };
    return [
      for (final line in lines)
        switch (existingMap['$repertoireId:${line.id}']) {
          final current? => current.copyWith(lineName: line.name),
          // Seed from PGN headers if available (forward/backward compatible)
          null => _entryFromPgnHeaders(repertoireId, line),
        },
    ];
  }

  static RepertoireReviewEntry _entryFromPgnHeaders(
    String repertoireId,
    RepertoireLine line,
  ) {
    final h = line.headers;
    DateTime? parseDate(String? s) =>
        (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

    return RepertoireReviewEntry(
      repertoireId: repertoireId,
      lineId: line.id,
      lineName: line.name,
      difficulty: double.tryParse(h['Difficulty'] ?? '') ?? defaultEase,
      intervalDays: double.tryParse(h['Interval'] ?? '') ?? 0.0,
      dueDateUtc: parseDate(h['DueDate']),
      lastReviewedUtc: parseDate(h['LastReview']),
      passCount: int.tryParse(h['PassCount'] ?? '') ?? 0,
      failCount: int.tryParse(h['FailCount'] ?? '') ?? 0,
    );
  }

  /// Filter due/new lines and sort according to [order].
  ///
  /// [playabilityMap] is optional; when provided and [order] is
  /// [ReviewOrder.hardestFirst], lines are sorted by ascending playability
  /// (lowest quality first). Lines without playability data sort after those
  /// with data.
  ///
  /// [dueOnly] is the spaced-repetition filter; pass `false` (linear mode)
  /// to include every line regardless of its due date.
  @override
  List<RepertoireLine> orderLinesForReview(
    List<RepertoireLine> lines,
    Map<String, RepertoireReviewEntry> reviewMap,
    ReviewOrder order, {
    Map<String, double>? playabilityMap,
    bool dueOnly = true,
  }) {
    final due = <RepertoireLine>[];
    for (final line in lines) {
      final entry = reviewMap[line.id];
      if (line.readOnlyLabel != null || (entry?.excluded ?? false)) continue;
      if (!dueOnly || entry == null || entry.isDue) {
        due.add(line);
      }
    }

    switch (order) {
      case ReviewOrder.byImportance:
        // Imported courses carry no CumProb, so every comparison returned 0 —
        // and Dart's sort is not stable, so "most likely first" shuffled the
        // course into an arbitrary order that changed between loads. With
        // nothing to sort by, file order is the honest answer.
        if (due.any((line) => line.importance != null)) {
          due.sort((a, b) {
            final ai = a.importance;
            final bi = b.importance;
            if (ai == null || bi == null) return _compareKnownFirst(ai, bi);
            return bi.compareTo(ai);
          });
        }
      case ReviewOrder.random:
        due.shuffle(_fuzz);
      case ReviewOrder.weakestFirst:
        due.sort((a, b) {
          final ea = reviewMap[a.id];
          final eb = reviewMap[b.id];
          final cmp = _weaknessScore(eb).compareTo(_weaknessScore(ea));
          if (cmp != 0) return cmp;
          return (eb?.failCount ?? 0).compareTo(ea?.failCount ?? 0);
        });
      case ReviewOrder.hardestFirst:
        if (playabilityMap != null && playabilityMap.isNotEmpty) {
          due.sort(
            (a, b) =>
                _compareKnownFirst(playabilityMap[a.id], playabilityMap[b.id]),
          );
        }
      case ReviewOrder.sequential:
        break;
    }

    return due;
  }

  /// Ascending comparison that sorts a missing value after any known one.
  static int _compareKnownFirst(double? a, double? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  static double _weaknessScore(RepertoireReviewEntry? entry) {
    if (entry == null) return 0;
    final attempts = entry.passCount + entry.failCount;
    if (attempts == 0) return 0;
    return entry.failCount / attempts;
  }

  // ── Scheduling ────────────────────────────────────────────────────────

  @override
  RepertoireReviewEntry applyRating(
    RepertoireReviewEntry entry,
    ReviewRating rating,
  ) {
    final now = _now().toUtc();
    final ease = _easeAfter(_clampedEase(entry), rating);
    final interval = _fuzzed(_nextInterval(entry.intervalDays, rating, ease));

    return entry.copyWith(
      difficulty: ease,
      intervalDays: interval,
      dueDateUtc: now.add(
        Duration(
          milliseconds: (interval * Duration.millisecondsPerDay).round(),
        ),
      ),
      lastRating: rating.name,
      lastReviewedUtc: now,
    );
  }

  /// Legacy rows stored eases outside the SM-2 range (the old default was
  /// 1.5 and the old ceiling 5.0); clamping on read migrates them in place.
  static double _clampedEase(RepertoireReviewEntry entry) =>
      entry.difficulty.clamp(minEase, maxEase);

  static double _easeAfter(double ease, ReviewRating rating) =>
      switch (rating) {
        ReviewRating.again => max(minEase, ease - _againEasePenalty),
        ReviewRating.hard => max(minEase, ease - _hardEasePenalty),
        ReviewRating.good => ease,
        ReviewRating.easy => min(maxEase, ease + _easyEaseBonus),
      };

  /// The scheduled interval for [rating], before fuzz.
  ///
  /// The ease is what makes Hard/Good/Easy diverge over time rather than at
  /// one review: a line answered Good repeatedly stretches by its own ease,
  /// which Easy raises and Again/Hard lower. Before this the ease was stored
  /// and never read, so every line grew at the same fixed 1.6x.
  static double _nextInterval(
    double current,
    ReviewRating rating,
    double ease,
  ) {
    // A line rated for the first time (or after an Again) has no interval to
    // multiply, so it graduates onto a fixed first step.
    final isFirst = current < 1;
    final next = switch (rating) {
      ReviewRating.again => againIntervalDays,
      // Hard has to move: `current * 1.2` on a 1-day interval rounds back to
      // roughly a day forever, which is how a line becomes a leech.
      ReviewRating.hard => isFirst ? 1.0 : max(current + 1, current * 1.2),
      ReviewRating.good => isFirst ? 1.0 : current * ease,
      ReviewRating.easy => isFirst ? 3.0 : current * ease * 1.3,
    };
    return min(next, maxIntervalDays);
  }

  /// Anki's interval fuzz: up to ±5% (at least a day either way once the
  /// interval is more than a couple of days), so lines learned together stop
  /// arriving together. Never applied to sub-day intervals.
  double _fuzzed(double interval) {
    if (interval < 2) return interval;
    final spread = max(1.0, interval * 0.05);
    final jittered = interval + (_fuzz.nextDouble() * 2 - 1) * spread;
    return jittered.clamp(1.0, maxIntervalDays);
  }

  /// Dry-run of [applyRating] that returns the predicted interval without
  /// persisting anything or fuzzing it.  Used to show "Again (5m)" /
  /// "Good (4d)" previews, which should read as round numbers.
  @override
  double previewInterval(RepertoireReviewEntry entry, ReviewRating rating) =>
      _nextInterval(entry.intervalDays, rating, _clampedEase(entry));
}

/// In-process exact append retry. Preparation precedes publication inside the
/// existing storage lock; acknowledgement follows the complete guarded write.
class _HistoryAppend {
  _HistoryAppend(this.storage, this.source, this.additions);
  final StorageService storage;
  final TrainingSourceContext source;
  final String additions;
  String? before;
  String? after;
  bool complete = false;
}
