/// Top-level helpers for whole-PGN-collection work (parsing, slicing,
/// metadata rewriting, protagonist detection) used by
/// `pgn_viewer_controller.dart`, which re-exports this library so existing
/// importers keep working.
library;

import 'dart:math' as math;

import '../../models/pgn_filter_models.dart';
import '../../models/pgn_game_entry.dart';
import '../../services/games_library/game_filter.dart' show dedupKeyForHeaders;
import '../../services/pgn_parsing_service.dart' as pgn;

// ---------------------------------------------------------------------------
// Top-level helpers used inside Isolate.run closures.
// Must NOT be class statics — Dart captures the enclosing class context
// when referencing static members from a closure, which pulls unsendable
// State/Widget objects into the isolate message.
// ---------------------------------------------------------------------------

List<PgnGameEntry> parseMultiGamePgn(String content) {
  final entries = <PgnGameEntry>[];
  for (final chunk in pgn.splitPgnIntoGames(content)) {
    _addChunk(entries, chunk);
  }
  return entries;
}

/// Offset of the next `[Event ` that begins a line strictly after [from]
/// (so the chunk starting at [from] is never empty), or null.
int? _nextChunkBoundary(String content, int from) {
  var search = from + 1;
  while (true) {
    final idx = content.indexOf('[Event ', search);
    if (idx < 0) return null;
    if (idx > 0 && content.codeUnitAt(idx - 1) == 0x0A) return idx;
    search = idx + 1;
  }
}

void _addChunk(List<PgnGameEntry> entries, String chunk) {
  final trimmed = chunk.trim();
  if (trimmed.isEmpty) return;
  // A comment-only chunk (e.g. a `;`-comment banner before the first
  // `[Event` header, as in chessgames.com collection downloads) is not a
  // game; without this it would surface as a blank extra game.
  if (_isCommentOnly(trimmed)) return;
  final headers = pgn.extractHeaders(trimmed);
  final rating = int.tryParse(headers['StudyRating'] ?? '') ?? 0;
  entries.add(
    PgnGameEntry(
      headers: headers,
      pgnText: trimmed,
      studyRating: rating.clamp(0, 5),
      studySummary: headers['StudySummary'] ?? '',
    ),
  );
}

/// The text above the first game that [parseMultiGamePgn] does not hand back
/// as a game: a `;` or `%` banner, the shape chessgames.com collection
/// downloads arrive in.
///
/// It has to be kept somewhere, because the only copy of a collection the app
/// holds is its list of games, and `doPersistMetadata` rewrites the whole file
/// from that list. A star, a comment edit or an engine review therefore wrote
/// the file back *without* the banner — text the reader wrote, deleted by an
/// edit that had nothing to do with it. Returned trimmed, empty when there is
/// none.
String pgnCollectionPreamble(String content) {
  final head = content.substring(
    0,
    _nextChunkBoundary(content, 0) ?? content.length,
  );
  final trimmed = head.trim();
  if (trimmed.isEmpty || !_isCommentOnly(trimmed)) return '';
  return trimmed;
}

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

/// Whether every line of [text] is blank or a top-level comment line.  Stops
/// at the first line that is neither, so a real game is settled by its
/// first header rather than a scan of all its lines.
bool _isCommentOnly(String text) {
  var lineStart = 0;
  while (lineStart <= text.length) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    final line = text.substring(lineStart, lineEnd).trim();
    if (line.isNotEmpty && !pgn.isPgnCommentLine(line)) return false;
    lineStart = lineEnd + 1;
  }
  return true;
}

Future<List<int>> applySliceConfig(
  SliceConfig config,
  List<GameRecord> games, {
  Map<String, List<int>>? fenIndex,
}) {
  final seqPattern = config.sequencePattern;
  return pgn.computeSliceMatches(
    games: games,
    targetFen: pgn.parseTargetFen(config.positionInput),
    filters: config.headerFilters
        .map((f) => (field: f.field, mode: f.mode, value: f.value))
        .toList(),
    seqGroups: (seqPattern != null && seqPattern.isNotEmpty)
        ? pgn.parseSequenceGroups(seqPattern)
        : const [],
    seqGap: config.sequenceGap,
    fenIndex: fenIndex,
  );
}

final studyRatingRe = RegExp(r'\[StudyRating\s+"[^"]*"\]');
final studyRatingLineRe = RegExp(r'\[StudyRating\s+"[^"]*"\]\n?');
final studySummaryRe = RegExp(r'\[StudySummary\s+"[^"]*"\]');
final studySummaryLineRe = RegExp(r'\[StudySummary\s+"[^"]*"\]\n?');

List<String> buildMetadataOutput(
  List<({String pgn, int rating, String summary})> gameData,
) {
  final results = <String>[];
  for (final game in gameData) {
    var pgn = game.pgn;

    if (game.rating > 0) {
      if (studyRatingRe.hasMatch(pgn)) {
        pgn = pgn.replaceFirst(studyRatingRe, '[StudyRating "${game.rating}"]');
      } else {
        final firstNewline = pgn.indexOf('\n');
        if (firstNewline != -1) {
          pgn =
              '${pgn.substring(0, firstNewline)}\n[StudyRating "${game.rating}"]${pgn.substring(firstNewline)}';
        }
      }
    } else {
      pgn = pgn.replaceFirst(studyRatingLineRe, '');
    }

    if (game.summary.isNotEmpty) {
      final escaped = game.summary.replaceAll('"', "'");
      if (studySummaryRe.hasMatch(pgn)) {
        pgn = pgn.replaceFirst(studySummaryRe, '[StudySummary "$escaped"]');
      } else {
        final firstNewline = pgn.indexOf('\n');
        if (firstNewline != -1) {
          pgn =
              '${pgn.substring(0, firstNewline)}\n[StudySummary "$escaped"]${pgn.substring(firstNewline)}';
        }
      }
    } else {
      pgn = pgn.replaceFirst(studySummaryLineRe, '');
    }

    results.add(pgn);
  }
  return results;
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

String? detectProtagonistFrom(List<PgnGameEntry> games) {
  if (games.length < 2) return null;
  final sample = games.take(math.min(4, games.length));
  final counts = <String, int>{};
  for (final g in sample) {
    final w = g.headers['White'];
    final b = g.headers['Black'];
    if (w != null && w.isNotEmpty && w != '?') {
      counts[w] = (counts[w] ?? 0) + 1;
    }
    if (b != null && b.isNotEmpty && b != '?') {
      counts[b] = (counts[b] ?? 0) + 1;
    }
  }
  final sampleSize = sample.length;
  for (final entry in counts.entries) {
    if (entry.value >= sampleSize) return entry.key;
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
  final sample = games.take(math.min(6, games.length)).toList();
  final counts = <String, int>{};
  for (final g in sample) {
    final w = g.headers['White'];
    final b = g.headers['Black'];
    if (w != null && w.isNotEmpty && w != '?') {
      counts[w] = (counts[w] ?? 0) + 1;
    }
    if (b != null && b.isNotEmpty && b != '?') {
      counts[b] = (counts[b] ?? 0) + 1;
    }
  }
  final sampleSize = sample.length;
  final recurring = counts.entries
      .where((e) => e.value >= sampleSize)
      .map((e) => e.key)
      .toList();
  if (recurring.length < 2) return null;
  // Return with the player who appears as White more often listed first.
  int whiteCount(String name) =>
      sample.where((g) => g.headers['White'] == name).length;
  recurring.sort((a, b) => whiteCount(b).compareTo(whiteCount(a)));
  return (player1: recurring[0], player2: recurring[1]);
}
