import 'dart:convert';

import 'game_tree.dart';
import 'move_text.dart';

/// One `[Key "value"]` tag, with the value exactly as the file spells it.
///
/// A chapter game carries tags no PGN model knows — `LineID`, the SM-2
/// review state, `CumProb` — and losing one of them orphans the line, so
/// they are kept as a list in file order rather than parsed into fields.
final class PgnTag {
  const PgnTag(this.key, this.value);

  final String key;
  final String value;

  @override
  String toString() => '[$key "$value"]';
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

final _tagLine = RegExp(r'^\s*\[(\w+)\s+"([^"]*)"\]\s*$');

/// The tags at the top of [gameText], in file order; reading stops at the
/// first line that is neither a tag nor blank.
List<PgnTag> readTags(String gameText) {
  final tags = <PgnTag>[];
  for (final line in const LineSplitter().convert(gameText)) {
    final match = _tagLine.firstMatch(line);
    if (match == null) {
      if (line.trim().isEmpty) continue;
      break;
    }
    tags.add(PgnTag(match.group(1)!, match.group(2)!));
  }
  return List.unmodifiable(tags);
}

/// The value of the first tag named [key], or null.
String? tagValue(List<PgnTag> tags, String key) {
  for (final tag in tags) {
    if (tag.key == key) return tag.value;
  }
  return null;
}

/// [tags] then [tree] as one game's text: the tags in the order they are
/// given, a blank line, and the movetext on one line ending with the value
/// of the `Result` tag.
String writeGameText(List<PgnTag> tags, GameTree tree) {
  final header = [for (final tag in tags) '[${tag.key} "${tag.value}"]'];
  final moves = writeMoveText(tree, result: tagValue(tags, 'Result') ?? '*');
  return '${header.join('\n')}\n\n$moves';
}
