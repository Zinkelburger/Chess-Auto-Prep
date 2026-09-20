import 'game_tree.dart';
import 'move_text.dart';
import 'pgn_lexer.dart';

/// One line of a game's header block, kept in the order the file has it.
///
/// A chapter game carries tags no PGN model knows — `LineID`, the SM-2 review
/// state, `CumProb` — and losing one of them orphans the line, so the header is
/// a list rather than a set of fields. A line that is not a tag at all is kept
/// for the same reason: stopping at it would drop every tag below it too.
sealed class PgnHeader {
  const PgnHeader({this.newline = '\n'});

  /// The line ending this line had in the file. Real repertoire exports put
  /// CRLF on the tag lines and LF on everything else in the same game, so
  /// one ending per file would change bytes the edit never touched.
  final String newline;

  /// The line as it belongs in the file, without its ending.
  String get text;

  @override
  String toString() => text;
}

/// One `[Key "value"]` tag.
final class PgnTag extends PgnHeader {
  const PgnTag(this.key, this.value, {super.newline});

  final String key;

  /// The value as prose: `\"` in the file is a quote here and `\\` is a
  /// backslash. Writing escapes them again, so a value the file spelled with
  /// a bare backslash comes back escaped, which is what the standard asks
  /// for, and a value this app sets can hold a quote without cutting the
  /// rest of the header off.
  final String value;

  @override
  String get text => '[$key "${_escaped(value)}"]';
}

/// A header line this reader cannot parse — a `%` escape, a bracket somebody
/// mistyped — written back exactly as it was read.
final class UnparsedHeader extends PgnHeader {
  const UnparsedHeader(this.text, {super.newline});

  @override
  final String text;
}

/// One game as the file holds it: [text] is its verbatim source with no
/// trailing whitespace, [trailer] is the whitespace that separates it from
/// the next game, so the two concatenated give the source span back.
typedef GameSpan = ({String text, String trailer});

/// Cuts chapter text into the `//` preamble and its games.
///
/// A game starts at a line whose first non-blank characters are `[Event`
/// followed by whitespace, and that is not inside a `{}` comment. Both
/// conditions cost a game when they are wrong: `[EventDate "…"]`, which
/// course exports carry, would split every game in two, and a comment
/// quoting a header would split one game where it should not.
///
/// A byte-order mark at the very start belongs to the file, not to its first
/// game, so it goes into the preamble: a game the user edits is written
/// again from its model, and a mark left inside it would be written away.
({String preamble, List<GameSpan> games}) splitChapterText(String text) {
  final starts = _gameStarts(text);
  if (starts.isEmpty) return (preamble: text, games: const []);
  if (starts.first == 0 && text.startsWith('\uFEFF')) starts[0] = 1;
  final games = <GameSpan>[];
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : text.length;
    final span = text.substring(starts[i], end);
    final body = span.trimRight();
    games.add((text: body, trailer: span.substring(body.length)));
  }
  return (preamble: text.substring(0, starts.first), games: games);
}

List<int> _gameStarts(String text) {
  final starts = <int>[];
  var lineStart = 0;
  var commented = false;
  while (lineStart <= text.length) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    if (!commented && _isEventLine(text, lineStart, lineEnd)) {
      starts.add(lineStart);
    }
    commented = commentOpenAfter(text, lineStart, lineEnd, commented);
    lineStart = lineEnd + 1;
  }
  return starts;
}

bool _isEventLine(String text, int start, int end) {
  var i = start;
  while (i < end && isTokenBlank(text.codeUnitAt(i))) {
    i++;
  }
  const event = '[Event';
  return text.startsWith(event, i) &&
      i + event.length < end &&
      isTokenBlank(text.codeUnitAt(i + event.length));
}

/// The value of the first tag named [key], or null.
String? tagValue(List<PgnHeader> header, String key) {
  for (final line in header) {
    if (line is PgnTag && line.key == key) return line.value;
  }
  return null;
}

/// [header], [separator] and [tree] as one game's text: the header lines in
/// the order they are given with the endings they had, the whitespace that
/// stood between them and the moves, and the movetext on one line ending
/// with [terminator].
String writeGameText(
  List<PgnHeader> header,
  GameTree tree, {
  required String? terminator,
  required String separator,
}) {
  final buffer = StringBuffer();
  for (final line in header) {
    buffer
      ..write(line.text)
      ..write(line.newline);
  }
  return (buffer
        ..write(separator)
        ..write(writeMoveText(tree, terminator: terminator)))
      .toString();
}

/// PGN escapes two characters inside a tag value and no others: a backslash
/// and a quote, each with a backslash in front of it.
String _escaped(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
