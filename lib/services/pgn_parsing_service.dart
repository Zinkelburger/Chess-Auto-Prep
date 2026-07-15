/// Centralized PGN parsing utilities.
///
/// Intentional barrel: re-exports [pgn_filter_models] for callers that
/// import parsing helpers and filter types from one place.
///
/// Collects the multi-game splitting, header extraction, game counting,
/// position-replay helpers, and the FEN position index that were previously
/// duplicated across [RepertoireService], [PgnViewerController],
/// [RepertoireController], and [PgnImportDialog].
///
/// Pure helpers are isolate-safe (no instance state captured).
/// [computeSliceMatches] spawns its own isolate for the heavy work.
library;

import 'dart:isolate';

import 'package:dartchess/dartchess.dart';

import '../models/pgn_filter_models.dart';
import '../utils/fen_utils.dart';

export '../models/pgn_filter_models.dart';

// ── Regex constants ──────────────────────────────────────────────────────────

/// Splits multi-game PGN text on blank-line boundaries before `[Event `.
final pgnChunkSplitRe = RegExp(r'(?<=\n)\n*(?=\[Event )');

/// Extracts `[Key "Value"]` header pairs from a PGN chunk.
final pgnHeaderRe = RegExp(r'\[(\w+)\s+"([^"]*)"\]');

// ── Multi-game splitting ─────────────────────────────────────────────────────

/// Splits a multi-game PGN string into individual game chunks.
///
/// Handles both `[Event`-delimited and header-less move-only text.
/// Comment-only lines (`// ...`) at the top level are stripped.
///
/// This is isolate-safe (no instance state captured).
List<String> splitPgnIntoGames(String content) {
  final games = <String>[];
  final lines = content.split('\n');

  // A StringBuffer keeps accumulation linear; the old `currentGame += line`
  // re-copied the whole game on every line, which made splitting large
  // multi-game files superlinear (same issue countPgnGamesFast works around).
  final currentGame = StringBuffer();
  var inGame = false;

  void flushGame() {
    final text = currentGame.toString();
    if (text.trim().isNotEmpty) {
      games.add(text);
    }
    currentGame.clear();
  }

  for (final line in lines) {
    final trimmedLine = line.trim();

    if (!inGame &&
        (trimmedLine.startsWith('//') ||
            trimmedLine.startsWith('{') ||
            trimmedLine.startsWith('%'))) {
      continue;
    }

    if (trimmedLine.startsWith('[Event')) {
      if (inGame) {
        flushGame();
      }
      currentGame.write('$line\n');
      inGame = true;
    } else if (inGame) {
      currentGame.write('$line\n');
    } else if (trimmedLine.isNotEmpty) {
      currentGame.write(
        '[Event "Repertoire Line"]\n[White "Training"]\n[Black "Me"]\n\n',
      );
      inGame = true;
      currentGame.write('$line\n');
    }
  }

  if (inGame) {
    flushGame();
  }

  return games;
}

/// Extracts a map of PGN headers from a single-game PGN string.
Map<String, String> extractHeaders(String pgnText) {
  final headers = <String, String>{};
  for (final m in pgnHeaderRe.allMatches(pgnText)) {
    headers[m.group(1)!] = m.group(2)!;
  }
  return headers;
}

// ── Game counting ────────────────────────────────────────────────────────────

/// Returns the number of games in a PGN string.
///
/// Uses [splitPgnIntoGames] so the count matches repertoire import and the
/// Lines list. dartchess [PgnGame.parseMultiGamePgn] under-counts when games
/// are separated only by `[Event` headers (no blank line), as in tree_builder
/// repertoire exports.
int countPgnGames(String pgnContent) {
  return splitPgnIntoGames(stripBom(pgnContent)).length;
}

