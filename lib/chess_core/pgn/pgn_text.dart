/// PGN text utilities that need no move tree: splitting a file into games,
/// counting them, reading headers and the `//` preamble this app writes.
///
/// Intentional barrel: re-exports [pgn_filter_models] for callers that
/// import parsing helpers and filter types from one place.
///
/// The other halves of what used to live here have their own files:
/// `mainline_lexer.dart` (header block and mainline SANs off the text),
/// `pgn_position_replay.dart` (FEN lookups and the position index) and
/// `pgn_slice_filter.dart` (header / sequence / position slices).
///
/// Every helper is isolate-safe (no instance state captured).
library;

export '../../models/pgn_filter_models.dart';

// ── Regex constants ──────────────────────────────────────────────────────────

/// Splits multi-game PGN text on blank-line boundaries before `[Event `.
final pgnChunkSplitRe = RegExp(r'(?<=\n)\n*(?=\[Event )');

/// Extracts `[Key "Value"]` header pairs from a PGN chunk.
final pgnHeaderRe = RegExp(r'\[(\w+)\s+"([^"]*)"\]');

/// The `[Event ` line start that separates games. The trailing space is
/// load-bearing: a bare `[Event` prefix also matches `[EventDate "..."]`,
/// which would split every game with that header in two.
const String _kEventTagStart = '[Event ';

/// Preamble lines are read this far before giving up.
const int _kPreambleScanLines = 20;

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
List<String> splitPgnIntoGames(String content) => [
  for (final range in pgnGameRanges(content))
    '${range.prefix}${content.substring(range.start, range.end)}'
        '${range.end == content.length ? '\n' : ''}',
];

/// Source offsets using the same boundaries as [splitPgnIntoGames]. Keeping
/// offsets lets writers replace whole games in one pass without searching or
/// rebuilding the entire document for every edit. `prefix` is synthetic and
/// is never part of the source range (header-less repertoire input).
Iterable<({int start, int end, String prefix})> pgnGameRanges(
  String content,
) sync* {
  final length = content.length;
  var gameStart = -1;
  var prefix = '';
  var lineStart = 0;
  while (lineStart <= length) {
    var lineEnd = content.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = length;
    final firstNonBlank = _firstNonBlank(content, lineStart, lineEnd);

    if (content.startsWith(_kEventTagStart, firstNonBlank)) {
      if (gameStart >= 0) {
        yield (start: gameStart, end: lineStart, prefix: prefix);
      }
      gameStart = lineStart;
      prefix = '';
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
    yield (start: gameStart, end: length, prefix: prefix);
  }
}

/// Offset of the line that starts the last game in [content] — the last
/// `[Event ` at a line start — or -1 when there is none.  The boundary
/// [splitPgnIntoGames] cuts on, for callers that only want the final game.
int lastGameStart(String content) {
  var from = content.length;
  while (true) {
    final idx = content.lastIndexOf(_kEventTagStart, from);
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

/// Extracts a map of PGN headers from a single-game PGN string.
///
/// Matches a tag-shaped `[Key "Value"]` anywhere in the text, comments
/// included; `extractHeaderBlock` in `mainline_lexer.dart` reads the
/// leading header block only.
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
/// Walks the text one line at a time without accumulating per-game
/// substrings, so counting a library of large PGNs does not make the picker
/// screens sluggish.
///
/// Counts exactly what the splitter splits, which is not merely the number of
/// `[Event ` line starts: text above the first header is a game too, the one
/// the splitter gives a synthetic `[Event "Repertoire Line"]` block. Counting
/// headers alone reported a file with a non-comment banner — or one opening
/// with bare movetext before its `[Event ` games — as one game short of the
/// Lines list built from the very same file.
int countPgnGamesFast(String pgnContent) {
  final content = stripBom(pgnContent);
  final length = content.length;
  var count = 0;
  // Whether a game is already open, which is what decides if a non-header line
  // starts the synthetic header-less game or merely belongs to the game above.
  var inGame = false;

  var lineStart = 0;
  while (lineStart <= length) {
    var lineEnd = content.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = length;
    final firstNonBlank = _firstNonBlank(content, lineStart, lineEnd);

    if (content.startsWith(_kEventTagStart, firstNonBlank)) {
      count++;
      inGame = true;
    } else if (!inGame && firstNonBlank < lineEnd) {
      final trimmedLine = content.substring(firstNonBlank, lineEnd).trim();
      if (!isPgnCommentLine(trimmedLine)) {
        count++;
        inGame = true;
      }
    }
    lineStart = lineEnd + 1;
  }
  return count;
}

// ── Repertoire preamble ──────────────────────────────────────────────────────

/// The trimmed lines above the first game, at most [_kPreambleScanLines].
Iterable<String> _preambleLines(String content) sync* {
  var lineStart = 0;
  for (var i = 0; i < _kPreambleScanLines && lineStart <= content.length; i++) {
    var lineEnd = content.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = content.length;
    final line = content.substring(lineStart, lineEnd).trim();
    lineStart = lineEnd + 1;
    if (line.startsWith(_kEventTagStart)) return;
    yield line;
  }
}

/// Extracts the `// Color:` comment from the top of a repertoire PGN.
///
/// Returns `'white'` or `'black'`, or `null` if not found.
String? extractRepertoireColor(String content) {
  const marker = '// Color:';
  for (final line in _preambleLines(content)) {
    if (!line.startsWith(marker)) continue;
    final color = line.substring(marker.length).trim().toLowerCase();
    if (color == 'white' || color == 'black') return color;
  }
  return null;
}

/// The course chapter a split chapter file holds, from its `// Chapter:`
/// preamble line (written by `ChapterSplitter`); null for any other file.
/// Read the way [extractRepertoireColor] is: the preamble only.
String? extractCourseChapter(String content) {
  const marker = '// Chapter:';
  for (final line in _preambleLines(content)) {
    if (!line.startsWith(marker)) continue;
    final title = line.substring(marker.length).trim();
    return title.isEmpty ? null : title;
  }
  return null;
}

/// Strips a leading UTF-8 BOM if present.
String stripBom(String s) => s.startsWith('﻿') ? s.substring(1) : s;
