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

import '../core/pgn/pgn_dummy_mainline.dart';
import '../models/pgn_filter_models.dart';
import '../utils/chess_utils.dart' show isNullMoveSan, playSanOrNullMove;
import '../utils/fen_utils.dart';

export '../models/pgn_filter_models.dart';

// ── Regex constants ──────────────────────────────────────────────────────────

/// Splits multi-game PGN text on blank-line boundaries before `[Event `.
final pgnChunkSplitRe = RegExp(r'(?<=\n)\n*(?=\[Event )');

/// Extracts `[Key "Value"]` header pairs from a PGN chunk.
final pgnHeaderRe = RegExp(r'\[(\w+)\s+"([^"]*)"\]');

// ── Multi-game splitting ─────────────────────────────────────────────────────

/// Whether a trimmed line is a top-level comment/escape line: `//` (this
/// app's repertoire metadata), `;` (PGN spec rest-of-line comment), `{`
/// (brace comment), or `%` (PGN spec escape). Downloaded collections often
/// open with a `;`-comment banner, which must not become a game.
bool isPgnCommentLine(String trimmedLine) =>
    trimmedLine.startsWith('//') ||
    trimmedLine.startsWith(';') ||
    trimmedLine.startsWith('{') ||
    trimmedLine.startsWith('%');

/// Splits a multi-game PGN string into individual game chunks.
///
/// Handles both `[Event`-delimited and header-less move-only text.
/// Comment-only lines (`// ...`, spec `; ...` rest-of-line comments, `%`
/// escapes) at the top level are stripped.
///
/// Games are cut out of [content] as substrings between `[Event ` line
/// starts: the text is scanned once for line boundaries and no per-line
/// strings are made for the lines inside a game.  A file with N games costs
/// N substrings, not one per line plus a trim per line.
///
/// Each chunk is the game's lines each terminated by `\n` (the last chunk
/// always ends with one), which is what the line-joining implementation this
/// replaces produced.
///
/// This is isolate-safe (no instance state captured).
List<String> splitPgnIntoGames(String content) {
  final games = <String>[];
  final length = content.length;

  // Start offset of the game being accumulated, or -1 before the first one.
  var gameStart = -1;
  // Synthetic header block for header-less text, prepended to the chunk.
  String? prefix;

  void flush(int end) {
    final body = content.substring(gameStart, end);
    final text = prefix == null ? body : '$prefix$body';
    if (text.trim().isNotEmpty) games.add(text);
    prefix = null;
  }

  var lineStart = 0;
  while (lineStart <= length) {
    var lineEnd = content.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = length;
    final firstNonBlank = _firstNonBlank(content, lineStart, lineEnd);

    // The trailing space is load-bearing: a bare `[Event` prefix also matches
    // `[EventDate "..."]`, which would split every game with that header in
    // two.
    if (content.startsWith('[Event ', firstNonBlank)) {
      if (gameStart >= 0) flush(lineStart);
      gameStart = lineStart;
    } else if (gameStart < 0 && firstNonBlank < lineEnd) {
      final trimmedLine = content.substring(firstNonBlank, lineEnd).trim();
      if (!isPgnCommentLine(trimmedLine)) {
        prefix =
            '[Event "Repertoire Line"]\n[White "Training"]\n[Black "Me"]\n\n';
        gameStart = lineStart;
      }
    }
    lineStart = lineEnd + 1;
  }

  if (gameStart >= 0) {
    // Every line is `\n`-terminated in a chunk, the final one included.
    final body = content.substring(gameStart);
    final text = '${prefix ?? ''}$body\n';
    if (text.trim().isNotEmpty) games.add(text);
  }

  return games;
}

/// Offset of the line that starts the last game in [content] — the last
/// `[Event ` at a line start — or -1 when there is none.  The boundary
/// [splitPgnIntoGames] cuts on, for callers that only want the final game.
int lastGameStart(String content) {
  const marker = '[Event ';
  var from = content.length;
  while (true) {
    final idx = content.lastIndexOf(marker, from);
    if (idx < 0) return -1;
    if (_isLineStart(content, idx)) {
      // Back up over the blanks to the true line start.
      var lineStart = idx;
      while (lineStart > 0 && content.codeUnitAt(lineStart - 1) != 0x0A) {
        lineStart--;
      }
      return lineStart;
    }
    if (idx == 0) return -1;
    from = idx - 1;
  }
}

