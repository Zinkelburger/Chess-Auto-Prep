class RepertoireReviewHistoryEntry {
  final String repertoireId;
  final String lineId;
  final DateTime timestampUtc;
  final String rating;
  final bool hadMistake;
  final String sessionType; // e.g., "trainer"

  RepertoireReviewHistoryEntry({
    required this.repertoireId,
    required this.lineId,
    required this.timestampUtc,
    required this.rating,
    required this.hadMistake,
    this.sessionType = 'trainer',
  });

  String toCsvRow() {
    return [
      repertoireId,
      lineId,
      timestampUtc.toUtc().toIso8601String(),
      rating,
      hadMistake ? '1' : '0',
      sessionType,
    ].join(',');
  }

  static RepertoireReviewHistoryEntry fromCsvRow(String row) {
    final cells = row.split(',').map((c) => c.trim()).toList();
    if (cells.length < 6) {
      throw FormatException('Invalid review history row: $row');
    }
    return RepertoireReviewHistoryEntry(
      repertoireId: cells[0],
      lineId: cells[1],
      timestampUtc: DateTime.parse(cells[2]).toUtc(),
      rating: cells[3],
      hadMistake: cells[4] == '1',
      sessionType: cells[5],
    );
  }
}









