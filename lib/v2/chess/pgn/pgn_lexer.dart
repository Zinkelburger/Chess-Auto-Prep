import 'pgn_chars.dart';
import 'pgn_token.dart';

/// Cuts one game's PGN text into tokens.
///
/// Every character is looked at once and no suffix of the text is ever
/// copied, so a megabyte-long single-line game costs what its length says:
/// fifteen milliseconds, against dartchess, which re-substrings the
/// remainder at every `{` and takes about forty times as long on the same
/// text.
///
/// The header block runs until the first character that is neither part of a
/// `[Key "value"]` pair nor a `%` escape line; a game may put its moves on
/// the header's last line and many exports do.
List<PgnToken> lexGame(String text) {
  final scan = _Scan(text);
  final tokens = <PgnToken>[];
  while (scan.i < text.length) {
    final token = scan.next();
    if (token != null) tokens.add(token);
  }
  return tokens;
}

/// The header block of one game's text: the tokens [lexGame] gives before
/// the first one that is neither a tag nor a header line, found without
/// reading any of the moves.
List<PgnToken> lexHeader(String text) {
  final scan = _Scan(text);
  final tokens = <PgnToken>[];
  while (scan.i < text.length) {
    final token = scan.next();
    if (!scan.header) break;
    if (token != null) tokens.add(token);
  }
  return tokens;
}

/// Games spell a ply where nobody moved four ways. `0000` is why move
/// numbers are read before words: `10000.` is move ten thousand, not a null
/// move with a dot after it.
const _nullMoves = {'--', 'Z0', '0000', '@@@@'};

const _terminations = {'1-0', '0-1', '1/2-1/2'};

/// Standard algebraic notation: a piece move with any disambiguation, a
/// pawn move or capture, a promotion with or without `=`, a crazyhouse drop
/// and both spellings of castling. Anchored, so a word is a move only when
/// the whole of it is one.
///
/// A capture needs a piece letter or a from-file in front of it. Letting one
/// start with `x` costs more than a wrong answer: dartchess cuts the
/// annotation off a SAN and then reads its first character, so `xe4` leaves
/// it reading an empty string.
///
/// What this does not accept is written down where the reader reports it:
/// `Qh4++`, `½-½`, `1 . e4` and `$12345` are each text nothing can read, and
/// the game that holds one keeps its own bytes. The long form `e2-e4` is
/// lexed as a move and then found unplayable, because dartchess plays SAN.
final _san = RegExp(
  r'^(?:[NBKRQ][a-h]?[1-8]?[-x]?[a-h][1-8]'
  r'|[a-h][1-8]?[-x]?[a-h][1-8](?:=?[nbrqkNBRQK])?'
  r'|[a-h][1-8](?:=?[nbrqkNBRQK])?'
  r'|[pnbrqkPNBRQK]?@[a-h][1-8]|O-O-O|0-0-0|O-O|0-0)[+#]?$',
);

/// Where the scan is and what it has decided so far.
final class _Scan {
  _Scan(this.text);

  final String text;
  int i = 0;

  /// Whether [i] is the first character of a line, which is the only place a
  /// `%` escape line can start.
  bool lineStart = true;

  /// Whether the header block is still open.
  bool header = true;

  /// The next token, or null for text that carries nothing — whitespace, a
  /// move number, `e.p.`.
  PgnToken? next() {
    final c = text.codeUnitAt(i);
    if (c == lf) {
      i++;
      lineStart = true;
      return null;
    }
    if (isBlank(c)) {
      i++;
      return null;
    }
    final fresh = lineStart;
    lineStart = false;
    if (fresh && c == percent) return _escapeLine();
    if (header && c == openBracket) return _headerLine();
    header = false;
    return _moveToken(c);
  }

  PgnToken _escapeLine() {
    final start = i;
    final inHeader = header;
    final (line, trailer) = _restOfLine();
    return inHeader
        ? HeaderLineToken(start, i, line, trailer)
        : EscapeLineToken(start);
  }

  PgnToken _headerLine() {
    final tag = _tag();
    if (tag != null) return tag;
    final start = i;
    final (line, trailer) = _restOfLine();
    return HeaderLineToken(start, i, line, trailer);
  }

  /// One `[Key "value"]`, or null when the text at [i] is not one; on null
  /// nothing has been consumed.
  TagToken? _tag() {
    final start = i;
    var j = _keyEnd(i + 1);
    if (j == i + 1) return null;
    final key = text.substring(i + 1, j);
    final spaced = j;
    while (j < text.length && isBlank(text.codeUnitAt(j))) {
      j++;
    }
    if (j == spaced || j >= text.length || text.codeUnitAt(j) != quote) {
      return null;
    }
    final valueStart = j + 1;
    final valueEnd = _valueEnd(valueStart);
    if (valueEnd < 0 || valueEnd + 1 >= text.length) return null;
    if (text.codeUnitAt(valueEnd + 1) != closeBracket) return null;
    i = valueEnd + 2;
    final value = unescapedTagValue(text.substring(valueStart, valueEnd));
    final raw = text.substring(start, i);
    final trailer = _trailer();
    return TagToken(start, i, key, value, raw, trailer);
  }