/// Offset of the first character in `[start, end)` that is not a space,
/// tab, carriage return or byte-order mark — [end] when the line is blank.
/// (`String.trim`, which this replaces, strips U+FEFF as whitespace too.)
int _firstNonBlank(String content, int start, int end) {
  var i = start;
  while (i < end) {
    final c = content.codeUnitAt(i);
    if (c != 0x20 && c != 0x09 && c != 0x0D && c != 0xFEFF) break;
    i++;
  }
  return i;
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
/// Agrees with [splitPgnIntoGames] (so the count matches repertoire import
/// and the Lines list) without building the chunks: both count `[Event `
/// headers at line starts, and both report header-less move text as one
/// game.  dartchess [PgnGame.parseMultiGamePgn] under-counts when games are
/// separated only by `[Event` headers (no blank line), as in tree_builder
/// repertoire exports.
int countPgnGames(String pgnContent) => countPgnGamesFast(pgnContent);

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
    // Only headers that begin a line (start of file or just after a newline,
    // with nothing but blanks between) start a new game — mirrors
    // `trimmedLine.startsWith('[Event ')`.
    if (_isLineStart(content, idx)) count++;
    from = idx + marker.length;
  }
  if (count > 0) return count;

  // No headers: header-less move text counts as one game if it has any
  // non-comment, non-blank content.
  var lineStart = 0;
  while (lineStart <= content.length) {
    var lineEnd = content.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = content.length;
    final t = content.substring(lineStart, lineEnd).trim();
    if (t.isNotEmpty && !isPgnCommentLine(t)) return 1;
    lineStart = lineEnd + 1;
  }
  return 0;
}

/// Whether only blanks separate [offset] from the start of its line.
bool _isLineStart(String content, int offset) {
  var i = offset - 1;
  while (i >= 0) {
    final c = content.codeUnitAt(i);
    if (c == 0x0A) return true;
    if (c != 0x20 && c != 0x09 && c != 0x0D) return false;
    i--;
  }
  return true;
}

// ── Mainline lexing ──────────────────────────────────────────────────────────

/// dartchess's movetext token grammar, verbatim from its PGN parser: a SAN
/// (with optional check/mate suffix), a null move, a comment or line-comment
/// opener, a NAG, an annotation glyph, a variation bracket, or a result.
/// Anything else on a line — move numbers, dots, stray text — is skipped.
final RegExp _movetextTokenRe = RegExp(
  r'(?:[NBKRQ]?[a-h]?[1-8]?[-x]?[a-h][1-8](?:=?[nbrqkNBRQK])?|[pnbrqkPNBRQK]?@[a-h][1-8]|O-O-O|0-0-0|O-O|0-0)[+#]?|--|Z0|0000|@@@@|{|;|\$\d{1,4}|[?!]{1,2}|\(|\)|\*|1-0|0-1|1\/2-1\/2',
);

/// One `[Tag "value"]` pair at the start of a header line, as dartchess
/// recognises it (escaped quotes and backslashes allowed in the value).
final RegExp _headerTagRe = RegExp(
  r'^\s*\[([A-Za-z0-9][A-Za-z0-9_+#=:-]*)\s+"((?:[^"\\]|\\"|\\\\)*)"\]',
);

