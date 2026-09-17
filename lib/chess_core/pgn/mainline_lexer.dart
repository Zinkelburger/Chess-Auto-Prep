/// Reading a game's header block and mainline SANs straight off its text,
/// without building the dartchess move tree.
///
/// Line ids are derived from the mainline, so every file edit that looks a
/// game up by id needs this for every game in the file. Parsing each game
/// with dartchess allocates a node per move, per variation move and per
/// comment; these walk the same token grammar and keep only what they need.
/// The equivalence with dartchess is pinned by
/// `test/services/mainline_lexer_test.dart` — change one, run the other.
library;

import 'pgn_text.dart' show stripBom;

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

  var lineStart = movetextStart(text);
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
          if (_isGlyphOrNag(token)) break;
          if (depth == 0) sans.add(_normalizeSanToken(token));
      }
    }
    lineStart = nextLineStart;
  }
  return sans;
}

/// Batch form for `compute`: one SAN list per input game.
List<List<String>> mainlineSansOfBatch(List<String> gameTexts) => [
  for (final text in gameTexts) mainlineSansOf(text),
];

/// A NAG (`$12`) or an annotation glyph (`!`, `?!`).
bool _isGlyphOrNag(String token) {
  final first = token.codeUnitAt(0);
  return first == 0x24 /* $ */ ||
      first == 0x21 /* ! */ ||
      first == 0x3F /* ? */;
}

/// The `[Tag "value"]` pairs of the leading header block, decoded the way
/// dartchess decodes them (`\\"` → `"`, `\\\\` → `\\`).  Stops at the first line
/// that is not a header, so a tag-shaped string inside a comment is never
/// read as a header — unlike `extractHeaders`, which matches anywhere.
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

/// Offset of the first movetext character: past any leading blank / `%`
/// lines and the run of header lines.  A line that carries text after its
/// last header tag starts the movetext itself, as in dartchess.
///
/// `0` for header-less move text (which `splitPgnIntoGames` supports), and
/// past the end of [text] when the game has no movetext at all.  This is the
/// boundary anything that rewrites a game's moves in place has to cut on:
/// searching for the last `]`-terminated line instead finds a `]` inside a
/// comment and splices in the middle of the movetext.
int movetextStart(String text) {
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
