/// Lightweight model wrapping a single parsed game + its raw text for rewrite.
library;

class PgnGameEntry {
  final Map<String, String> headers;
  String pgnText; // full single-game PGN (headers + moves)
  int studyRating; // 0 = unrated, 1-5
  String studySummary; // user's one-line summary of the game

  PgnGameEntry({
    required this.headers,
    required this.pgnText,
    this.studyRating = 0,
    this.studySummary = '',
  });

  String get label {
    final w = headers['White'] ?? '?';
    final b = headers['Black'] ?? '?';
    final wElo = headers['WhiteElo'];
    final bElo = headers['BlackElo'];
    final wStr =
        wElo != null && wElo.isNotEmpty && wElo != '?' ? '$w ($wElo)' : w;
    final bStr =
        bElo != null && bElo.isNotEmpty && bElo != '?' ? '$b ($bElo)' : b;
    final d = headers['Date'] ?? '';
    return '$wStr vs $bStr  $d';
  }
}