/// Fast game count for list/metadata display.
///
/// Counts `[Event ` headers at line starts by scanning the string in place,
/// without accumulating per-game substrings the way [splitPgnIntoGames] does
/// (its repeated `currentGame += line` is superlinear, so counting a library
/// of large PGNs that way is what makes the picker screens sluggish).
///
/// All repertoire / study / tactics files this app writes are `[Event`-
/// delimited, so the count is exact for them; header-less move-only text is
/// still reported as a single game, matching [splitPgnIntoGames].
int countPgnGamesFast(String pgnContent) {
  final content = stripBom(pgnContent);
  const marker = '[Event ';
  var count = 0;
  var from = 0;
  while (true) {
    final idx = content.indexOf(marker, from);
    if (idx < 0) break;
    // Only headers that begin a line (start of file or just after a newline)
    // start a new game — mirrors `trimmedLine.startsWith('[Event')`.
    if (idx == 0 || content[idx - 1] == '\n') count++;
    from = idx + marker.length;
  }
  if (count > 0) return count;

  // No headers: header-less move text counts as one game if it has any
  // non-comment, non-blank content.
  for (final line in content.split('\n')) {
    final t = line.trim();
    if (t.isEmpty ||
        t.startsWith('//') ||
        t.startsWith('{') ||
        t.startsWith('%')) {
      continue;
    }
    return 1;
  }
  return 0;
}

// ── Position replay ──────────────────────────────────────────────────────────

/// Determines the starting [Position] for a parsed PGN game.
///
/// Uses the `[FEN]` / `[SetUp]` headers when present, otherwise returns
/// [Chess.initial].
Position startPositionFromGame(PgnGame game) {
  final setup = game.headers['SetUp'] ?? game.headers['Setup'] ?? '';
  final fen = game.headers['FEN'] ?? '';
  if (setup == '1' && fen.isNotEmpty) {
    try {
      return Chess.fromSetup(Setup.parseFen(expandFen(fen)));
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }
  }
  return Chess.initial;
}

/// Whether [pgnText] contains a position matching [targetFen] (normalized).
///
/// Isolate-safe.
bool gamePassesThroughFen(
  Map<String, String> headers,
  String pgnText,
  String targetFen,
) {
  try {
    final game = PgnGame.parsePgn(pgnText);
    final mainline = game.moves.mainline().toList();

    final setupFlag = headers['SetUp'] ?? headers['Setup'] ?? '';
    final fenHeader = headers['FEN'] ?? '';
    Position pos;
    if (setupFlag == '1' && fenHeader.isNotEmpty) {
      pos = Chess.fromSetup(Setup.parseFen(expandFen(fenHeader)));
    } else {
      pos = Chess.initial;
    }

    if (normalizeFen(pos.fen) == targetFen) return true;
    for (final moveData in mainline) {
      final move = pos.parseSan(moveData.san);
      if (move == null) break;
      pos = pos.play(move);
      if (normalizeFen(pos.fen) == targetFen) return true;
    }
  } catch (_) {
    // Best-effort; failure here is non-fatal and intentionally ignored.
  }
  return false;
}

/// Extracts the `// Color:` comment from the top of a repertoire PGN.
///
/// Returns `'white'` or `'black'`, or `null` if not found.
String? extractRepertoireColor(String content) {
  final lines = content.split('\n');
  for (var i = 0; i < lines.length && i < 20; i++) {
    final line = lines[i].trim();
    if (line.startsWith('// Color:')) {
      final color = line.substring(9).trim().toLowerCase();
      if (color == 'white' || color == 'black') return color;
    }
    if (line.startsWith('[Event ')) break;
  }
  return null;
}

/// Strips a leading UTF-8 BOM if present.
String stripBom(String s) => s.startsWith('\uFEFF') ? s.substring(1) : s;

// ── Field matching (isolate-safe) ────────────────────────────────────────────

