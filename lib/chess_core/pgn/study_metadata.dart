/// Each game's text with its `[StudyRating]` / `[StudySummary]` headers
/// brought in line with the rating and summary it carries: written when set,
/// removed when cleared. Summary quotes become apostrophes so the header
/// value stays a single PGN string.
List<String> buildMetadataOutput(
  List<({String pgn, int rating, String summary})> gameData,
) => [
  for (final game in gameData)
    _withStudySummary(_withStudyRating(game.pgn, game.rating), game.summary),
];

String _withStudyRating(String pgn, int rating) => rating > 0
    ? upsertPgnHeader(pgn, 'StudyRating', '$rating')
    : removePgnHeader(pgn, 'StudyRating');

String _withStudySummary(String pgn, String summary) => summary.isNotEmpty
    ? upsertPgnHeader(pgn, 'StudySummary', summary.replaceAll('"', "'"))
    : removePgnHeader(pgn, 'StudySummary');

/// [pgn] with `[name "value"]` set: an existing header of that name is
/// replaced in place, otherwise the header is inserted after the first line
/// (a PGN's first line is its `[Event]` header). A single-line [pgn] has no
/// header block to insert into and is returned unchanged.
String upsertPgnHeader(String pgn, String name, String value) {
  final header = '[$name "$value"]';
  final existing = _headerRe(name);
  if (existing.hasMatch(pgn)) return pgn.replaceFirst(existing, header);
  final firstNewline = pgn.indexOf('\n');
  if (firstNewline == -1) return pgn;
  return '${pgn.substring(0, firstNewline)}\n$header'
      '${pgn.substring(firstNewline)}';
}

/// [pgn] without its first `[name "..."]` header line, if any.
String removePgnHeader(String pgn, String name) =>
    pgn.replaceFirst(_headerLineRe(name), '');

RegExp _headerRe(String name) => RegExp('\\[$name\\s+"[^"]*"\\]');
RegExp _headerLineRe(String name) => RegExp('\\[$name\\s+"[^"]*"\\]\\n?');
