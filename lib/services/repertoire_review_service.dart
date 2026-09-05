import 'dart:math';
import '../utils/training_csv.dart';

import '../models/repertoire_line.dart';
import '../models/repertoire_review_entry.dart';
import '../models/repertoire_review_history_entry.dart';
import '../models/repertoire_move_progress.dart';
import '../models/training_settings.dart';
import 'storage/storage_factory.dart';
import 'storage/storage_service.dart';

class RepertoireReviewService {
  static const _header =
      'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count';
  static const _historyHeader =
      'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type';
  static const _moveProgressHeader =
      'repertoire_id,line_id,move_index,correct_streak,learned';

  final StorageService _storage;

  static const _reviewsFile = 'repertoire_reviews.csv';
  static const _historyFile = 'repertoire_review_history.csv';
  static const _progressFile = 'repertoire_move_progress.csv';
  final Map<String, String> _loadedReviewRows = {};
  final Map<String, String> _loadedProgressRows = {};

  String _reviewKey(RepertoireReviewEntry e) =>
      '${e.repertoireId.length}:${e.repertoireId}${e.lineId}';
  String _progressKey(RepertoireMoveProgress e) =>
      '${e.repertoireId.length}:${e.repertoireId}${e.lineId}:${e.moveIndex}';

  Future<List<RepertoireReviewEntry>> loadAll() async {
    final entries = trainingRows(
      await _storage.readRepertoireReviewsCsv(),
    ).map(RepertoireReviewEntry.fromCsvRow).toList();
    _loadedReviewRows.clear();
    for (final e in entries) {
      _loadedReviewRows[_reviewKey(e)] = e.toCsvRow();
    }
    return entries;
  }

  Future<void> _preserveBeforeMigration(String path) async {
    final old = await _storage.readFile(path);
    final backup = '$path.pre-csv-v2.bak';
    if (old != null && !await _storage.fileExists(backup)) {
      try {
        await _storage.writeFile(backup, old, createOnly: true);
      } catch (_) {
        if (!await _storage.fileExists(backup)) rethrow;
      }
    }
  }

  Future<void> saveAll(
    List<RepertoireReviewEntry> entries, {
    String? repertoireId,
  }) async {
    await _preserveBeforeMigration(_reviewsFile);
    final snapshot = [
      for (final e in entries)
        if (repertoireId == null || e.repertoireId == repertoireId)
          e.toCsvRow(),
    ];
    final expected = Map<String, String>.of(_loadedReviewRows);
    await _storage.updateFile(_reviewsFile, (raw) {
      final current = trainingRows(
        raw,
      ).map(RepertoireReviewEntry.fromCsvRow).toList();
      final merged = {for (final e in current) _reviewKey(e): e};
      for (final row in snapshot) {
        final e = RepertoireReviewEntry.fromCsvRow(row);
        final key = _reviewKey(e);
        final existing = merged[key]?.toCsvRow();
        if (row == expected[key]) continue;
        if (existing != expected[key] && existing != row) {
          throw StateError(
            'Training progress changed in another session. Reload before saving.',
          );
        }
        merged[key] = e;
      }
      final keys = {
        for (final row in snapshot)
          _reviewKey(RepertoireReviewEntry.fromCsvRow(row)),
      };
      for (final entry in expected.entries) {
        final previous = RepertoireReviewEntry.fromCsvRow(entry.value);
        if ((repertoireId == null || previous.repertoireId == repertoireId) &&
            !keys.contains(entry.key)) {
          if (merged[entry.key]?.toCsvRow() != entry.value) {
            throw StateError(
              'Training progress changed before removal. Reload before saving.',
            );
          }
          merged.remove(entry.key);
        }
      }
      return '$_header\n${merged.values.map((e) => e.toCsvRow()).join('\n')}\n';
    });
    _loadedReviewRows.removeWhere(
      (key, row) =>
          repertoireId == null ||
          RepertoireReviewEntry.fromCsvRow(row).repertoireId == repertoireId,
    );
    for (final row in snapshot) {
      final e = RepertoireReviewEntry.fromCsvRow(row);
      _loadedReviewRows[_reviewKey(e)] = row;
    }
  }

  Future<List<RepertoireReviewHistoryEntry>> loadHistory() async =>
      trainingRows(
        await _storage.readRepertoireReviewHistoryCsv(),
      ).map(RepertoireReviewHistoryEntry.fromCsvRow).toList();