/// Checks whether [headerVal] satisfies [query] under the given [mode].
///
/// Used by both the slice dialog and the controller to filter games by header
/// values.  Extracted here so `core/` can call it without importing a widget.
bool matchesField(String headerVal, String query, MatchMode mode) {
  switch (mode) {
    case MatchMode.contains:
      return headerVal.toLowerCase().contains(query.toLowerCase());
    case MatchMode.notContains:
      return !headerVal.toLowerCase().contains(query.toLowerCase());
    case MatchMode.exact:
      return headerVal.toLowerCase() == query.toLowerCase();
    case MatchMode.regex:
      try {
        return RegExp(query, caseSensitive: false).hasMatch(headerVal);
      } catch (_) {
        return false;
      }
    case MatchMode.after:
      return headerVal.compareTo(query) >= 0;
    case MatchMode.before:
      return headerVal.compareTo(query) <= 0;
  }
}

// ── Sequence matching (isolate-safe) ─────────────────────────────────────────

/// Parse a sequence pattern string into groups of consecutive SAN moves.
///
/// Groups are separated by `[gap]` tokens.
/// Example: "d5 e5 [gap] f6" -> [["d5","e5"], ["f6"]]
List<List<String>> parseSequenceGroups(String pattern) {
  final trimmed = pattern.trim();
  if (trimmed.isEmpty) return const [];
  final parts = trimmed.split(RegExp(r'\[gap\]', caseSensitive: false));
  final groups = <List<String>>[];
  for (final part in parts) {
    final tokens = part
        .replaceAll(RegExp(r'\d+\.+'), '')
        .replaceAll(RegExp(r'(1-0|0-1|1/2-1/2|\*)'), '')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isNotEmpty) groups.add(tokens);
  }
  return groups;
}

/// Check whether a game's mainline matches the sequence groups with the
/// given max gap (in ply) between groups.
bool gameMatchesSequence(
  String pgnText,
  List<List<String>> groups,
  int maxGap,
) {
  if (groups.isEmpty) return true;
  try {
    final game = PgnGame.parsePgn(pgnText);
    final moves = game.moves.mainline().map((n) => n.san).toList();
    return _matchGroupsAt(moves, groups, 0, 0, maxGap);
  } catch (_) {
    return false;
  }
}

// ── Position input parsing (isolate-safe) ────────────────────────────────────

/// Parse a position input string (FEN or SAN sequence) into a normalized
/// 4-field target FEN.  Returns `null` on empty/invalid input.
String? parseTargetFen(String? input) {
  if (input == null || input.isEmpty) return null;
  final trimmed = input.trim();
  if (trimmed.contains('/')) {
    try {
      final full = expandFen(trimmed);
      Chess.fromSetup(Setup.parseFen(full));
      return normalizeFen(full);
    } catch (_) {
      return null;
    }
  }
  final tokens = trimmed
      .replaceAll(RegExp(r'\d+\.+'), '')
      .replaceAll(RegExp(r'(1-0|0-1|1/2-1/2|\*)'), '')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return null;
  Position pos = Chess.initial;
  for (final t in tokens) {
    final move = pos.parseSan(t);
    if (move == null) return null;
    pos = pos.play(move);
  }
  return normalizeFen(pos.fen);
}

// ── FEN position index ───────────────────────────────────────────────────────

