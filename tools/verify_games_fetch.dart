/// Manual verification: hit the real Chess.com + Lichess game endpoints and
/// run the shared filter over the results. Not part of the test suite (needs
/// network). Run: `dart run tools/verify_games_fetch.dart`.
library;

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:chess_auto_prep/services/games_library/game_filter.dart';

Future<String> fetchChesscom(String user) async {
  final arch = await http.get(Uri.parse(
      'https://api.chess.com/pub/player/${user.toLowerCase()}/games/archives'));
  if (arch.statusCode != 200) return '';
  final urls = List<String>.from(
      (json.decode(arch.body) as Map<String, dynamic>)['archives'] as List);
  if (urls.isEmpty) return '';
  final last = await http.get(Uri.parse(urls.last));
  if (last.statusCode != 200) return '';
  final games = (json.decode(last.body) as Map<String, dynamic>)['games']
      as List<dynamic>;
  return games
      .map((g) => (g as Map<String, dynamic>)['pgn'] as String? ?? '')
      .where((p) => p.isNotEmpty)
      .join('\n\n');
}

Future<String> fetchLichess(String user) async {
  final resp = await http.get(
    Uri.parse('https://lichess.org/api/games/user/$user?max=20'),
    headers: {'Accept': 'application/x-chess-pgn'},
  );
  return resp.statusCode == 200 ? resp.body : '';
}

void report(String label, String pgn) {
  final records = parseGameRecords(pgn);
  final blitzRapid = applySelection(
    records,
    const GameSelection(maxGames: 10, speeds: {GameSpeed.blitz, GameSpeed.rapid}),
  );
  print('── $label ──');
  print('  raw games parsed : ${records.length}');
  final speeds = <GameSpeed, int>{};
  for (final r in records) {
    speeds[r.speed] = (speeds[r.speed] ?? 0) + 1;
  }
  print('  speed histogram  : $speeds');
  final dated = records.where((r) => r.date != null).length;
  print('  with parsed date : $dated / ${records.length}');
  print('  after blitz/rapid + max 10 (newest first): ${blitzRapid.length}');
  if (blitzRapid.isNotEmpty) {
    final r = blitzRapid.first;
    print('  newest kept      : ${r.white} vs ${r.black}  '
        '${r.date?.toIso8601String()}  ${r.speed.name}');
  }
}

Future<void> main() async {
  try {
    report('Chess.com (hikaru)', await fetchChesscom('hikaru'));
  } catch (e) {
    print('Chess.com fetch failed: $e');
  }
  try {
    report('Lichess (DrNykterstein)', await fetchLichess('DrNykterstein'));
  } catch (e) {
    print('Lichess fetch failed: $e');
  }
}
