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

/// The Lichess "export games by user" URL with [username] safely encoded as a
/// single path segment. [params] becomes the query string.
Uri lichessUserGamesUrl(String username, Map<String, String> params) {
  return Uri.parse(
    'https://lichess.org/api/games/user/${Uri.encodeComponent(username)}',
  ).replace(queryParameters: params.isEmpty ? null : params);
}

/// The Chess.com "monthly archives list" URL for [username] (lowercased per the
/// Chess.com convention, then encoded as a single path segment).
Uri chesscomArchivesUrl(String username) {
  return Uri.parse(
    'https://api.chess.com/pub/player/'
    '${Uri.encodeComponent(username.toLowerCase())}/games/archives',
  );
}
