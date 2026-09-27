/// The headers a request to Lichess carries, in one place.
///
/// Lichess asks the programs that use its API to say who they are; one set
/// of headers for every Lichess client keeps each of them saying it, where
/// headers built client by client left all but one anonymous.
library;

/// Who is asking, as the sites want to know.
const appUserAgent = 'ChessAutoPrep (+https://chessautoprep.com)';

/// The headers of one request to Lichess: who is asking, the [accept]ed
/// type when the answer's type matters, and the user's [token] when they
/// have connected one, which is never logged.
Map<String, String> lichessHeaders({String? token, String? accept}) => {
  'User-Agent': appUserAgent,
  'Accept': ?accept,
  if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
};
