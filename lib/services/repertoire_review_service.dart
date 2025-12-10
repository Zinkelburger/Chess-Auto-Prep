import 'dart:math';

import '../models/repertoire_line.dart';
import '../models/repertoire_review_entry.dart';
import '../models/repertoire_review_history_entry.dart';
import '../models/repertoire_move_progress.dart';
import 'storage/storage_factory.dart';

class RepertoireReviewService {
  static const _header =
      'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc';
  static const _historyHeader =
      'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type';
  static const _moveProgressHeader =
      'repertoire_id,line_id,move_index,correct_streak,learned';

  final _storage = StorageFactory.instance;

  Future<List<RepertoireReviewEntry>> loadAll() async {
    final csv = await _storage.readRepertoireReviewsCsv();
    if (csv == null || csv.trim().isEmpty) return [];

    final lines = csv.split('\n').where((line) => line.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];

    final rows = lines.first.trim() == _header ? lines.sublist(1) : lines;
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
    final lines = csv.split('\n').where((line) => line.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];
    final rows = lines.first.trim() == _historyHeader ? lines.sublist(1) : lines;
    return rows.map((row) => RepertoireReviewHistoryEntry.fromCsvRow(row)).toList();
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
    final lines = csv.split('\n').where((line) => line.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];
    final rows = lines.first.trim() == _moveProgressHeader ? lines.sublist(1) : lines;
    return rows.map((row) => RepertoireMoveProgress.fromCsvRow(row)).toList();
  }

  Future<void> saveMoveProgress(List<RepertoireMoveProgress> entries) async {
    final buffer = StringBuffer()..writeln(_moveProgressHeader);
    for (final entry in entries) {
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
    final existingMap = {for (final e in existing) '${e.repertoireId}:${e.lineId}': e};

    for (final line in lines) {
      final key = '$repertoireId:${line.id}';
      final current = existingMap[key];
      if (current != null) {
        // Keep name fresh if it changed
        merged.add(current.copyWith(lineName: line.name));
      } else {
        merged.add(RepertoireReviewEntry(
          repertoireId: repertoireId,
          lineId: line.id,
          lineName: line.name,
        ));
      }
    }

    return merged;
  }

  /// Return lines that are due (or new) in the original order.
  List<RepertoireLine> dueLinesInOrder(
    List<RepertoireLine> lines,
    Map<String, RepertoireReviewEntry> reviewMap,
  ) {
    final due = <RepertoireLine>[];
    for (final line in lines) {
      final entry = reviewMap[line.id];
      if (entry == null || entry.isDue) {
        due.add(line);
      }
    }
    return due;
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

  Map<String, RepertoireMoveProgress> indexMoveProgress(List<RepertoireMoveProgress> items) {
    return {for (final i in items) '${i.lineId}:${i.moveIndex}': i};
  }
}

