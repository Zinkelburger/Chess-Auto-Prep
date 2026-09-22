import '../../models/pgn_game_entry.dart';

/// Detect the player a whole collection is "about" by scanning every game's
/// White/Black headers. Counts by surname (text before the first comma) so
/// "Kasparov, Garry" and "Kasparov, G." pool together. Returns the surname
/// when one player appears in ≥80% of the games.
String? detectFileProtagonist(List<PgnGameEntry> games) {
  if (games.length < 2) return null;
  final counts = <String, int>{};
  for (final g in games) {
    final seen = <String>{};
    for (final key in const ['White', 'Black']) {
      final name = (g.headers[key] ?? '').trim();
      if (name.isEmpty || name == '?') continue;
      final surname = name.split(',').first.trim();
      if (surname.isEmpty || !seen.add(surname)) continue;
      counts[surname] = (counts[surname] ?? 0) + 1;
    }
  }
  String? best;
  var bestCount = 0;
  counts.forEach((name, c) {
    if (c > bestCount) {
      best = name;
      bestCount = c;
    }
  });
  if (bestCount < (games.length * 0.8).ceil()) return null;
  return best;
}

/// A single player present in at least 80% of the complete collection.
/// Full PGN names (case-insensitive) keep different players with the same
/// surname distinct. A two-player match has no unambiguous collection player.
String? detectSingleCollectionPlayer(List<PgnGameEntry> games) {
  if (games.length < 2) return null;
  final counts = <String, int>{};
  final names = <String, String>{};
  for (final game in games) {
    final seen = <String>{};
    for (final field in const ['White', 'Black']) {
      final name = (game.headers[field] ?? '').trim();
      if (name.isEmpty || name == '?') continue;
      final key = name.toLowerCase();
      names.putIfAbsent(key, () => name);
      if (seen.add(key)) counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  final threshold = (games.length * .8).ceil();
  final candidates = counts.keys.where((name) => counts[name]! >= threshold);
  return candidates.length == 1 ? names[candidates.single] : null;
}

/// A player named in every game of the first four: the quick guess used
/// while a collection is still loading. Null when none recurs.
String? detectProtagonistFrom(List<PgnGameEntry> games) {
  if (games.length < 2) return null;
  final sample = games.take(_protagonistSampleSize).toList();
  final counts = _playerCounts(sample);
  for (final MapEntry(key: name, value: count) in counts.entries) {
    if (count >= sample.length) return name;
  }
  return null;
}

/// Returns both player names when every game in the sample is between the
/// same two players (order: most-frequent-as-White first). Returns null if
/// only one (or no) recurring player is found.
({String player1, String player2})? detectBothPlayersFrom(
  List<PgnGameEntry> games,
) {
  if (games.length < 2) return null;
  final sample = games.take(_bothPlayersSampleSize).toList();
  final counts = _playerCounts(sample);
  final recurring = [
    for (final MapEntry(key: name, value: count) in counts.entries)
      if (count >= sample.length) name,
  ];
  if (recurring.length < 2) return null;
  int whiteCount(String name) =>
      sample.where((g) => g.headers['White'] == name).length;
  recurring.sort((a, b) => whiteCount(b).compareTo(whiteCount(a)));
  return (player1: recurring[0], player2: recurring[1]);
}

const _protagonistSampleSize = 4;
const _bothPlayersSampleSize = 6;

/// How many games of [sample] each named player takes part in, by exact
/// header spelling, in first-seen order.
Map<String, int> _playerCounts(List<PgnGameEntry> sample) {
  final counts = <String, int>{};
  for (final game in sample) {
    for (final field in const ['White', 'Black']) {
      final name = game.headers[field];
      if (name == null || name.isEmpty || name == '?') continue;
      counts[name] = (counts[name] ?? 0) + 1;
    }
  }
  return counts;
}
