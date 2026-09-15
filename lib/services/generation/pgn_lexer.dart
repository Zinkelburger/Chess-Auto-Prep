/// PGN lexing: splitting a file into games and a movetext into SAN tokens.
///
/// Deliberately lenient and allocation-light: the frequency scanner runs
/// this over every byte of a multi-million-game database, and real files
/// omit blank lines between games, nest variations and carry mojibake
/// headers.  Nothing here validates chess; it only finds the tokens.
library;

/// One game as the splitter found it: its tag pairs and the raw movetext
/// (comments, variations and result token included).
class PgnGame {
  final Map<String, String> headers;
  final String movetext;
  const PgnGame({required this.headers, required this.movetext});
}

final _headerPattern = RegExp(r'^\[(\w+)\s+"(.*)"\]$');

/// Incremental PGN game splitter: feed it lines, receive games.
///
/// Splits on the header/movetext boundary and tolerates missing blank lines
/// between games, which hand-edited and scraped files routinely omit.  The
/// state machine is the same one [splitPgnGames] runs over a whole string;
/// exposing it line by line is what lets the scanner stream a file.
class PgnGameSplitter {
  PgnGameSplitter(this._onGame);

  final void Function(PgnGame game) _onGame;

  Map<String, String> _headers = <String, String>{};
  final StringBuffer _movetext = StringBuffer();
  bool _inMovetext = false;

  void addLine(String line) {
    final trimmed = line.trim();

    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      if (_inMovetext) _flush();
      final match = _headerPattern.firstMatch(trimmed);
      if (match != null) _headers[match.group(1)!] = match.group(2)!;
    } else if (trimmed.isEmpty) {
      if (_headers.isNotEmpty && !_inMovetext) {
        _inMovetext = true;
      } else if (_inMovetext) {
        _flush();
      }
    } else {
      _inMovetext = true;
      if (_movetext.isNotEmpty) _movetext.write(' ');
      _movetext.write(trimmed);
    }
  }

  /// Emit the game in progress, if any.  Call once after the last line.
  void close() => _flush();

  void _flush() {
    if (_movetext.isEmpty) return;
    _onGame(PgnGame(headers: _headers, movetext: _movetext.toString()));
    _headers = <String, String>{};
    _movetext.clear();
    _inMovetext = false;
  }
}

/// Split a PGN string into games.  See [PgnGameSplitter].
List<PgnGame> splitPgnGames(String pgn) {
  final games = <PgnGame>[];
  final splitter = PgnGameSplitter(games.add);
  var start = 0;
  while (start <= pgn.length) {
    var end = pgn.indexOf('\n', start);
    if (end < 0) end = pgn.length;
    splitter.addLine(pgn.substring(start, end));
    start = end + 1;
  }
  splitter.close();
  return games;
}

/// Tokenize movetext, skipping comments, variations, and NAGs.
///
/// Works on code units: `movetext[i]` allocates a one-character string, and
/// this runs over every byte of movetext in a multi-million-game database.
List<String> tokenizeMovetext(String movetext) {
  final tokens = <String>[];
  final len = movetext.length;
  var i = 0;

  while (i < len) {
    final ch = movetext.codeUnitAt(i);

    if (_isWhitespace(ch)) {
      i++;
      continue;
    }
    if (ch == _leftBrace) {
      while (i < len && movetext.codeUnitAt(i) != _rightBrace) {
        i++;
      }
      if (i < len) i++;
      continue;
    }
    if (ch == _leftParen) {
      var depth = 1;
      i++;
      while (i < len && depth > 0) {
        final c = movetext.codeUnitAt(i);
        if (c == _leftParen) depth++;
        if (c == _rightParen) depth--;
        i++;
      }
      continue;
    }
    if (ch == _dollar) {
      i++;
      while (i < len && _isDigit(movetext.codeUnitAt(i))) {
        i++;
      }
      continue;
    }

    final start = i;
    while (i < len && !_isTokenBoundary(movetext.codeUnitAt(i))) {
      i++;
    }
    tokens.add(movetext.substring(start, i));
  }
  return tokens;
}

const int _space = 0x20;
const int _tab = 0x09;
const int _cr = 0x0D;
const int _lf = 0x0A;
const int _leftBrace = 0x7B;
const int _rightBrace = 0x7D;
const int _leftParen = 0x28;
const int _rightParen = 0x29;
const int _dollar = 0x24;
const int _dot = 0x2E;

bool _isWhitespace(int c) => c == _space || c == _tab || c == _cr || c == _lf;

bool _isTokenBoundary(int c) =>
    _isWhitespace(c) || c == _leftBrace || c == _leftParen;

bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

/// Whether [token] is a PGN game-termination marker.
bool isResultToken(String token) =>
    token == '1-0' || token == '0-1' || token == '1/2-1/2' || token == '*';

/// Extract a SAN move from a movetext token (`1.e4`, `12.Nf3`, `1...c5`).
/// Returns null for a bare move number.
String? tokenToSan(String token) {
  if (token.isEmpty) return null;

  var i = 0;
  while (i < token.length && _isDigit(token.codeUnitAt(i))) {
    i++;
  }
  if (i == 0) return token;
  if (i >= token.length) return null;
  if (token.codeUnitAt(i) != _dot) return token;
  while (i < token.length && token.codeUnitAt(i) == _dot) {
    i++;
  }
  return i >= token.length ? null : token.substring(i);
}
