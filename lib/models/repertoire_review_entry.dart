enum ReviewRating { again, hard, good, easy }

/// Lightweight spaced-repetition metadata for a repertoire line.
/// Stores only aggregated difficulty, not per-move history.
class RepertoireReviewEntry {
  final String repertoireId;
  final String lineId;
  String lineName;
  double difficulty; // Higher = easier
  double intervalDays;
  DateTime? dueDateUtc;
  String lastRating;
  DateTime? lastReviewedUtc;

  RepertoireReviewEntry({
    required this.repertoireId,
    required this.lineId,
    required this.lineName,
    this.difficulty = 1.5,
    this.intervalDays = 0,
    this.dueDateUtc,
    this.lastRating = '',
    this.lastReviewedUtc,
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
    );
  }

  static RepertoireReviewEntry fromCsvRow(String row) {
    final cells = _parseCsvRow(row);
    if (cells.length < 8) {
      throw FormatException('Invalid repertoire review row: $row');
    }

    final due = cells[5].isEmpty ? null : DateTime.tryParse(cells[5])?.toUtc();
    final reviewed = cells[7].isEmpty ? null : DateTime.tryParse(cells[7])?.toUtc();

    return RepertoireReviewEntry(
      repertoireId: cells[0],
      lineId: cells[1],
      lineName: cells[2],
      difficulty: double.tryParse(cells[3]) ?? 1.5,
      intervalDays: double.tryParse(cells[4]) ?? 0,
      dueDateUtc: due,
      lastRating: cells[6],
      lastReviewedUtc: reviewed,
    );
  }

  String toCsvRow() {
    final dueStr = dueDateUtc == null ? '' : dueDateUtc!.toUtc().toIso8601String();
    final reviewedStr =
        lastReviewedUtc == null ? '' : lastReviewedUtc!.toUtc().toIso8601String();

    return [
      repertoireId,
      lineId,
      lineName.replaceAll(',', ';'),
      difficulty.toStringAsFixed(2),
      intervalDays.toStringAsFixed(2),
      dueStr,
      lastRating,
      reviewedStr,
    ].join(',');
  }

  static List<String> _parseCsvRow(String row) {
    // Simple CSV parser (no quoted commas in our use-case)
    return row.split(',').map((cell) => cell.trim()).toList();
  }
}

