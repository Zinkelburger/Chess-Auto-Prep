/// Top-level helpers for whole-PGN-collection work (parsing, slicing,
/// metadata rewriting, protagonist detection) used by
/// `pgn_viewer_controller.dart`, which re-exports this library so existing
/// importers keep working.
library;

import 'dart:math' as math;

import '../../models/pgn_filter_models.dart';
import '../../models/pgn_game_entry.dart';
import '../../services/pgn_parsing_service.dart' as pgn;

// ---------------------------------------------------------------------------
// Top-level helpers used inside Isolate.run closures.
// Must NOT be class statics — Dart captures the enclosing class context
// when referencing static members from a closure, which pulls unsendable
// State/Widget objects into the isolate message.
// ---------------------------------------------------------------------------

List<PgnGameEntry> parseMultiGamePgn(String content) {
  final entries = <PgnGameEntry>[];
  final chunks = content.split(pgn.pgnChunkSplitRe);
  for (final chunk in chunks) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) continue;
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
  return entries;
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
