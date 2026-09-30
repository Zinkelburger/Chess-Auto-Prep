import 'package:dartchess/dartchess.dart' show Side;

import '../pgn/game_text.dart';
import '../pgn/pgn_chars.dart' show unescapedTagValue;

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

/// A game's time control, with [unknown] for a `TimeControl` header that
/// is missing or says nothing this can read.
///
/// Every speed filter in the app classifies with [timeClassOfTags] and
/// decides for itself what [unknown] does:
/// - My games and Tactics ([keepsSpeed]) and a player download
///   (`PlayerDownloadRange.keeps`) let it through: none of their choices
///   names it, so leaving it out would hide the game with no way back;
/// - Player analysis offers it as its own choice, Other.
enum TimeClass {
  bullet('Bullet'),
  blitz('Blitz'),
  rapid('Rapid'),
  classical('Classical'),
  correspondence('Correspondence'),
  unknown('Other');

  const TimeClass(this.label);

  final String label;
}

/// The class of a `TimeControl` header value, by base seconds plus forty
/// times the increment, sorted the way the game's site sorts it:
/// - a [lichess] game as Lichess (and the old app) does: under 3 minutes
///   bullet, UltraBullet included, under 8 blitz, under 25 rapid, else
///   classical — `300+5` is 500 seconds, rapid;
/// - any other game under 3 minutes bullet, under 10 blitz, under 30
///   rapid, else classical — `180+2` is 260 seconds, blitz. Chess.com's
///   `1800` is classical here, though that site calls it rapid.
///
/// A day-based control (Chess.com's `1/259200`) or none at all (Lichess's
/// `-`) is correspondence.
TimeClass timeClassOf(String? control, {bool lichess = false}) {
  final value = control?.trim() ?? '';
  if (value == '-' || value.contains('/')) return TimeClass.correspondence;
  final parts = value.split('+');
  final base = int.tryParse(parts.first);
  final increment = parts.length == 2 ? int.tryParse(parts[1]) : 0;
  if (parts.length > 2 || base == null || increment == null) {
    return TimeClass.unknown;
  }
  final seconds = base + 40 * increment;
  final (blitz, rapid) = lichess ? (480, 1500) : (600, 1800);
  return seconds <= 0
      ? TimeClass.unknown
      : seconds < 180
      ? TimeClass.bullet
      : seconds < blitz
      ? TimeClass.blitz
      : seconds < rapid
      ? TimeClass.rapid
      : TimeClass.classical;
}

/// The class of the game whose header values are [tags] ([timeClassOf]),
/// as Lichess sorts it when its `Site` or `Link` is a Lichess address.
TimeClass timeClassOfTags(Map<String, String> tags) => timeClassOf(
  tags['TimeControl'],
  lichess: _onLichess(tags['Site']) || _onLichess(tags['Link']),
);

/// The class of the game [gameText] ([timeClassOfTags]), read off its
/// header lines without replaying its moves.
TimeClass timeClassIn(String gameText) =>
    timeClassOfTags(_headerValues(gameText));

/// The time controls the user's games are sorted by, as the old app's
/// review offers them. Nothing slower is its own choice: a daily or
/// correspondence game counts as classical.
enum GameSpeed {
  bullet('Bullet'),
  blitz('Blitz'),
  rapid('Rapid'),
  classical('Classical');

  const GameSpeed(this.label);

  final String label;
}

/// The speed of the game [gameText] by its headers ([timeClassIn]), or
/// null when it does not say.
GameSpeed? speedIn(String gameText) => switch (timeClassIn(gameText)) {
  TimeClass.bullet => GameSpeed.bullet,
  TimeClass.blitz => GameSpeed.blitz,
  TimeClass.rapid => GameSpeed.rapid,
  TimeClass.classical || TimeClass.correspondence => GameSpeed.classical,
  TimeClass.unknown => null,
};

/// Whether a filter of [speeds] lets the game [gameText] through. A game
/// that does not say its time control is let through ([TimeClass.unknown]).
bool keepsSpeed(Set<GameSpeed> speeds, String gameText) {
  final speed = speedIn(gameText);
  return speed == null || speeds.contains(speed);
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

/// The header values of [gameText], the first of each name winning, read
/// as the PGN reader reads them: `\"` a quote and `\\` a backslash.
Map<String, String> _headerValues(String gameText) {
  final values = <String, String>{};
  for (final match in _header.allMatches(gameText)) {
    values.putIfAbsent(match[1]!, () => unescapedTagValue(match[2]!).trim());
  }
  return values;
}

final _lichessPath = RegExp(
  r'^/([a-zA-Z0-9]{8})([a-zA-Z0-9]{4})?(/(white|black))?$',
);
final _chesscomPath = RegExp(r'^/game/(live|daily)/([0-9]+)/?$');

/// The web address [address], when it is one, and its host without `www.`.
(Uri, String)? _webAddress(String? address) {
  final uri = Uri.tryParse(address ?? '');
  if (uri == null || !const ['https', 'http'].contains(uri.scheme)) {
    return null;
  }
  return (uri, uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), ''));
}

/// Whether [address] is on Lichess.
bool _onLichess(String? address) => _webAddress(address)?.$2 == 'lichess.org';

/// The id of the game at [address] when it is a Lichess or Chess.com game;
/// a tournament's address is shared by many games and names none.
String? _siteGameId(String? address) {
  final web = _webAddress(address);
  if (web == null) return null;
  final (uri, host) = web;
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
