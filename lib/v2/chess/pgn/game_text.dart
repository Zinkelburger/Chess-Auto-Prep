import 'dart:convert';

import 'game_tree.dart';
import 'move_text.dart';

/// One line of a game's header block, kept in the order the file has it.
///
/// A chapter game carries tags no PGN model knows — `LineID`, the SM-2 review
/// state, `CumProb` — and losing one of them orphans the line, so the header is
/// a list rather than a set of fields. A line that is not a tag at all is kept
/// for the same reason: stopping at it would drop every tag below it too.
sealed class PgnHeader {
  const PgnHeader();

  /// The line as it belongs in the file.
  String get text;

  @override
  String toString() => text;
}

/// One `[Key "value"]` tag.
final class PgnTag extends PgnHeader {
  const PgnTag(this.key, this.value);

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
  const UnparsedHeader(this.text);

  @override
  final String text;
}

/// One game as the file holds it: [text] is its verbatim source with no
/// trailing whitespace, [trailer] is the whitespace that separates it from
/// the next game, so the two concatenated give the source span back.
typedef GameSpan = ({String text, String trailer});

/// Cuts chapter text into the `//` preamble and its games.
///
/// A game starts at a line whose first non-blank characters are `[Event `.
/// The trailing space is load-bearing: a bare `[Event` prefix also matches
/// the `[EventDate "…"]` that course exports carry, and cutting there splits
/// every game in two.
({String preamble, List<GameSpan> games}) splitChapterText(String text) {
  final starts = _gameStarts(text);
  if (starts.isEmpty) return (preamble: text, games: const []);
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
  while (lineStart <= text.length) {
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    if (_isEventLine(text, lineStart, lineEnd)) starts.add(lineStart);
    lineStart = lineEnd + 1;
  }
  return starts;
}

bool _isEventLine(String text, int start, int end) {
  var i = start;
  while (i < end && _isBlank(text.codeUnitAt(i))) {
    i++;
  }
  return i < end && text.startsWith('[Event ', i);
}

/// Space, tab, carriage return or a byte-order mark.
bool _isBlank(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0D || unit == 0xFEFF;

/// A tag name is letters, digits and the punctuation course exports use;
/// a value may escape a quote or a backslash, so `"` alone cannot end it.
final _tagLine = RegExp(
  r'^\s*\[([A-Za-z0-9_+#=:-]+)\s+"((?:[^"\\]|\\.)*)"\]\s*$',
);

/// The header block at the top of [gameText], in file order.
///
/// The block ends at the first blank line, which is what separates a header
/// from its movetext, or at the first line that is neither bracketed nor a `%`
/// escape, so a game written without that blank line does not swallow its
/// moves. Every line before that is kept, parsed as a [PgnTag] where it can be
/// and as an [UnparsedHeader] where it cannot.
List<PgnHeader> readTags(String gameText) {
  final header = <PgnHeader>[];
  for (final line in const LineSplitter().convert(gameText)) {
    final match = _tagLine.firstMatch(line);
    if (match != null) {
      header.add(PgnTag(match.group(1)!, _unescaped(match.group(2)!)));
      continue;
    }
    final rest = line.trimLeft();
    if (rest.isEmpty || !(rest.startsWith('[') || line.startsWith('%'))) break;
    header.add(UnparsedHeader(line));
  }
  return List.unmodifiable(header);
}

/// The value of the first tag named [key], or null.
String? tagValue(List<PgnHeader> header, String key) {
  for (final line in header) {
    if (line is PgnTag && line.key == key) return line.value;
  }
  return null;
}

/// [header] then [tree] as one game's text: the header lines in the order
/// they are given, a blank line, and the movetext on one line ending with the
/// value of the `Result` tag.
String writeGameText(List<PgnHeader> header, GameTree tree) {
  final lines = [for (final line in header) line.text];
  final moves = writeMoveText(tree, result: tagValue(header, 'Result') ?? '*');
  return '${lines.join('\n')}\n\n$moves';
}

/// PGN escapes two characters inside a tag value and no others: a backslash
/// and a quote, each with a backslash in front of it.
String _escaped(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

String _unescaped(String value) {
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
