/// Stable identity for a stored game: which URL or hash the game is keyed by.
library;

import 'dart:convert';

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:crypto/crypto.dart';

/// A Lichess game path: the 8-char game id, optionally followed by the
/// 4-char player suffix and/or a `/white` or `/black` orientation.
final RegExp _lichessGamePath = RegExp(
  r'^/[a-zA-Z0-9]{8}([a-zA-Z0-9]{4})?(/(white|black))?$',
);

/// A chess.com live or daily game path.
final RegExp _chesscomGamePath = RegExp(r'^/game/(live|daily)/[0-9]+/?$');

/// Length of a Lichess game id, the part of the path that identifies a game.
const int _lichessGameIdLength = 8;

/// Headers that, with the date, time and moves, identify a game that has no
/// platform URL and no `GameId` of its own.
const List<String> _identityHeaders = [
  'Event',
  'Site',
  'Round',
  'White',
  'Black',
  'FEN',
  'Variant',
  'TimeControl',
];

/// Only actual game endpoints are identity-bearing URLs. A tournament's Site
/// URL is shared by many games and must never be used as an upsert key.
///
/// Returns the canonical game URL, or null when [value] is not one.
String? platformGameUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null || !const ['https', 'http'].contains(uri.scheme)) {
    return null;
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  if (host == 'lichess.org' && _lichessGamePath.hasMatch(uri.path)) {
    return 'https://lichess.org/'
        '${uri.path.substring(1, 1 + _lichessGameIdLength)}';
  }
  if (host == 'chess.com' && _chesscomGamePath.hasMatch(uri.path)) {
    return 'https://www.chess.com${uri.path.replaceFirst(RegExp(r'/$'), '')}';
  }
  return null;
}

/// The key a game is stored and de-duplicated under.
///
/// In priority order: the `GameId` header this app writes at import (unless
/// [preferHeaderId] is false), a platform game URL from `Link` or `Site`,
/// then the header id anyway, and finally a hash of the identifying headers
/// and the mainline moves.
String canonicalGameKey(
  Map<String, String> headers,
  String pgn, {
  bool preferHeaderId = true,
}) {
  final id = headers['GameId'];
  final headerId = id == null || id.isEmpty ? null : id;
  if (preferHeaderId && headerId != null) return headerId;
  final url =
      platformGameUrl(headers['Link']) ?? platformGameUrl(headers['Site']);
  if (url != null) return url;
  if (headerId != null) return headerId;
  return 'pgn-v2:${_contentDigest(headers, pgn)}';
}

String _contentDigest(Map<String, String> headers, String pgn) {
  String moves;
  try {
    moves = parsePgnGame(pgn).moves.mainline().map((m) => m.san).join(' ');
  } catch (_) {
    // An unreadable game must not collide with another unreadable record.
    moves = pgn.trim();
  }
  final identity = [
    for (final name in _identityHeaders) headers[name]?.trim() ?? '',
    headers['UTCDate'] ?? headers['Date'] ?? '',
    headers['UTCTime'] ?? headers['Time'] ?? '',
    moves,
  ];
  return sha256.convert(utf8.encode(jsonEncode(identity))).toString();
}
