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
        due.sort((a, b) {
          final ai = a.importance;
          final bi = b.importance;
          if (ai == null && bi == null) return 0;
          if (ai == null) return 1;
          if (bi == null) return -1;
          return bi.compareTo(ai);
        });
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

  RepertoireReviewEntry applyRating(
    RepertoireReviewEntry entry,
    ReviewRating rating,
  ) {
    final now = DateTime.now().toUtc();
    double difficulty = entry.difficulty;
    double interval = entry.intervalDays;

    switch (rating) {
      case ReviewRating.again:
        difficulty = max(1.0, difficulty - 0.3);
        interval = 0.05; // ~1 hour
        break;
      case ReviewRating.hard:
        difficulty = max(1.0, difficulty - 0.1);
        interval = interval <= 0 ? 1.0 : max(1.0, interval * 0.8 + 0.2);
        break;
      case ReviewRating.good:
        difficulty = min(5.0, difficulty + 0.1);
        interval = interval <= 0 ? 1.5 : interval * 1.6;
        break;
      case ReviewRating.easy:
        difficulty = min(5.0, difficulty + 0.25);
        interval = interval <= 0 ? 2.5 : interval * 2.3;
        break;
    }

    final millis = (interval * 24 * 60 * 60 * 1000).round();
    final dueDate = now.add(Duration(milliseconds: millis));

    return entry.copyWith(
      difficulty: difficulty,
      intervalDays: interval,
      dueDateUtc: dueDate,
      lastRating: rating.name,
      lastReviewedUtc: now,
    );
  }

  /// Dry-run of [applyRating] that returns the predicted interval without
  /// persisting anything.  Used to show "Again (1h)" / "Good (4d)" previews.
  double previewInterval(RepertoireReviewEntry entry, ReviewRating rating) {
    double interval = entry.intervalDays;
    switch (rating) {
      case ReviewRating.again:
        interval = 0.05;
        break;
      case ReviewRating.hard:
        interval = interval <= 0 ? 1.0 : max(1.0, interval * 0.8 + 0.2);
        break;
      case ReviewRating.good:
        interval = interval <= 0 ? 1.5 : interval * 1.6;
        break;
      case ReviewRating.easy:
        interval = interval <= 0 ? 2.5 : interval * 2.3;
        break;
    }
    return interval;
  }

  /// Human-readable label for a review interval in days.
  static String formatInterval(double intervalDays) {
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