/// The mainline SAN moves of [gameText], exactly as
/// `PgnGame.parsePgn(gameText).moves.mainline()` reports them, without
/// building the move tree.
///
/// Line ids are derived from the mainline, so every file edit that looks a
/// game up by id needs this list for every game in the file.  Parsing each
/// game with dartchess allocates a node per move, per variation move and per
/// comment; this walks the same token grammar and keeps only the top-level
/// moves.  The equivalence is pinned by `test/services/mainline_lexer_test.dart`
/// — change one, run the other.
///
/// Mirrors the parser's rules: `[Tag "value"]` lines at the top are headers;
/// a `%` at a line start escapes that line; `;` comments to end of line;
/// `{ }` comments do not nest and may span lines; `( )` variations nest;
/// `Z0` / `0000` / `@@@@` are the null move `--`; `0-0` castling is
/// normalised to `O-O`.  Results and `!?` glyphs are not moves, and — as in
/// dartchess — tokens after a result are still read.
List<String> mainlineSansOf(String gameText) {
  final text = stripBom(gameText);
  final sans = <String>[];
  var depth = 0;

  var lineStart = _movetextStart(text);
  // Set when a brace comment ran past the end of its line: the scan resumes
  // mid-line at the `}` instead of at the next line start.
  var resumeInsideLine = false;

  while (lineStart <= text.length) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;

    if (!resumeInsideLine && text.startsWith('%', lineStart)) {
      lineStart = lineEnd + 1;
      continue;
    }
    resumeInsideLine = false;

    final line = text.substring(lineStart, lineEnd);
    var offset = 0;
    var nextLineStart = lineEnd + 1;

    tokens:
    for (final match in _movetextTokenRe.allMatches(line, offset)) {
      if (match.start < offset) continue;
      final token = match[0]!;
      switch (token) {
        case ';':
          break tokens;
        case '(':
          depth++;
        case ')':
          if (depth > 0) depth--;
        case '{':
          final close = text.indexOf('}', lineStart + match.end);
          if (close < 0) return sans;
          if (close < lineEnd) {
            // Same line: skip the comment and keep lexing after it.
            offset = close - lineStart + 1;
            continue tokens;
          }
          // The comment closes on a later line: resume there, mid-line.
          nextLineStart = close;
          resumeInsideLine = true;
          break tokens;
        case '*' || '1-0' || '0-1' || '1/2-1/2':
          break;
        default:
          if (token.codeUnitAt(0) == 0x24 /* $ */ ||
              token.codeUnitAt(0) == 0x21 /* ! */ ||
              token.codeUnitAt(0) == 0x3F /* ? */ ) {
            break; // NAG or annotation glyph.
          }
          if (depth == 0) sans.add(_normalizeSanToken(token));
      }
    }
    lineStart = nextLineStart;
  }
  return sans;
}

/// The `[Tag "value"]` pairs of the leading header block, decoded the way
/// dartchess decodes them (`\\"` → `"`, `\\\\` → `\\`).  Stops at the first line
/// that is not a header, so a tag-shaped string inside a comment is never
/// read as a header — unlike [extractHeaders], which matches anywhere.
Map<String, String> extractHeaderBlock(String gameText) {
  final text = stripBom(gameText);
  final headers = <String, String>{};
  var lineStart = 0;
  var inHeaders = false;
  while (lineStart < text.length) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    var line = text.substring(lineStart, lineEnd);
    lineStart = lineEnd + 1;

    if (!inHeaders) {
      if (line.trim().isEmpty || line.startsWith('%')) continue;
      inHeaders = true;
    } else if (line.startsWith('%')) {
      return headers;
    }

    for (var m = _headerTagRe.firstMatch(line); m != null;) {
      headers[m.group(1)!] = m
          .group(2)!
          .replaceAll('\\"', '"')
          .replaceAll('\\\\', '\\');
      line = line.substring(m.end);
      m = _headerTagRe.firstMatch(line);
    }
    if (line.trim().isNotEmpty) return headers;
  }
  return headers;
}

/// Offset of the first movetext line: past any leading blank / `%` lines and
/// the run of header lines.  A line that carries text after its last header
/// tag starts the movetext itself, as in dartchess.
int _movetextStart(String text) {
  var lineStart = 0;
  var inHeaders = false;
  while (lineStart < text.length) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    var line = text.substring(lineStart, lineEnd);

    if (!inHeaders) {
      if (line.trim().isEmpty || line.startsWith('%')) {
        lineStart = lineEnd + 1;
        continue;
      }
      inHeaders = true;
    } else if (line.startsWith('%')) {
      // dartchess ends the game here; there is no movetext to read.
      return text.length + 1;
    }

    var consumed = 0;
    for (var m = _headerTagRe.firstMatch(line); m != null;) {
      consumed += m.end;
      line = line.substring(m.end);
      m = _headerTagRe.firstMatch(line);
    }
    if (line.trim().isNotEmpty) return lineStart + consumed;
    lineStart = lineEnd + 1;
  }
  return text.length + 1;
}

String _normalizeSanToken(String token) {
  if (token == 'Z0' || token == '0000' || token == '@@@@') return '--';
  if (token.codeUnitAt(0) == 0x30 /* 0 */ ) return token.replaceAll('0', 'O');
  return token;
}

// ── Position replay ──────────────────────────────────────────────────────────