  int _keyEnd(int from) {
    var j = from;
    while (j < text.length && isKeyChar(text.codeUnitAt(j))) {
      j++;
    }
    return j;
  }

  /// The index of the quote that closes a tag value starting at [from], or
  /// -1 when the line ends first. A backslash escapes the character after it,
  /// which is how a value holds a quote.
  int _valueEnd(int from) {
    var j = from;
    while (j < text.length) {
      final c = text.codeUnitAt(j);
      if (c == lf) return -1;
      if (c == quote) return j;
      if (c == backslash &&
          (j + 1 >= text.length || text.codeUnitAt(j + 1) == lf)) {
        return -1;
      }
      j += c == backslash ? 2 : 1;
    }
    return -1;
  }

  /// The whitespace that followed the header line just read, consumed: up
  /// to and including the first newline, or up to whatever else is on the
  /// line. Writing it back is what keeps a trailing space, a CRLF tag line
  /// above an LF movetext, and two tags that shared a line.
  String _trailer() {
    final start = i;
    var j = i;
    while (j < text.length && isBlank(text.codeUnitAt(j))) {
      j++;
    }
    if (j < text.length && text.codeUnitAt(j) == lf) {
      j++;
      lineStart = true;
    }
    i = j;
    return text.substring(start, j);
  }

  /// The rest of the line from [i] without its ending, and that ending;
  /// [i] is left on the next line.
  (String, String) _restOfLine() {
    final found = text.indexOf('\n', i);
    final end = found < 0 ? text.length : found;
    final carriage = end > i && text.codeUnitAt(end - 1) == cr;
    final stop = carriage ? end - 1 : end;
    final line = text.substring(i, stop);
    i = found < 0 ? text.length : end + 1;
    lineStart = true;
    if (found < 0) return (line, carriage ? '\r' : '');
    return (line, carriage ? '\r\n' : '\n');
  }

  PgnToken? _moveToken(int c) {
    final start = i;
    switch (c) {
      case openBrace:
        return _braceComment();
      case semicolon:
        return _lineComment();
      case openParen:
        i++;
        return VariationOpen(start);
      case closeParen:
        i++;
        return VariationClose(start);
      case dollar:
        return _numericNag();
      case bang || question:
        return _glyphNag();
      case star:
        i++;
        return TerminationToken(start, '*');
      case dot:
        return dots();
    }
    final number = isDigit(c) ? _moveNumber() : null;
    if (number != null) return number;
    if (_skipsEnPassant()) return null;
    return _word();
  }

  /// A `{}` comment, kept exactly as written: comments do not nest, so the
  /// first `}` ends it and a `{` inside one is ordinary text. PGN has no
  /// escape inside a comment and neither the old app nor Lichess invents
  /// one — both strip braces instead — so `\}` closes the comment too.
  PgnToken _braceComment() {
    final start = i;
    final found = text.indexOf('}', i + 1);
    final stop = found < 0 ? text.length : found;
    final body = text.substring(i + 1, stop);
    i = found < 0 ? text.length : found + 1;
    return CommentToken(start, body, closed: found >= 0);
  }

  PgnToken _lineComment() {
    final start = i;
    i++;
    final (line, _) = _restOfLine();
    return CommentToken(start, line, closed: true);
  }

  PgnToken _numericNag() {
    final start = i;
    var j = i + 1;
    while (j < text.length && j - start <= 4 && isDigit(text.codeUnitAt(j))) {
      j++;
    }
    i = j;
    if (j == start + 1) return UnknownTextToken(start, r'$');
    return NagToken(start, int.parse(text.substring(start + 1, j)));
  }

  PgnToken _glyphNag() {
    final start = i;
    var j = i + 1;
    if (j < text.length && isGlyph(text.codeUnitAt(j))) j++;
    i = j;
    return NagToken(start, glyphValue(text.substring(start, j)));
  }

  PgnToken dots() {
    final start = i;
    while (i < text.length && text.codeUnitAt(i) == dot) {
      i++;
    }
    return MoveNumberToken(start);
  }

  /// `12.` or `12...`, or null when the digits are not a move number after
  /// all; on null nothing has been consumed.
  MoveNumberToken? _moveNumber() {
    final start = i;
    var j = i;
    while (j < text.length && isDigit(text.codeUnitAt(j))) {
      j++;
    }
    if (j >= text.length || text.codeUnitAt(j) != dot) return null;
    while (j < text.length && text.codeUnitAt(j) == dot) {
      j++;
    }
    i = j;
    return MoveNumberToken(start);
  }

  bool _skipsEnPassant() {
    for (final form in const ['e.p.', 'e.p']) {
      if (!text.startsWith(form, i)) continue;
      i += form.length;
      return true;
    }
    return false;
  }

  PgnToken _word() {
    final start = i;
    while (i < text.length && isWordChar(text.codeUnitAt(i))) {
      i++;
    }
    if (i == start) {
      i++;
      return UnknownTextToken(start, text.substring(start, i));
    }
    final word = text.substring(start, i);
    if (_terminations.contains(word)) return TerminationToken(start, word);
    if (_nullMoves.contains(word)) return NullMoveToken(start, word);
    if (_san.hasMatch(word)) return SanToken(start, word);
    return UnknownTextToken(start, word);
  }
}
