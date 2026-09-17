/// Top-level helpers for whole-PGN-collection work (slicing,
/// metadata rewriting, protagonist detection) used by
/// `pgn_viewer_controller.dart`, which re-exports this library so existing
/// importers keep working.
library;

import '../../chess_core/pgn/pgn_collection.dart';
import '../../models/pgn_game_entry.dart';
import '../../services/games_library/game_filter.dart' show dedupKeyForHeaders;
import '../../chess_core/pgn/pgn_text.dart' as pgn;

/// The file as it now stands on disk, with only the games *we* changed
/// substituted into it — the write to use when the file moved under us.
///
/// A viewer save rewrites the whole file from the collection in memory, which
/// is correct only while that memory is the newest copy. It is not, whenever
/// something else has written to the file since it was loaded: the app's own
/// review runner patches the games cache in place ([GamesLibraryService
/// .patchGameMovetexts]), and a reader can have the file open in an editor.
/// Rewriting from memory then silently reverts everything that arrived in
/// between — a star discarding an hour of engine review.
///
/// [gameTexts] is every game as we hold it, in collection order; [edited]
/// names the ones this session actually changed. Everything else comes from
/// [diskContent] verbatim, including its banner, its game order, and any game
/// we have never seen.
///
/// The merge only ever *substitutes*: nothing on disk is dropped, reordered,
/// or appended to. A game we cannot place unambiguously keeps the disk copy
/// and is named in [unplaced] — losing a star beats corrupting a file whose
/// shape we no longer recognise. Returns null when [diskContent] holds no
/// games at all, which is not a file this merge understands.
String? mergeEditedGamesIntoDiskCopy({
  required String diskContent,
  required List<String> gameTexts,
  required Set<int> edited,
  List<int>? unplaced,
}) {
  final chunks = pgn.splitPgnIntoGames(diskContent);
  if (chunks.isEmpty) return null;

  String keyOf(String gameText) =>
      dedupKeyForHeaders(pgn.extractHeaders(gameText));

  final diskKeys = [for (final c in chunks) keyOf(c)];

  // Same number of games, and the game at each edited index is still the game
  // we edited: the shape did not change, only the text inside it. This is the
  // case the review runner produces, and it needs no identity lookup at all.
  final sameShape = chunks.length == gameTexts.length;

  for (final index in edited) {
    if (index < 0 || index >= gameTexts.length) continue;
    final ours = gameTexts[index];
    final key = keyOf(ours);

    if (sameShape && (key.isEmpty || diskKeys[index] == key)) {
      chunks[index] = ours;
      continue;
    }

    // The shape moved. Place the game only where its identity is unambiguous
    // on both sides — one game on disk with that key, and one of ours.
    final matches = [
      for (var i = 0; i < diskKeys.length; i++)
        if (diskKeys[i] == key) i,
    ];
    final ourMatches = [
      for (var i = 0; i < gameTexts.length; i++)
        if (keyOf(gameTexts[i]) == key) i,
    ];
    if (key.isEmpty || matches.length != 1 || ourMatches.length != 1) {
      unplaced?.add(index);
      continue;
    }
    chunks[matches.single] = ours;
  }

  final preamble = pgnCollectionPreamble(diskContent);
  final body = [for (final c in chunks) c.trim()].join('\n\n');
  return preamble.isEmpty ? '$body\n' : '$preamble\n\n$body\n';
}

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
