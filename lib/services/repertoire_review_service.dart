import 'dart:math';

import '../models/repertoire_line.dart';
import '../models/repertoire_review_entry.dart';
import '../models/repertoire_review_history_entry.dart';
import '../models/repertoire_move_progress.dart';
import '../models/training_settings.dart';
import 'storage/storage_factory.dart';

class RepertoireReviewService {
  static const _header =
      'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count';
  static const _historyHeader =
      'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type';
  static const _moveProgressHeader =
      'repertoire_id,line_id,move_index,correct_streak,learned';

  final _storage = StorageFactory.instance;

  Future<List<RepertoireReviewEntry>> loadAll() async {
    final csv = await _storage.readRepertoireReviewsCsv();
    if (csv == null || csv.trim().isEmpty) return [];

    final lines = csv
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return [];

    final firstLine = lines.first.trim();
    final rows = firstLine.startsWith('repertoire_id,')
        ? lines.sublist(1)
        : lines;
    return rows.map((row) => RepertoireReviewEntry.fromCsvRow(row)).toList();
  }

  Future<void> saveAll(List<RepertoireReviewEntry> entries) async {
    final buffer = StringBuffer()..writeln(_header);
    for (final entry in entries) {
      buffer.writeln(entry.toCsvRow());
    }
    await _storage.saveRepertoireReviewsCsv(buffer.toString());
  }

  Future<List<RepertoireReviewHistoryEntry>> loadHistory() async {
    final csv = await _storage.readRepertoireReviewHistoryCsv();
    if (csv == null || csv.trim().isEmpty) return [];
    final lines = csv
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return [];
    final rows = lines.first.trim() == _historyHeader
        ? lines.sublist(1)
        : lines;
    return rows
        .map((row) => RepertoireReviewHistoryEntry.fromCsvRow(row))
        .toList();
  }

  Future<void> appendHistory(List<RepertoireReviewHistoryEntry> entries) async {
    final existing = await loadHistory();
    final all = [...existing, ...entries];
    final buffer = StringBuffer()..writeln(_historyHeader);
    for (final entry in all) {
      buffer.writeln(entry.toCsvRow());
    }
    await _storage.saveRepertoireReviewHistoryCsv(buffer.toString());
  }

  Future<List<RepertoireMoveProgress>> loadMoveProgress() async {
    final csv = await _storage.readRepertoireMoveProgressCsv();
    if (csv == null || csv.trim().isEmpty) return [];
    final lines = csv
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return [];
    final rows = lines.first.trim() == _moveProgressHeader
        ? lines.sublist(1)
        : lines;
    return rows.map((row) => RepertoireMoveProgress.fromCsvRow(row)).toList();
  }

  /// Save move progress for a specific repertoire, merging with other
  /// repertoires' data already on disk.
  Future<void> saveMoveProgress(
    List<RepertoireMoveProgress> entries, {
    String? repertoireId,
  }) async {
    List<RepertoireMoveProgress> all;
    if (repertoireId != null) {
      final existing = await loadMoveProgress();
      final others = existing
          .where((e) => e.repertoireId != repertoireId)
          .toList();
      all = [...others, ...entries];
    } else {
      all = entries;
    }
    final buffer = StringBuffer()..writeln(_moveProgressHeader);
    for (final entry in all) {
      buffer.writeln(entry.toCsvRow());
    }
    await _storage.saveRepertoireMoveProgressCsv(buffer.toString());
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

  RepertoireReviewService({Random? fuzz}) : _fuzz = fuzz ?? Random();

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
