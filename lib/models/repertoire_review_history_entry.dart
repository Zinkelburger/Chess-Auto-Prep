import '../utils/training_csv.dart';

/// One row of the training log: how a line was rated in one session.
class RepertoireReviewHistoryEntry {
  final String repertoireId;
  final String lineId;
  final DateTime timestampUtc;
  final String rating;
  final bool hadMistake;

  /// Which kind of session produced the rating, e.g. `trainer`.
  final String sessionType;

  const RepertoireReviewHistoryEntry({
    required this.repertoireId,
    required this.lineId,
    required this.timestampUtc,
    required this.rating,
    required this.hadMistake,
    this.sessionType = 'trainer',
  });

  String toCsvRow() {
    return encodeTrainingRow([
      repertoireId,
      lineId,
      timestampUtc.toUtc().toIso8601String(),
      rating,
      hadMistake ? '1' : '0',
      sessionType,
    ]);
  }

  factory RepertoireReviewHistoryEntry.fromCsvRow(String row) {
    final cells = decodeTrainingRow(row, 6);
    if (cells.length != 6) {
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
