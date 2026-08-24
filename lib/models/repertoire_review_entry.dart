enum ReviewRating { again, hard, good, easy }

/// Lightweight spaced-repetition metadata for a repertoire line.
/// Stores only aggregated difficulty, not per-move history.
class RepertoireReviewEntry {
  final String repertoireId;
  final String lineId;
  String lineName;

  /// SM-2 ease factor: how much the interval stretches on a "Good". Higher is
  /// easier. Clamped to [RepertoireReviewService.minEase] ..
  /// [RepertoireReviewService.maxEase] whenever it is used, which migrates the
  /// values written before the scheduler read this field at all.
  double difficulty;
  double intervalDays;
  DateTime? dueDateUtc;
  String lastRating;
  DateTime? lastReviewedUtc;
  int passCount;
  int failCount;

  RepertoireReviewEntry({
    required this.repertoireId,
    required this.lineId,
    required this.lineName,
    // SM-2's starting ease. Was 1.5 here and 2.5 when seeded from PGN
    // headers, which meant the same line scheduled differently depending on
    // which path created its row.
    this.difficulty = 2.5,
    this.intervalDays = 0,
    this.dueDateUtc,
    this.lastRating = '',
    this.lastReviewedUtc,
    this.passCount = 0,
    this.failCount = 0,
  });

  bool get isNew => lastRating.isEmpty;
  bool get isDue {
    if (isNew) return true;
    if (dueDateUtc == null) return true;
    return !dueDateUtc!.isAfter(DateTime.now().toUtc());
  }

  RepertoireReviewEntry copyWith({
    String? lineName,
    double? difficulty,
    double? intervalDays,
    DateTime? dueDateUtc,
    String? lastRating,
    DateTime? lastReviewedUtc,
    int? passCount,
    int? failCount,
  }) {
    return RepertoireReviewEntry(
      repertoireId: repertoireId,
      lineId: lineId,
      lineName: lineName ?? this.lineName,
      difficulty: difficulty ?? this.difficulty,
      intervalDays: intervalDays ?? this.intervalDays,
      dueDateUtc: dueDateUtc ?? this.dueDateUtc,
      lastRating: lastRating ?? this.lastRating,
      lastReviewedUtc: lastReviewedUtc ?? this.lastReviewedUtc,
      passCount: passCount ?? this.passCount,
      failCount: failCount ?? this.failCount,
    );
  }

  static RepertoireReviewEntry fromCsvRow(String row) {
    final cells = _parseCsvRow(row);
    if (cells.length < 8) {
      throw FormatException('Invalid repertoire review row: $row');
    }

    final due = cells[5].isEmpty ? null : DateTime.tryParse(cells[5])?.toUtc();
    final reviewed = cells[7].isEmpty
        ? null
        : DateTime.tryParse(cells[7])?.toUtc();

    return RepertoireReviewEntry(
      repertoireId: cells[0],
      lineId: cells[1],
      lineName: cells[2],
      difficulty: double.tryParse(cells[3]) ?? 2.5,
      intervalDays: double.tryParse(cells[4]) ?? 0,
      dueDateUtc: due,
      lastRating: cells[6],
      lastReviewedUtc: reviewed,
      passCount: cells.length > 8 ? (int.tryParse(cells[8]) ?? 0) : 0,
      failCount: cells.length > 9 ? (int.tryParse(cells[9]) ?? 0) : 0,
    );
  }

  String toCsvRow() {
    final dueStr = dueDateUtc == null
        ? ''
        : dueDateUtc!.toUtc().toIso8601String();
    final reviewedStr = lastReviewedUtc == null
        ? ''
        : lastReviewedUtc!.toUtc().toIso8601String();

    return [
      repertoireId,
      lineId,
      lineName.replaceAll(',', ';'),
      difficulty.toStringAsFixed(2),
      intervalDays.toStringAsFixed(2),
      dueStr,
      lastRating,
      reviewedStr,
      passCount.toString(),
      failCount.toString(),
    ].join(',');
  }

  static List<String> _parseCsvRow(String row) {
    // Simple CSV parser (no quoted commas in our use-case)
    return row.split(',').map((cell) => cell.trim()).toList();
  }
}
