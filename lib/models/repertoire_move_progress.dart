class RepertoireMoveProgress {
  final String repertoireId;
  final String lineId;
  final int moveIndex;
  final int correctStreak; // number of consecutive correct attempts
  final bool learned; // true when streak >= threshold

  RepertoireMoveProgress({
    required this.repertoireId,
    required this.lineId,
    required this.moveIndex,
    required this.correctStreak,
    required this.learned,
  });

  RepertoireMoveProgress copyWith({
    int? correctStreak,
    bool? learned,
  }) {
    return RepertoireMoveProgress(
      repertoireId: repertoireId,
      lineId: lineId,
      moveIndex: moveIndex,
      correctStreak: correctStreak ?? this.correctStreak,
      learned: learned ?? this.learned,
    );
  }

  String toCsvRow() {
    return [
      repertoireId,
      lineId,
      moveIndex.toString(),
      correctStreak.toString(),
      learned ? '1' : '0',
    ].join(',');
  }

  static RepertoireMoveProgress fromCsvRow(String row) {
    final cells = row.split(',').map((c) => c.trim()).toList();
    if (cells.length < 5) {
      throw FormatException('Invalid move progress row: $row');
    }
    return RepertoireMoveProgress(
      repertoireId: cells[0],
      lineId: cells[1],
      moveIndex: int.parse(cells[2]),
      correctStreak: int.parse(cells[3]),
      learned: cells[4] == '1',
    );
  }
}