/// Build an inverted index mapping normalized FEN → sorted game indices.
///
/// Replays each game's **mainline only** and records every position reached,
/// so that position-filter lookups become O(1) instead of O(games × moves).
/// Positions reachable only through RAVs (variations) are intentionally
/// excluded for consistency with [gamePassesThroughFen] which also only
/// traverses the mainline.
///
/// Isolate-safe: no instance state captured.
Map<String, List<int>> buildFenIndex(
  List<({Map<String, String> headers, String pgnText})> games,
) {
  final index = <String, List<int>>{};

  void record(String fen, int gameIdx) {
    final list = index[fen];
    if (list == null) {
      index[fen] = [gameIdx];
    } else if (list.last != gameIdx) {
      list.add(gameIdx);
    }
  }

  for (int i = 0; i < games.length; i++) {
    try {
      final game = PgnGame.parsePgn(games[i].pgnText);
      final mainline = game.moves.mainline().toList();
      final headers = games[i].headers;

      final setupFlag = headers['SetUp'] ?? headers['Setup'] ?? '';
      final fenHeader = headers['FEN'] ?? '';
      Position pos;
      if (setupFlag == '1' && fenHeader.isNotEmpty) {
        pos = Chess.fromSetup(Setup.parseFen(expandFen(fenHeader)));
      } else {
        pos = Chess.initial;
      }

      record(normalizeFen(pos.fen), i);
      for (final moveData in mainline) {
        final move = pos.parseSan(moveData.san);
        if (move == null) break;
        pos = pos.play(move);
        record(normalizeFen(pos.fen), i);
      }
    } catch (_) {
      // Best-effort; failure here is non-fatal and intentionally ignored.
    }
  }

  return index;
}

// ── Shared slice compute ─────────────────────────────────────────────────────

/// Compute matching game indices for a combined position / sequence / header
/// filter.  Uses [fenIndex] for O(1) position lookups when available,
/// otherwise falls back to per-game replay in an isolate.
///
/// This is the single entry point shared by [PgnSliceDialog],
/// [InlineSliceEditor], and [applySliceConfig].
Future<List<int>> computeSliceMatches({
  required List<GameRecord> games,
  String? targetFen,
  required List<({String field, MatchMode mode, String value})> filters,
  required List<List<String>> seqGroups,
  required int seqGap,
  Map<String, List<int>>? fenIndex,
}) {
  // Fast path: precomputed FEN index for position lookup
  if (targetFen != null && fenIndex != null) {
    final candidates = fenIndex[targetFen];
    if (candidates == null || candidates.isEmpty) {
      return Future.value(const []);
    }

    final hasOtherFilters =
        filters.any((f) => f.value.isNotEmpty) || seqGroups.isNotEmpty;
    if (!hasOtherFilters) return Future.value(List<int>.from(candidates));

    final candidateData = candidates
        .map(
          (i) => (
            origIdx: i,
            headers: Map<String, String>.from(games[i].headers),
            pgnText: games[i].pgnText,
          ),
        )
        .toList();
    final filterData = filters
        .map((f) => (field: f.field, modeName: f.mode.name, value: f.value))
        .toList();
    final seqCopy = seqGroups.map((g) => List<String>.from(g)).toList();

    return Isolate.run(() {
      final result = <int>[];
      for (final c in candidateData) {
        if (!_passesNonPositionFilters(
          c.headers,
          c.pgnText,
          filterData,
          seqCopy,
          seqGap,
        )) {
          continue;
        }
        result.add(c.origIdx);
      }
      return result;
    });
  }

  // Slow path: full scan in isolate
  final filterData = filters
      .map((f) => (field: f.field, modeName: f.mode.name, value: f.value))
      .toList();
  final gameData = games
      .map(
        (g) =>
            (headers: Map<String, String>.from(g.headers), pgnText: g.pgnText),
      )
      .toList();
  final seqCopy = seqGroups.map((g) => List<String>.from(g)).toList();

  return Isolate.run(() {
    final indices = <int>[];
    for (int i = 0; i < gameData.length; i++) {
      final game = gameData[i];
      bool matches = true;

      if (targetFen != null) {
        matches = gamePassesThroughFen(game.headers, game.pgnText, targetFen);
      }

      if (matches &&
          !_passesNonPositionFilters(
            game.headers,
            game.pgnText,
            filterData,
            seqCopy,
            seqGap,
          )) {
        matches = false;
      }

      if (matches) indices.add(i);
    }
    return indices;
  });
}

