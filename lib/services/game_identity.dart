import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart';

/// Only actual game endpoints are identity-bearing URLs. A tournament's Site
/// URL is shared by many games and must never be used as an upsert key.
String? platformGameUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null || !['https', 'http'].contains(uri.scheme)) return null;
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  if (host == 'lichess.org' &&
      RegExp(
        r'^/[a-zA-Z0-9]{8}([a-zA-Z0-9]{4})?(/(white|black))?$',
      ).hasMatch(uri.path)) {
    return 'https://lichess.org/${uri.path.substring(1, 9)}';
  }
  if (host == 'chess.com' &&
      RegExp(r'^/game/(live|daily)/[0-9]+/?$').hasMatch(uri.path)) {
    return 'https://www.chess.com${uri.path.replaceFirst(RegExp(r'/$'), '')}';
  }
  return null;
}

String canonicalGameKey(
  Map<String, String> headers,
  String pgn, {
  bool preferHeaderId = true,
}) {
  final id = headers['GameId'];
  if (preferHeaderId && id != null && id.isNotEmpty) return id;
  final url =
      platformGameUrl(headers['Link']) ?? platformGameUrl(headers['Site']);
  if (url != null) return url;
  if (id != null && id.isNotEmpty) return id;
  String moves;
  try {
    moves = PgnGame.parsePgn(pgn).moves.mainline().map((m) => m.san).join(' ');
  } catch (_) {
    // An unreadable game must not collide with another unreadable record.
    moves = pgn.trim();
  }
  final identity = [
    for (final name in [
      'Event',
      'Site',
      'Round',
      'White',
      'Black',
      'FEN',
      'Variant',
      'TimeControl',
    ])
      headers[name]?.trim() ?? '',
    headers['UTCDate'] ?? headers['Date'] ?? '',
    headers['UTCTime'] ?? headers['Time'] ?? '',
    moves,
  ];
  return 'pgn-v2:${sha256.convert(utf8.encode(jsonEncode(identity)))}';
}
