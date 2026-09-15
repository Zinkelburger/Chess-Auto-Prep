/// Safe URL builders for the Lichess / Chess.com public APIs.
///
/// Usernames reach these functions straight from user input (a text field, a
/// pasted string, an imported file's headers). Interpolating a raw username
/// into a URL is a path-traversal hazard: a value like `a/../../admin` would,
/// after [Uri]'s dot-segment normalization, redirect the request to a *different
/// endpoint* (e.g. `/api/games/admin` instead of `/api/games/user/<name>`), and
/// a `?`/`#` could inject or truncate the query. Encoding the username with
/// [Uri.encodeComponent] keeps it a single, literal path segment for every
/// input, so the target path and query are always exactly what we intend. The
/// host is fixed by the literal prefix and can never be redirected.
///
/// Legit usernames (`[A-Za-z0-9_-]`, plus `.`) are unchanged by the encoding,
/// so this is a no-op for normal input and a hard boundary for hostile input.
library;

/// [url] with [params] as its query string; no `?` at all when empty.
Uri _withQuery(String url, Map<String, String> params) =>
    Uri.parse(url).replace(queryParameters: params.isEmpty ? null : params);

/// The Lichess "export games by user" URL with [username] safely encoded as a
/// single path segment. [params] becomes the query string.
Uri lichessUserGamesUrl(String username, Map<String, String> params) =>
    _withQuery(
      'https://lichess.org/api/games/user/${Uri.encodeComponent(username)}',
      params,
    );

/// The Chess.com "monthly archives list" URL for [username] (lowercased per the
/// Chess.com convention, then encoded as a single path segment).
Uri chesscomArchivesUrl(String username) => Uri.parse(
  'https://api.chess.com/pub/player/'
  '${Uri.encodeComponent(username.toLowerCase())}/games/archives',
);

/// The Lichess study PGN export URL — the whole study, or one [chapterId].
///
/// Ids are validated as `[A-Za-z0-9]{8}` when the URL is parsed, so encoding
/// here is belt-and-braces; it costs nothing and keeps every id a single path
/// segment no matter where the caller got it.
Uri lichessStudyPgnUrl(
  String studyId,
  Map<String, String> params, {
  String? chapterId,
}) {
  final path = chapterId == null
      ? '${Uri.encodeComponent(studyId)}.pgn'
      : '${Uri.encodeComponent(studyId)}/${Uri.encodeComponent(chapterId)}.pgn';
  return _withQuery('https://lichess.org/api/study/$path', params);
}

/// The "export every study by this user" PGN URL, [username] safely encoded.
Uri lichessStudiesByUserUrl(String username, Map<String, String> params) =>
    _withQuery(
      'https://lichess.org/api/study/by/'
      '${Uri.encodeComponent(username)}/export.pgn',
      params,
    );

/// The chessgames.com collection page (the HTML we scrape game ids from).
Uri chessgamesCollectionUrl(String cid) =>
    _withQuery('https://www.chessgames.com/perl/chesscollection', {'cid': cid});

/// The chessgames.com single-game PGN endpoint for [gid].
Uri chessgamesPgnUrl(String gid) => Uri.parse(
  'https://www.chessgames.com/njs/api/game/viewPGN/'
  '${Uri.encodeComponent(gid)}',
);

/// The chessgames.com human-facing game page — sent as the `Referer` for
/// [chessgamesPgnUrl], which the API expects.
Uri chessgamesGameUrl(String gid) =>
    _withQuery('https://www.chessgames.com/perl/chessgame', {'gid': gid});
