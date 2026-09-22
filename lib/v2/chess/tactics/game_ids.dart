import 'package:dartchess/dartchess.dart' show Side;

import '../pgn/game_text.dart';

/// Where a game of the user's was downloaded from. The names are the old
/// app's: they are in its cache file names and its game ids.
enum GameSite {
  lichess('Lichess'),
  chesscom('Chess.com');

  const GameSite(this.label);

  /// How a person names the site.
  final String label;
}

/// The id both apps file a downloaded game under — `lichess_AbCd1234`,
/// `chesscom_173321420294` — read off its header lines, or an empty string
/// when it has none, in which case nothing can say it was reviewed.
///
/// In the old app's order: a `GameId` that already has a site's prefix,
/// then the game's address in `Link` or `Site`, then a bare `GameId`, which
/// only Lichess writes.
String gameIdIn(String gameText) {
  final tags = _headerValues(gameText);
  final own = tags['GameId'];
  if (own != null && GameSite.values.any((s) => own.startsWith('${s.name}_'))) {
    return own;
  }
  final address = _siteGameId(tags['Link']) ?? _siteGameId(tags['Site']);
  if (address != null) return address;
  return own == null || own.isEmpty ? '' : '${GameSite.lichess.name}_$own';
}

/// When the game was played, as text that sorts: `2026.08.21 15:17:30`.
/// A game that does not say sorts first.
String playedAt(String gameText) {
  final tags = _headerValues(gameText);
  final day = tags['UTCDate'] ?? tags['Date'] ?? '';
  return '$day ${tags['UTCTime'] ?? ''}'.trim();
}

/// The side [username] played in the game whose headers are [tags], or
/// null when neither player is them. Exact, ignoring case: a substring
/// would take user "tal" for their opponent "talinda".
Side? sideOf(List<PgnHeader> tags, String username) {
  final wanted = username.trim().toLowerCase();
  if (wanted.isEmpty) return null;
  if (tagValue(tags, 'White')?.trim().toLowerCase() == wanted) {
    return Side.white;
  }
  if (tagValue(tags, 'Black')?.trim().toLowerCase() == wanted) {
    return Side.black;
  }
  return null;
}

/// Whether the game is played by the ordinary rules, from the usual start
/// or a set-up position; Chess960 and the other variants are not reviewed.
bool isStandardChess(List<PgnHeader> tags) {
  final variant = tagValue(tags, 'Variant')?.trim().toLowerCase() ?? '';
  return const {'', 'standard', 'from position'}.contains(variant);
}

final _header = RegExp(
  r'^\s*\[(\w+)\s+"((?:[^"\\]|\\.)*)"\s*\]',
  multiLine: true,
);

/// The header values of [gameText], the first of each name winning.
Map<String, String> _headerValues(String gameText) {
  final values = <String, String>{};
  for (final match in _header.allMatches(gameText)) {
    values.putIfAbsent(match[1]!, () => match[2]!.trim());
  }
  return values;
}

final _lichessPath = RegExp(
  r'^/([a-zA-Z0-9]{8})([a-zA-Z0-9]{4})?(/(white|black))?$',
);
final _chesscomPath = RegExp(r'^/game/(live|daily)/([0-9]+)/?$');

/// The id of the game at [address] when it is a Lichess or Chess.com game;
/// a tournament's address is shared by many games and names none.
String? _siteGameId(String? address) {
  final uri = Uri.tryParse(address ?? '');
  if (uri == null || !const ['https', 'http'].contains(uri.scheme)) {
    return null;
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  if (host == 'lichess.org') {
    final id = _lichessPath.firstMatch(uri.path)?[1];
    return id == null ? null : '${GameSite.lichess.name}_$id';
  }
  if (host == 'chess.com') {
    final id = _chesscomPath.firstMatch(uri.path)?[2];
    return id == null ? null : '${GameSite.chesscom.name}_$id';
  }
  return null;
}
