/// Centralized PGN parsing utilities.
///
/// Intentional barrel: re-exports [pgn_filter_models] for callers that
/// import parsing helpers and filter types from one place.
///
/// Collects the multi-game splitting, header extraction, game counting, and
/// position-replay helpers that were previously duplicated across
/// [RepertoireService], [PgnViewerController], [RepertoireController], and
/// [PgnImportDialog].
///
/// All functions are static or top-level so they can run inside [Isolate.run]
/// closures without capturing unsendable state.
library;

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

  var currentGame = '';
  var inGame = false;

  for (final line in lines) {
    final trimmedLine = line.trim();

    if (!inGame &&
        (trimmedLine.startsWith('//') ||
            trimmedLine.startsWith('{') ||
            trimmedLine.startsWith('%'))) {
      continue;
    }

    if (trimmedLine.startsWith('[Event')) {
      if (inGame && currentGame.trim().isNotEmpty) {
        games.add(currentGame);
      }
      currentGame = '$line\n';
      inGame = true;
    } else if (inGame) {
      currentGame += '$line\n';
    } else if (trimmedLine.isNotEmpty) {
      if (!inGame) {
        currentGame =
            '[Event "Repertoire Line"]\n[White "Training"]\n[Black "Me"]\n\n';
        inGame = true;
      }
      currentGame += '$line\n';
    }
  }

  if (inGame && currentGame.trim().isNotEmpty) {
    games.add(currentGame);
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
    } catch (_) {}
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
  } catch (_) {}
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
String stripBom(String s) =>
    s.startsWith('\uFEFF') ? s.substring(1) : s;

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
    String pgnText, List<List<String>> groups, int maxGap) {
  if (groups.isEmpty) return true;
  try {
    final game = PgnGame.parsePgn(pgnText);
    final moves = game.moves.mainline().map((n) => n.san).toList();
    return _matchGroupsAt(moves, groups, 0, 0, maxGap);
  } catch (_) {
    return false;
  }
}

bool _matchGroupsAt(
    List<String> moves, List<List<String>> groups, int gi, int mi, int maxGap) {
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