  Future<void> appendHistory(List<RepertoireReviewHistoryEntry> entries) async {
    await _preserveBeforeMigration(_historyFile);
    final additions = entries.map((e) => e.toCsvRow()).toList();
    await _storage.updateFile(_historyFile, (raw) {
      final existing = trainingRows(
        raw,
      ).map(RepertoireReviewHistoryEntry.fromCsvRow);
      return '$_historyHeader\n${[...existing.map((e) => e.toCsvRow()), ...additions].join('\n')}\n';
    });
  }

  Future<List<RepertoireMoveProgress>> loadMoveProgress() async {
    final entries = trainingRows(
      await _storage.readRepertoireMoveProgressCsv(),
    ).map(RepertoireMoveProgress.fromCsvRow).toList();
    _loadedProgressRows.clear();
    for (final e in entries) {
      _loadedProgressRows[_progressKey(e)] = e.toCsvRow();
    }
    return entries;
  }

  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    String? repertoireId,
  }) async {
    await _preserveBeforeMigration(_progressFile);
    final snapshot = {
      for (final e in entries)
        if (repertoireId == null || e.repertoireId == repertoireId)
          _progressKey(e): e.toCsvRow(),
    };
    final expected = Map<String, String>.of(_loadedProgressRows);
    await _storage.updateFile(_progressFile, (raw) {
      final current = trainingRows(raw).map(RepertoireMoveProgress.fromCsvRow);
      final merged = {for (final e in current) _progressKey(e): e.toCsvRow()};
      for (final entry in snapshot.entries) {
        if (entry.value == expected[entry.key]) continue;
        if (merged[entry.key] != expected[entry.key] &&
            merged[entry.key] != entry.value) {
          throw StateError(
            'Move progress changed in another session. Reload before saving.',
          );
        }
        merged[entry.key] = entry.value;
      }
      for (final entry in expected.entries) {
        final previous = RepertoireMoveProgress.fromCsvRow(entry.value);
        if ((repertoireId == null || previous.repertoireId == repertoireId) &&
            !snapshot.containsKey(entry.key)) {
          if (merged[entry.key] != entry.value) {
            throw StateError(
              'Move progress changed before removal. Reload before saving.',
            );
          }
          merged.remove(entry.key);
        }
      }
      return '$_moveProgressHeader\n${merged.values.join('\n')}\n';
    });
    _loadedProgressRows.removeWhere(
      (key, row) =>
          repertoireId == null ||
          RepertoireMoveProgress.fromCsvRow(row).repertoireId == repertoireId,
    );
    _loadedProgressRows.addAll(snapshot);
  }

  /// Ensure every repertoire line has a review entry and return merged list.
  List<RepertoireReviewEntry> syncEntries({
    required String repertoireId,
    required List<RepertoireLine> lines,
    required List<RepertoireReviewEntry> existing,
  }) {
    final merged = <RepertoireReviewEntry>[];
    final existingMap = {
      for (final e in existing) '${e.repertoireId}:${e.lineId}': e,
    };

    for (final line in lines) {
      final key = '$repertoireId:${line.id}';
      final current = existingMap[key];
      if (current != null) {
        merged.add(current.copyWith(lineName: line.name));
      } else {
        // Seed from PGN headers if available (forward/backward compatible)
        merged.add(_entryFromPgnHeaders(repertoireId, line));
      }
    }

    return merged;
  }

  RepertoireReviewEntry _entryFromPgnHeaders(
    String repertoireId,
    RepertoireLine line,
  ) {
    final h = line.headers;
    DateTime? parseDate(String? s) {
      if (s == null || s.isEmpty) return null;
      return DateTime.tryParse(s);
    }

    return RepertoireReviewEntry(
      repertoireId: repertoireId,
      lineId: line.id,
      lineName: line.name,
      difficulty: double.tryParse(h['Difficulty'] ?? '') ?? 2.5,
      intervalDays: double.tryParse(h['Interval'] ?? '') ?? 0.0,
      dueDateUtc: parseDate(h['DueDate']),
      lastReviewedUtc: parseDate(h['LastReview']),
      passCount: int.tryParse(h['PassCount'] ?? '') ?? 0,
      failCount: int.tryParse(h['FailCount'] ?? '') ?? 0,
    );
  }

  /// Return lines that are due (or new) in the original file order.
  List<RepertoireLine> dueLinesInOrder(
    List<RepertoireLine> lines,
    Map<String, RepertoireReviewEntry> reviewMap,
  ) {
    return orderLinesForReview(lines, reviewMap, ReviewOrder.sequential);
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
            if (ai == null && bi == null) return 0;
            if (ai == null) return 1;
            if (bi == null) return -1;
            return bi.compareTo(ai);
          });
        }
      case ReviewOrder.random:
        due.shuffle(Random());
      case ReviewOrder.weakestFirst:
        due.sort((a, b) {
          final ea = reviewMap[a.id];
          final eb = reviewMap[b.id];
          final wa = _weaknessScore(ea);
          final wb = _weaknessScore(eb);
          final cmp = wb.compareTo(wa);
          if (cmp != 0) return cmp;
          return (eb?.failCount ?? 0).compareTo(ea?.failCount ?? 0);
        });
      case ReviewOrder.hardestFirst:
        if (playabilityMap != null && playabilityMap.isNotEmpty) {
          due.sort((a, b) {
            final pa = playabilityMap[a.id];
            final pb = playabilityMap[b.id];
            if (pa == null && pb == null) return 0;
            if (pa == null) return 1;
            if (pb == null) return -1;
            return pa.compareTo(pb);
          });
        }
      case ReviewOrder.sequential:
        break;
    }

    return due;
  }

  double _weaknessScore(RepertoireReviewEntry? entry) {
    if (entry == null) return 0;
    final attempts = entry.passCount + entry.failCount;
    if (attempts == 0) return 0;
    return entry.failCount / attempts;
  }

  /// Smallest and largest ease a line can reach. [RepertoireReviewEntry.
  /// difficulty] *is* the ease factor — "higher = easier" — and SM-2 keeps it
  /// off the floor so a line you keep failing still eventually stretches out.
  static const double minEase = 1.3;
  static const double maxEase = 3.0;

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

  /// Spread applied to a scheduled interval, Anki-style, so a course learned
  /// in one weekend does not come back as one 900-line day. Injectable so
  /// tests can pin it.
  final Random _fuzz;

  /// [storage] is injectable only so tests can hold the review CSVs in
  /// memory instead of writing to the user's real `~/Documents`; every
  /// caller outside a test passes nothing.
  RepertoireReviewService({Random? fuzz, StorageService? storage})
    : _fuzz = fuzz ?? Random(),
      _storage = storage ?? StorageFactory.instance;

  RepertoireReviewEntry applyRating(
    RepertoireReviewEntry entry,
    ReviewRating rating,
  ) {
    final now = DateTime.now().toUtc();
    // Legacy rows stored eases outside the SM-2 range (the old default was
    // 1.5 and the old ceiling 5.0); clamping on read migrates them in place.
    double ease = entry.difficulty.clamp(minEase, maxEase);

    switch (rating) {
      case ReviewRating.again:
        ease = max(minEase, ease - 0.20);
      case ReviewRating.hard:
        ease = max(minEase, ease - 0.15);
      case ReviewRating.good:
        break;
      case ReviewRating.easy:
        ease = min(maxEase, ease + 0.15);
    }

    final interval = _fuzzed(_nextInterval(entry.intervalDays, rating, ease));
    final millis = (interval * 24 * 60 * 60 * 1000).round();

    return entry.copyWith(
      difficulty: ease,
      intervalDays: interval,
      dueDateUtc: now.add(Duration(milliseconds: millis)),
      lastRating: rating.name,
      lastReviewedUtc: now,
    );
  }

  /// The scheduled interval for [rating], before fuzz.
  ///
  /// The ease is what makes Hard/Good/Easy diverge over time rather than at
  /// one review: a line answered Good repeatedly stretches by its own ease,
  /// which Easy raises and Again/Hard lower. Before this the ease was stored
  /// and never read, so every line grew at the same fixed 1.6x.
  double _nextInterval(double current, ReviewRating rating, double ease) {
    if (rating == ReviewRating.again) return againIntervalDays;
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
  double previewInterval(RepertoireReviewEntry entry, ReviewRating rating) {
    final ease = entry.difficulty.clamp(minEase, maxEase);
    return _nextInterval(entry.intervalDays, rating, ease);
  }

  /// Human-readable label for a review interval in days.
  static String formatInterval(double intervalDays) {
    // "Again" schedules zero days on purpose — the line comes back inside the
    // session you are in — and "<1m" reads as a rounding artefact rather than
    // as the promise it is.
    if (intervalDays <= 0) return 'now';
    if (intervalDays < 1 / 24) return '<1m';
    if (intervalDays < 1) {
      final hours = (intervalDays * 24).round();
      return '${hours}h';
    }
    if (intervalDays < 30) {
      final days = intervalDays.round();
      return '${days}d';
    }
    if (intervalDays < 365) {
      final months = (intervalDays / 30).round();
      return '${months}mo';
    }
    final years = (intervalDays / 365).round();
    return '${years}y';
  }

  Map<String, RepertoireMoveProgress> indexMoveProgress(
    List<RepertoireMoveProgress> items,
  ) {
    return {for (final i in items) '${i.lineId}:${i.moveIndex}': i};
  }
}