/// Determines the starting [Position] for a parsed PGN game.
///
/// Uses the `[FEN]` / `[SetUp]` headers when present, otherwise returns
/// [Chess.initial].
Position startPositionFromGame(PgnGame game) {
  try {
    return _positionFromHeaders(game.headers);
  } catch (_) {
    return Chess.initial;
  }
}

PgnGame _parsePgnForReplay(String pgnText) {
  final game = PgnGame.parsePgn(pgnText);
  promoteNullMoveDummyMainline(game.moves);
  return game;
}

/// Throws when `[SetUp]` is `1` and `[FEN]` is unparsable — replay helpers
/// catch that and skip the game. [startPositionFromGame] falls back to the
/// initial position instead.
Position _positionFromHeaders(Map<String, String> headers) {
  final setupFlag = headers['SetUp'] ?? headers['Setup'] ?? '';
  final fenHeader = headers['FEN'] ?? '';
  if (setupFlag == '1' && fenHeader.isNotEmpty) {
    return Chess.fromSetup(Setup.parseFen(expandFen(fenHeader)));
  }
  return Chess.initial;
}

/// DFS over the parsed tree, mainline children first. [visit] returning
/// false stops the walk. Iterative so a hostile 500-deep RAV nest cannot
/// blow the stack.
void _forEachPgnNode(
  PgnNode<PgnNodeData> root,
  Position start,
  bool Function(Position pos, PgnNode<PgnNodeData> node) visit,
) {
  if (!visit(start, root)) return;
  final stack = <({PgnNode<PgnNodeData> node, Position pos})>[
    (node: root, pos: start),
  ];
  while (stack.isNotEmpty) {
    final cur = stack.removeLast();
    final kids = cur.node.children;
    for (var i = kids.length - 1; i >= 0; i--) {
      final next = playSanOrNullMove(cur.pos, kids[i].data.san);
      if (next == null) continue;
      if (!visit(next, kids[i])) return;
      stack.add((node: kids[i], pos: next));
    }
  }
}

List<String> _child0Sans(PgnNode<PgnNodeData> node, {required int maxPlies}) {
  final remaining = <String>[];
  var n = node;
  while (n.children.isNotEmpty && remaining.length < maxPlies) {
    final child = n.children.first;
    remaining.add(child.data.san);
    n = child;
  }
  return remaining;
}

/// A game parsed once for every replay-based predicate a slice applies to
/// it.  The slow slice path used to parse the same game up to three times —
/// once per predicate — which is the whole cost of a slice on a collection
/// without a `.fenidx`.
class _ReplayGame {
  _ReplayGame(this.game, this.start);

  final PgnGame<PgnNodeData> game;
  final Position start;

  /// Null when the game or its `[FEN]` header does not parse; every
  /// predicate then reports no match, as the per-call parses did.
  static _ReplayGame? tryParse(Map<String, String> headers, String pgnText) {
    try {
      return _ReplayGame(
        _parsePgnForReplay(pgnText),
        _positionFromHeaders(headers),
      );
    } catch (_) {
      return null;
    }
  }

