/// Lightweight model wrapping a single parsed game + its raw text for rewrite.
library;

import '../utils/pgn_date_utils.dart';

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
    final w = (headers['White'] ?? '?').trim();
    final b = (headers['Black'] ?? '?').trim();
    final wElo = headers['WhiteElo'];
    final bElo = headers['BlackElo'];
    final wStr = _eloSuffix(w, wElo);
    final bStr = _eloSuffix(b, bElo);
    final d = formatPgnDate(headers['Date']);

    final title = _courseStyleTitle(wStr, bStr, w, b);
    if (d.isEmpty) return title;
    return '$title  $d';
  }

  /// Course exports use White as a chapter/theme and Black as the line title,
  /// with an unfinished result and no player ratings. The viewer uses this to
  /// choose book typography and its focused one-note-at-a-time reader.
  bool get isCourseStyle {
    final white = (headers['White'] ?? '').trim();
    final result = (headers['Result'] ?? '').trim();
    final hasRating = ['WhiteElo', 'BlackElo'].any((key) {
      final value = (headers[key] ?? '').trim();
      return value.isNotEmpty && value != '?';
    });
    return result == '*' &&
        !hasRating &&
        white.isNotEmpty &&
        white != '?' &&
        !white.contains(',');
  }

  static String _eloSuffix(String name, String? elo) {
    if (elo != null && elo.isNotEmpty && elo != '?') return '$name ($elo)';
    return name;
  }

  /// Course exports put the chapter in [White] and the line in [Black], with
  /// Result `*` and no ratings. Player games (rated, or "Last, First") stay
  /// "White vs Black". [Result] must be present as `*` so unlabeled test
  /// fixtures and real games that omitted the header don't get a chapter dash.
  String _courseStyleTitle(String wStr, String bStr, String w, String b) {
    final course = isCourseStyle;
    if (!course) return '$wStr vs $bStr';
    if (b.isEmpty || b == '?' || b == w) return wStr;
    return '$wStr — $bStr';
  }
}
