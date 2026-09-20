/// The characters PGN gives a meaning to, and what each group of them is.
///
/// They live apart from the scanner because the file splitter needs the same
/// answers before there is a game to scan, and two copies of "what counts as
/// whitespace" is two answers waiting to disagree.
library;

const tab = 0x09;
const lf = 0x0A;
const cr = 0x0D;
const space = 0x20;
const bang = 0x21;
const quote = 0x22;
const dollar = 0x24;
const percent = 0x25;
const openParen = 0x28;
const closeParen = 0x29;
const star = 0x2A;
const dot = 0x2E;
const zero = 0x30;
const nine = 0x39;
const semicolon = 0x3B;
const question = 0x3F;
const openBracket = 0x5B;
const backslash = 0x5C;
const closeBracket = 0x5D;
const openBrace = 0x7B;
const closeBrace = 0x7D;
const bom = 0xFEFF;

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

int glyphValue(String glyph) => switch (glyph) {
  '!' => 1,
  '?' => 2,
  '!!' => 3,
  '??' => 4,
  '!?' => 5,
  '?!' => 6,
  _ => 0,
};

bool isDigit(int c) => c >= zero && c <= nine;

bool isGlyph(int c) => c == bang || c == question;

/// Space, tab, carriage return, form feed and a byte-order mark: everything
/// that separates tokens without ending a line.
bool isBlank(int c) =>
    c == space || c == tab || c == cr || c == 0x0B || c == 0x0C || c == bom;

/// Letters, digits and the punctuation real exports put in a tag name.
bool isKeyChar(int c) =>
    isLetter(c) ||
    isDigit(c) ||
    c == 0x5F || // _
    c == 0x2B || // +
    c == 0x23 || // #
    c == 0x3D || // =
    c == 0x3A || // :
    c == 0x2D; //  -

bool isLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// What a move, a result or a null move can be made of. `.` is not in it, so
/// `1.e4` splits into a number and a move on its own.
bool isWordChar(int c) =>
    isLetter(c) ||
    isDigit(c) ||
    c == 0x2B || // +
    c == 0x23 || // #
    c == 0x3D || // =
    c == 0x2D || // -
    c == 0x2F || // /
    c == 0x40 || // @
    c == 0x5F; //  _

/// Whether [c] separates tokens without ending a line.
bool isTokenBlank(int c) => isBlank(c);

/// Whether [c] is whitespace of any kind, line endings included.
bool isGameWhitespace(int c) => isBlank(c) || c == lf;