  bool passesThroughFen(String targetFen) {
    var found = false;
    _forEachPgnNode(game.moves, start, (pos, _) {
      if (normalizeFen(pos.fen) == targetFen) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  bool matchesSequence(List<List<String>> groups, int maxGap) {
    if (groups.isEmpty) return true;
    final moves = game.moves
        .mainline()
        .map((n) => n.san)
        .where((s) => !isNullMoveSan(s))
        .toList();
    return _matchGroupsAt(moves, groups, 0, 0, maxGap);
  }
}

/// Whether [pgnText] contains a position matching [targetFen] (normalized).
///
/// Walks the mainline and RAVs, so a course chapter that only reaches the
/// position in a sideline still matches. Isolate-safe.
bool gamePassesThroughFen(
  Map<String, String> headers,
  String pgnText,
  String targetFen,
) =>
    _ReplayGame.tryParse(headers, pgnText)?.passesThroughFen(targetFen) ??
    false;

/// SAN after [targetFen] is reached, along the line that found it (the
/// mainline of that variation, or the game mainline when the hit is there).
/// Empty if the FEN is never hit, or if the line ends at that position.
///
/// Caps at [maxPlies] so a list row never materialises a whole long game.
/// Isolate-safe.
List<String> mainlineSansAfterFen(
  Map<String, String> headers,
  String pgnText,
  String targetFen, {
  int maxPlies = 40,
}) {
  try {
    final game = _parsePgnForReplay(pgnText);
    final target = normalizeFen(targetFen);
    List<String>? remaining;
    _forEachPgnNode(game.moves, _positionFromHeaders(headers), (pos, node) {
      if (normalizeFen(pos.fen) != target) return true;
      remaining = _child0Sans(node, maxPlies: maxPlies);
      return false;
    });
    return remaining ?? const [];
  } catch (_) {
    return const [];
  }
}

/// Extracts the `// Color:` comment from the top of a repertoire PGN.
///
/// Returns `'white'` or `'black'`, or `null` if not found.
String? extractRepertoireColor(String content) {
  var lineStart = 0;
  for (var i = 0; i < 20 && lineStart <= content.length; i++) {
    var lineEnd = content.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = content.length;
    final line = content.substring(lineStart, lineEnd).trim();
    lineStart = lineEnd + 1;
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
      {
        // Numeric fields (WhiteElo/BlackElo/StudyRating) must compare
        // numerically, not lexicographically — otherwise "≥ 500" wrongly
        // excludes a 2400 game ("2400" < "500"). Dates ("YYYY.MM.DD") don't
        // parse as num, so they fall back to the correct string compare.
        final hv = num.tryParse(headerVal);
        final q = num.tryParse(query);
        if (hv != null && q != null) return hv >= q;
        return headerVal.compareTo(query) >= 0;
      }
    case MatchMode.before:
      {
        final hv = num.tryParse(headerVal);
        final q = num.tryParse(query);
        if (hv != null && q != null) return hv <= q;
        return headerVal.compareTo(query) <= 0;
      }
  }
}

/// [kPlayerHeaderField] filter: does either colour's header satisfy [query]?
///
/// [query] may hold several `;`-separated names ([splitPlayerNames]); a game
/// passes when **any** name matches **either** side — except in
/// [MatchMode.notContains], where **every** name must be absent from **both**
/// sides (the natural reading of "player not contains X").
bool playerFieldMatches(
  String whiteHeader,
  String blackHeader,
  String query,
  MatchMode mode,
) {
  final names = splitPlayerNames(query);
  if (names.isEmpty) return true;
  if (mode == MatchMode.notContains) {
    return names.every(
      (n) =>
          matchesField(whiteHeader, n, mode) &&
          matchesField(blackHeader, n, mode),
    );
  }
  return names.any(
    (n) =>
        matchesField(whiteHeader, n, mode) ||
        matchesField(blackHeader, n, mode),
  );
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
  return _ReplayGame.tryParse(
        const {},
        pgnText,
      )?.matchesSequence(groups, maxGap) ??
      false;
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
  try {
    Position pos = Chess.initial;
    for (final t in tokens) {
      final next = playSanOrNullMove(pos, t);
      if (next == null) return null;
      pos = next;
    }
    return normalizeFen(pos.fen);
  } catch (_) {
    // dartchess' parseSan/play can throw (e.g. RangeError) on some malformed
    // tokens — a stray '(' from pasted variation movetext, an 'x'-prefixed
    // token — rather than returning null. Treat any such input as "no target",
    // matching the FEN branch above and this function's documented contract.
    return null;
  }
}

// ── FEN position index ───────────────────────────────────────────────────────

/// Build an inverted index mapping normalized FEN → sorted game indices.
///
/// Replays each game's mainline **and RAVs** and records every position
/// reached, so opening-tree "games at this position" and position-slice
/// filters see course sidelines, not just each chapter's mainline.
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
      final game = _parsePgnForReplay(games[i].pgnText);
      _forEachPgnNode(game.moves, _positionFromHeaders(games[i].headers), (
        pos,
        _,
      ) {
        record(normalizeFen(pos.fen), i);
        return true;
      });
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
  // Records cross the isolate boundary; the enum travels by name.
  final filterData = filters
      .map((f) => (field: f.field, modeName: f.mode.name, value: f.value))
      .toList();
  final seqCopy = seqGroups.map((g) => List<String>.from(g)).toList();

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

    return Isolate.run(() {
      final compiled = _CompiledFilter.compileAll(filterData);
      final result = <int>[];
      for (final c in candidateData) {
        if (!_passesNonPositionFilters(
          c.headers,
          c.pgnText,
          compiled,
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
  final gameData = games
      .map(
        (g) =>
            (headers: Map<String, String>.from(g.headers), pgnText: g.pgnText),
      )
      .toList();

  return Isolate.run(() {
    final compiled = _CompiledFilter.compileAll(filterData);
    final needsReplay = targetFen != null || seqCopy.isNotEmpty;
    final indices = <int>[];
    for (int i = 0; i < gameData.length; i++) {
      final game = gameData[i];
      if (needsReplay) {
        // One parse serves both replay predicates.
        final replay = _ReplayGame.tryParse(game.headers, game.pgnText);
        if (replay == null) continue;
        if (targetFen != null && !replay.passesThroughFen(targetFen)) continue;
        if (!replay.matchesSequence(seqCopy, seqGap)) continue;
      }
      if (!_CompiledFilter.allMatch(compiled, game.headers)) continue;
      indices.add(i);
    }
    return indices;
  });
}

/// A header filter with its mode resolved and its query lower-cased once,
/// rather than per game.  [MatchMode.regex] compiles its pattern once too.
class _CompiledFilter {
  _CompiledFilter._(this.field, this.mode, this.value)
    : queryLower = value.toLowerCase(),
      regex = mode == MatchMode.regex ? _tryRegExp(value) : null;

  final String field;
  final MatchMode mode;
  final String value;
  final String queryLower;
  final RegExp? regex;

  static RegExp? _tryRegExp(String pattern) {
    try {
      return RegExp(pattern, caseSensitive: false);
    } catch (_) {
      return null;
    }
  }

  static List<_CompiledFilter> compileAll(
    List<({String field, String modeName, String value})> filters,
  ) => [
    for (final f in filters)
      if (f.value.isNotEmpty)
        _CompiledFilter._(
          f.field,
          MatchMode.values.firstWhere(
            (m) => m.name == f.modeName,
            orElse: () => MatchMode.contains,
          ),
          f.value,
        ),
  ];

  static bool allMatch(
    List<_CompiledFilter> filters,
    Map<String, String> headers,
  ) {
    for (final f in filters) {
      if (!f.matches(headers)) return false;
    }
    return true;
  }

  bool matches(Map<String, String> headers) {
    if (field == kPlayerHeaderField) {
      return playerFieldMatches(
        headers['White'] ?? '',
        headers['Black'] ?? '',
        value,
        mode,
      );
    }
    final headerVal = headers[field] ?? '';
    switch (mode) {
      case MatchMode.contains:
        return headerVal.toLowerCase().contains(queryLower);
      case MatchMode.notContains:
        return !headerVal.toLowerCase().contains(queryLower);
      case MatchMode.exact:
        return headerVal.toLowerCase() == queryLower;
      case MatchMode.regex:
        return regex?.hasMatch(headerVal) ?? false;
      case MatchMode.after:
      case MatchMode.before:
        return matchesField(headerVal, value, mode);
    }
  }
}

/// Shared predicate for header + sequence filters (not position).
bool _passesNonPositionFilters(
  Map<String, String> headers,
  String pgnText,
  List<_CompiledFilter> filters,
  List<List<String>> seqGroups,
  int seqGap,
) {
  if (seqGroups.isNotEmpty &&
      !gameMatchesSequence(pgnText, seqGroups, seqGap)) {
    return false;
  }
  return _CompiledFilter.allMatch(filters, headers);
}

// ── FEN index persistence ────────────────────────────────────────────────────

/// Serialize a FEN index for disk storage.
///
/// Format header: `FENIDX2 <gameCount> <fileSize> <modifiedMs>`, then
/// one `FEN\tidx,idx,...` per entry.  [fileSize] and [modifiedMs] are the
/// PGN file's byte-size and last-modified epoch-ms at build time, used for
/// staleness detection on load. v2 indexes RAVs as well as the mainline;
/// `FENIDX1` blobs are rejected so they rebuild.
String serializeFenIndex(
  Map<String, List<int>> index, {
  required int gameCount,
  required int fileSize,
  required int modifiedMs,
}) {
  final buf = StringBuffer();
  buf.writeln('FENIDX2 $gameCount $fileSize $modifiedMs');
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

  if (header[0] == 'FENIDX2') {
    if (header.length != 4) return null;
    if (int.tryParse(header[1]) != expectedGameCount) return null;
    if (int.tryParse(header[2]) != expectedFileSize) return null;
    if (int.tryParse(header[3]) != expectedModifiedMs) return null;
  } else {
    // v1 (mainline-only) or unknown format — force rebuild.
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
