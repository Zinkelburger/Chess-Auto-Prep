/// Header-level PGN helpers for the tactics import: game identity, date
/// filtering and the player's rating. Pure text functions, no engine.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:flutter/foundation.dart';

import 'package:chess_auto_prep/chess_core/pgn/game_identity.dart'
    show platformGameUrl;
import '../../../chess_core/pgn/pgn_text.dart' show extractHeaders;
import '../../../utils/log.dart';

/// GameId prefix for games fetched from Lichess.
const String lichessGameIdPrefix = 'lichess_';

/// GameId prefix for games fetched from Chess.com.
const String chesscomGameIdPrefix = 'chesscom_';

final _dateHeaderRe = RegExp(
  r'\[(?:Date|UTCDate) "(\d{4})\.(\d{2})\.(\d{2})"\]',
);
final _gameIdHeaderRe = RegExp(r'\[GameId "([^"]+)"\]');

/// Whether the game's `Date`/`UTCDate` header is before [cutoff] (day
/// granularity). Games without a parseable date pass the filter — better
/// to analyze one game too many than silently drop it.
bool isGameBefore(String gameText, DateTime cutoff) {
  final match = _dateHeaderRe.firstMatch(gameText);
  if (match == null) return false;
  final gameDate = DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
  return gameDate.isBefore(DateTime(cutoff.year, cutoff.month, cutoff.day));
}

/// Whether [gameId] carries one of the platform prefixes this import writes.
bool hasPlatformGameIdPrefix(String gameId) =>
    gameId.startsWith(lichessGameIdPrefix) ||
    gameId.startsWith(chesscomGameIdPrefix);

/// The game's identity from its PGN headers, or an empty string when none
/// can be determined — such a game is analyzed every time (safe fallback).
///
/// Lichess provides the game URL in the `Site` header, Chess.com in `Link`.
/// Both APIs always include one of these, so only those two sources are
/// handled (plus our own injected `GameId` header).
///
/// Always returns a platform-prefixed ID ([lichessGameIdPrefix] /
/// [chesscomGameIdPrefix]) — the resume path routes games to the right
/// username by that prefix, so an unprefixed ID would make a game
/// unresumable.
String extractGameId(String gameText) {
  // A GameId header — ours from a previous import, or Lichess's own: their
  // PGN exports natively carry the bare game ID in [GameId]. Only trust it
  // as-is when it already has a platform prefix.
  final rawHeaderId = _gameIdHeaderRe.firstMatch(gameText)?.group(1);
  if (rawHeaderId != null && hasPlatformGameIdPrefix(rawHeaderId)) {
    return rawHeaderId;
  }

  // Only recognized game URLs carry identity. Tournament and other shared
  // website links must not collapse several source games into one record.
  final headers = extractHeaders(gameText);
  final url =
      platformGameUrl(headers['Link']) ?? platformGameUrl(headers['Site']);
  if (url != null) {
    final uri = Uri.parse(url);
    return uri.host == 'lichess.org'
        ? '$lichessGameIdPrefix${uri.pathSegments.first}'
        : '$chesscomGameIdPrefix${uri.pathSegments.last}';
  }

  // A bare GameId header with no Site/Link to attribute it — only Lichess
  // emits a native GameId header, so prefix accordingly.
  if (rawHeaderId != null && rawHeaderId.isNotEmpty) {
    return '$lichessGameIdPrefix$rawHeaderId';
  }

  if (kDebugMode) {
    log.w('Warning: could not extract game ID from PGN headers');
  }
  return '';
}

/// [gameText] with a `[GameId]` header added when it has none and one can
/// be derived (see [extractGameId]); otherwise the text unchanged.
///
/// The header goes right after the last header line when the movetext
/// follows it directly, else just before the first movetext line.
String injectGameIdHeader(String gameText) {
  if (gameText.contains('[GameId ')) return gameText;
  final gameId = extractGameId(gameText);
  if (gameId.isEmpty) return gameText;

  final lines = gameText.split('\n');
  final insertAt = _gameIdInsertionIndex(lines);
  if (insertAt == null) return gameText;
  lines.insert(insertAt, '[GameId "$gameId"]');
  return lines.join('\n');
}

bool _isHeaderLine(String line) {
  final trimmed = line.trim();
  return trimmed.startsWith('[') && trimmed.endsWith(']');
}

bool _isMovetextLine(String line) {
  final trimmed = line.trim();
  return trimmed.isNotEmpty && !trimmed.startsWith('[');
}

/// Index at which to insert the GameId header, or null when [lines] hold no
/// movetext at all.
int? _gameIdInsertionIndex(List<String> lines) {
  for (var i = 0; i + 1 < lines.length; i++) {
    if (_isHeaderLine(lines[i]) && _isMovetextLine(lines[i + 1])) {
      return i + 1;
    }
  }
  final firstMovetext = lines.indexWhere(_isMovetextLine);
  return firstMovetext == -1 ? null : firstMovetext;
}

/// The Elo of the side whose name matches [username] (case-insensitive),
/// from the game's `WhiteElo` / `BlackElo` header. Null when the user is not
/// a player in the game or the header is missing or unparseable.
int? extractUserElo(String gameText, String username) {
  final game = parsePgnGame(gameText);
  final white = (game.headers['White'] ?? '').toLowerCase();
  final black = (game.headers['Black'] ?? '').toLowerCase();
  final wanted = username.toLowerCase();

  final eloHeader = white == wanted
      ? game.headers['WhiteElo']
      : black == wanted
      ? game.headers['BlackElo']
      : null;
  if (eloHeader == null) return null;
  return int.tryParse(eloHeader.replaceAll('?', ''));
}