/// Shared predicate for header + sequence filters (not position).
bool _passesNonPositionFilters(
  Map<String, String> headers,
  String pgnText,
  List<({String field, String modeName, String value})> filterData,
  List<List<String>> seqGroups,
  int seqGap,
) {
  if (seqGroups.isNotEmpty &&
      !gameMatchesSequence(pgnText, seqGroups, seqGap)) {
    return false;
  }
  for (final f in filterData) {
    if (f.value.isEmpty) continue;
    final headerVal = headers[f.field] ?? '';
    final mode = MatchMode.values.firstWhere(
      (m) => m.name == f.modeName,
      orElse: () => MatchMode.contains,
    );
    if (!matchesField(headerVal, f.value, mode)) return false;
  }
  return true;
}

// ── FEN index persistence ────────────────────────────────────────────────────

/// Serialize a FEN index for disk storage.
///
/// Format header: `FENIDX1 <gameCount> <fileSize> <modifiedMs>`, then
/// one `FEN\tidx,idx,...` per entry.  [fileSize] and [modifiedMs] are the
/// PGN file's byte-size and last-modified epoch-ms at build time, used for
/// staleness detection on load.
String serializeFenIndex(
  Map<String, List<int>> index, {
  required int gameCount,
  required int fileSize,
  required int modifiedMs,
}) {
  final buf = StringBuffer();
  buf.writeln('FENIDX1 $gameCount $fileSize $modifiedMs');
  for (final entry in index.entries) {
    buf.write(entry.key);
    buf.write('\t');
    buf.writeln(entry.value.join(','));
  }
  return buf.toString();
}

/// Deserialize a FEN index from disk.  Returns `null` if the format is
/// invalid or the stored file metadata doesn't match the current PGN file.
Map<String, List<int>>? deserializeFenIndex(
  String data, {
  required int expectedGameCount,
  required int expectedFileSize,
  required int expectedModifiedMs,
}) {
  final firstNl = data.indexOf('\n');
  if (firstNl < 0) return null;

  final header = data.substring(0, firstNl).trim().split(' ');
  if (header.length < 2) return null;

  if (header[0] == 'FENIDX1') {
    if (header.length != 4) return null;
    if (int.tryParse(header[1]) != expectedGameCount) return null;
    if (int.tryParse(header[2]) != expectedFileSize) return null;
    if (int.tryParse(header[3]) != expectedModifiedMs) return null;
  } else {
    // v1 or unknown format — force rebuild.
    return null;
  }

  final index = <String, List<int>>{};
  int start = firstNl + 1;
  while (start < data.length) {
    int end = data.indexOf('\n', start);
    if (end < 0) end = data.length;
    var line = data.substring(start, end);
    start = end + 1;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.isEmpty) continue;

    final tab = line.indexOf('\t');
    if (tab < 0) continue;
    final fen = line.substring(0, tab);
    final ids = <int>[];
    for (final s in line.substring(tab + 1).split(',')) {
      final v = int.tryParse(s);
      if (v == null) continue;
      // Reject a stale/malformed index: any game reference outside
      // `[0, expectedGameCount)` would point past `allGames` and crash
      // consumers. Returning null forces the caller to rebuild from scratch.
      if (v < 0 || v >= expectedGameCount) return null;
      ids.add(v);
    }
    if (ids.isNotEmpty) index[fen] = ids;
  }
  return index;
}

bool _matchGroupsAt(
  List<String> moves,
  List<List<String>> groups,
  int gi,
  int mi,
  int maxGap,
) {
  if (gi >= groups.length) return true;
  final group = groups[gi];
  if (group.length > moves.length) return false;
  final searchLimit = gi == 0 ? moves.length : mi + maxGap;
  final end = searchLimit.clamp(0, moves.length - group.length);
  for (int i = mi; i <= end; i++) {
    bool ok = true;
    for (int j = 0; j < group.length; j++) {
      if (moves[i + j] != group[j]) {
        ok = false;
        break;
      }
    }
    if (ok && _matchGroupsAt(moves, groups, gi + 1, i + group.length, maxGap)) {
      return true;
    }
  }
  return false;
}
