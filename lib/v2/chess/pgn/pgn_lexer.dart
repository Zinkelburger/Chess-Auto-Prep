import 'pgn_token.dart';

/// Cuts one game's PGN text into tokens.
///
/// Every character is looked at once and no suffix of the text is ever
/// copied, so a megabyte-long single-line game costs what its length says.
/// dartchess re-substrings the remainder at every `{`, which turns one such
/// game into minutes of work.
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

/// Games spell a ply where nobody moved four ways. `0000` is why move
/// numbers are read before words: `10000.` is move ten thousand, not a null
/// move with a dot after it.
const _nullMoves = {'--', 'Z0', '0000', '@@@@'};

const _terminations = {'1-0', '0-1', '1/2-1/2'};

/// Standard algebraic notation, including the long form `e2-e4`, crazyhouse
/// drops and both spellings of castling. Anchored, so a word is a move only
/// when the whole of it is one.
final _san = RegExp(
  r'^(?:[NBKRQ]?[a-h]?[1-8]?[-x]?[a-h][1-8](?:=?[nbrqkNBRQK])?'
  r'|[pnbrqkPNBRQK]?@[a-h][1-8]|O-O-O|0-0-0|O-O|0-0)[+#]?$',
);

const _tab = 0x09;
const _lf = 0x0A;
const _cr = 0x0D;
const _space = 0x20;
const _bang = 0x21;
const _quote = 0x22;
const _dollar = 0x24;
const _percent = 0x25;
const _openParen = 0x28;
const _closeParen = 0x29;
const _star = 0x2A;
const _dot = 0x2E;
const _zero = 0x30;
const _nine = 0x39;
const _semicolon = 0x3B;
const _question = 0x3F;
const _openBracket = 0x5B;
const _backslash = 0x5C;
const _closeBracket = 0x5D;
const _openBrace = 0x7B;
const _closeBrace = 0x7D;
const _bom = 0xFEFF;

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
    if (c == _lf) {
      i++;
      lineStart = true;
      return null;
    }
    if (_isBlank(c)) {
      i++;
      return null;
    }
    final fresh = lineStart;
    lineStart = false;
    if (fresh && c == _percent) return _escapeLine();
    if (header && c == _openBracket) return _headerLine();
    header = false;
    return _moveToken(c);
  }

  PgnToken _escapeLine() {
    final start = i;
    final inHeader = header;
    final (line, newline) = _restOfLine();
    return inHeader
        ? HeaderLineToken(start, i, line, newline)
        : EscapeLineToken(start);
  }

  PgnToken _headerLine() {
    final tag = _tag();
    if (tag != null) return tag;
    final start = i;
    final (line, newline) = _restOfLine();
    return HeaderLineToken(start, i, line, newline);
  }

  /// One `[Key "value"]`, or null when the text at [i] is not one; on null
  /// nothing has been consumed.
  TagToken? _tag() {
    final start = i;
    var j = _keyEnd(i + 1);
    if (j == i + 1) return null;
    final key = text.substring(i + 1, j);
    final spaced = j;
    while (j < text.length && _isBlank(text.codeUnitAt(j))) {
      j++;
    }
    if (j == spaced || j >= text.length || text.codeUnitAt(j) != _quote) {
      return null;
    }
    final valueStart = j + 1;
    final valueEnd = _valueEnd(valueStart);
    if (valueEnd < 0 || valueEnd + 1 >= text.length) return null;
    if (text.codeUnitAt(valueEnd + 1) != _closeBracket) return null;
    i = valueEnd + 2;
    final value = unescapedTagValue(text.substring(valueStart, valueEnd));
    final newline = _lineEnding();
    return TagToken(start, i, key, value, newline);
  }

  int _keyEnd(int from) {
    var j = from;
    while (j < text.length && _isKeyChar(text.codeUnitAt(j))) {
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
      if (c == _lf) return -1;
      if (c == _quote) return j;
      if (c == _backslash &&
          (j + 1 >= text.length || text.codeUnitAt(j + 1) == _lf)) {
        return -1;
      }
      j += c == _backslash ? 2 : 1;
    }
    return -1;
  }

  /// The line ending after the tag just read, consumed; `\n` when something
  /// else follows on the same line, which is left where it is.
  String _lineEnding() {
    var j = i;
    while (j < text.length && _isBlank(text.codeUnitAt(j))) {
      j++;
    }
    if (j >= text.length) {
      i = j;
      return '';
    }
    if (text.codeUnitAt(j) != _lf) return '\n';
    final ending = j > i && text.codeUnitAt(j - 1) == _cr ? '\r\n' : '\n';
    i = j + 1;
    lineStart = true;
    return ending;
  }

  /// The rest of the line from [i] without its ending, and that ending;
  /// [i] is left on the next line.
  (String, String) _restOfLine() {
    final found = text.indexOf('\n', i);
    final end = found < 0 ? text.length : found;
    final carriage = end > i && text.codeUnitAt(end - 1) == _cr;
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
      case _openBrace:
        return _braceComment();
      case _semicolon:
        return _lineComment();
      case _openParen:
        i++;
        return VariationOpen(start);
      case _closeParen:
        i++;
        return VariationClose(start);
      case _dollar:
        return _numericNag();
      case _bang || _question:
        return _glyphNag();
      case _star:
        i++;
        return TerminationToken(start, '*');
      case _dot:
        return _dots();
    }
    final number = _isDigit(c) ? _moveNumber() : null;
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
    while (j < text.length && j - start <= 4 && _isDigit(text.codeUnitAt(j))) {
      j++;
    }
    i = j;
    if (j == start + 1) return UnknownTextToken(start, r'$');
    return NagToken(start, int.parse(text.substring(start + 1, j)));
  }

  PgnToken _glyphNag() {
    final start = i;
    var j = i + 1;
    if (j < text.length && _isGlyph(text.codeUnitAt(j))) j++;
    i = j;
    return NagToken(start, _glyphValue(text.substring(start, j)));
  }

  PgnToken _dots() {
    final start = i;
    while (i < text.length && text.codeUnitAt(i) == _dot) {
      i++;
    }
    return MoveNumberToken(start);
  }

  /// `12.` or `12...`, or null when the digits are not a move number after
  /// all; on null nothing has been consumed.
  MoveNumberToken? _moveNumber() {
    final start = i;
    var j = i;
    while (j < text.length && _isDigit(text.codeUnitAt(j))) {
      j++;
    }
    if (j >= text.length || text.codeUnitAt(j) != _dot) return null;
    while (j < text.length && text.codeUnitAt(j) == _dot) {
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
    while (i < text.length && _isWordChar(text.codeUnitAt(i))) {
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

/// A tag value as prose: `\"` is a quote and `\\` a backslash. Any other
/// backslash is not an escape and keeps both of its characters, so a value
/// the file spelled with a bare backslash survives being read.
String unescapedTagValue(String value) {
  if (!value.contains(r'\')) return value;
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    final next = i + 1 < value.length ? value[i + 1] : '';
    final escapes = char == r'\' && (next == r'\' || next == '"');
    out.write(escapes ? next : char);
    if (escapes) i++;
  }
  return out.toString();
}

int _glyphValue(String glyph) => switch (glyph) {
  '!' => 1,
  '?' => 2,
  '!!' => 3,
  '??' => 4,
  '!?' => 5,
  '?!' => 6,
  _ => 0,
};

bool _isDigit(int c) => c >= _zero && c <= _nine;

bool _isGlyph(int c) => c == _bang || c == _question;

/// Space, tab, carriage return, form feed and a byte-order mark: everything
/// that separates tokens without ending a line.
bool _isBlank(int c) =>
    c == _space || c == _tab || c == _cr || c == 0x0B || c == 0x0C || c == _bom;

/// Letters, digits and the punctuation real exports put in a tag name.
bool _isKeyChar(int c) =>
    _isLetter(c) ||
    _isDigit(c) ||
    c == 0x5F || // _
    c == 0x2B || // +
    c == 0x23 || // #
    c == 0x3D || // =
    c == 0x3A || // :
    c == 0x2D; //  -

bool _isLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// What a move, a result or a null move can be made of. `.` is not in it, so
/// `1.e4` splits into a number and a move on its own.
bool _isWordChar(int c) =>
    _isLetter(c) ||
    _isDigit(c) ||
    c == 0x2B || // +
    c == 0x23 || // #
    c == 0x3D || // =
    c == 0x2D || // -
    c == 0x2F || // /
    c == 0x40 || // @
    c == 0x5F; //  _

/// Whether a `{}` comment is still open at the end of the run [start]–[end],
/// given that [commented] says whether one was open before it.
///
/// Open or closed, never a count: PGN comments do not nest, so a `}` inside
/// one ends it and a `{` inside one is text. Cutting a file into games needs
/// this before it can trust a line that starts with `[Event`.
bool commentOpenAfter(String text, int start, int end, bool commented) {
  var open = commented;
  for (var i = start; i < end; i++) {
    final unit = text.codeUnitAt(i);
    if (open ? unit == _closeBrace : unit == _openBrace) open = !open;
  }
  return open;
}

/// Whether [c] separates tokens without ending a line.
bool isTokenBlank(int c) => _isBlank(c);
