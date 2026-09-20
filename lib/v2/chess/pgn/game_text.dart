import 'game_tree.dart';
import 'move_text.dart';
import 'pgn_chars.dart';

/// One line of a game's header block, kept in the order the file has it.
///
/// A chapter game carries tags no PGN model knows — `LineID`, the SM-2 review
/// state, `CumProb` — and losing one of them orphans the line, so the header is
/// a list rather than a set of fields. A line that is not a tag at all is kept
/// for the same reason: stopping at it would drop every tag below it too.
sealed class PgnHeader {
  const PgnHeader({this.trailer = '\n'});

  /// The whitespace between this line and whatever followed it. Real
  /// repertoire exports put CRLF on the tag lines and LF on everything else
  /// in the same game, and some put two tags on one line; keeping what was
  /// there is what stops an edit changing bytes it never touched.
  final String trailer;

  /// The line as it belongs in the file, without that whitespace.
  String get text;

  @override
  String toString() => text;
}

/// One `[Key "value"]` tag.
final class PgnTag extends PgnHeader {
  const PgnTag(this.key, this.value, {this.raw, super.trailer});

  final String key;

  /// The value as prose: `\"` in the file is a quote here and `\\` is a
  /// backslash. A value this app sets can hold a quote without cutting the
  /// rest of the header off, because writing escapes it again.
  final String value;

  /// The tag exactly as the file wrote it, when it came from a file.
  ///
  /// It is written back unchanged, so an edit to one move of a game does not
  /// also tidy its headers: a value spelled `a\b`, which the standard says
  /// to escape, stays `a\b` rather than becoming `a\\b`. A tag this app
  /// builds has none and is written in the standard form.
  final String? raw;

  @override
  String get text => raw ?? '[$key "${_escaped(value)}"]';
}

/// A header line this reader cannot parse — a `%` escape, a bracket somebody
/// mistyped — written back exactly as it was read.
final class UnparsedHeader extends PgnHeader {
  const UnparsedHeader(this.text, {super.trailer});

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
  while (i < end && isBlank(text.codeUnitAt(i))) {
    i++;
  }
  const event = '[Event';
  return text.startsWith(event, i) &&
      i + event.length < end &&
      isBlank(text.codeUnitAt(i + event.length));
}

/// Whether a `{}` comment is still open at the end of the run [start]–[end],
/// given that [commented] says whether one was open before it.
///
/// Open or closed, never a count: PGN comments do not nest, so a `}` inside
/// one ends it and a `{` inside one is text. Cutting a file into games needs
/// this before it can trust a line that starts with `[Event`.
///
/// Only the movetext can open one. A `{` inside a tag value — `[Event "a {b"]`
/// — or after a `;` is an ordinary character, and a file read as if it were a
/// comment would have every game below it swallowed into one blob that no
/// edit could ever touch again.
bool commentOpenAfter(String text, int start, int end, bool commented) {
  var open = commented;
  var i = start;
  while (i < end) {
    final unit = text.codeUnitAt(i);
    if (open) {
      if (unit == closeBrace) open = false;
      i++;
      continue;
    }
    if (unit == openBrace) {
      open = true;
      i++;
      continue;
    }
    if (unit == semicolon) return false;
    i = unit == quote ? _pastQuoted(text, i, end) : i + 1;
  }
  return open;
}

/// Just past the quoted value starting at [i]; a backslash escapes the
/// character after it, which is how a value holds a quote.
int _pastQuoted(String text, int i, int end) {
  var j = i + 1;
  while (j < end) {
    final unit = text.codeUnitAt(j);
    if (unit == backslash) {
      j += 2;
      continue;
    }
    if (unit == quote) return j + 1;
    j++;
  }
  return end;
}

/// The value of the first tag named [key], or null.
String? tagValue(List<PgnHeader> header, String key) {
  for (final line in header) {
    if (line is PgnTag && line.key == key) return line.value;
  }
  return null;
}

/// [header], [separator] and [tree] as one game's text: the header lines in
/// the order they are given with the whitespace that followed each of them,
/// whatever else stood between them and the moves, and the movetext on one
/// line ending with [terminator].
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
      ..write(line.trailer);
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
