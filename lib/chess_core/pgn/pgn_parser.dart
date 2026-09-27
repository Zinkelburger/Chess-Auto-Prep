/// Single-game parsing boundary. Stored PGN bytes are never reformatted here.
library;

import 'package:dartchess/dartchess.dart';

/// The upstream parser consumes a physical line by repeatedly taking suffix
/// substrings around brace comments. An annotated megabyte-long line therefore
/// entails quadratic copying. Feed it bounded comment-bearing lines instead.
/// Explicit move-number tokens are discarded: upstream otherwise interprets
/// the digits in `10000.` as the null move `0000`. Headers, comments, results,
/// standalone null moves and the parser's node representation are preserved.
PgnGame<PgnNodeData> parsePgnGame(
  String text, {
  PgnHeaders Function() initHeaders = PgnGame.defaultHeaders,
}) => PgnGame.parsePgn(_boundCommentLines(text), initHeaders: initHeaders);

String _boundCommentLines(String text) {
  const budget = 4096;
  StringBuffer? output;
  var copied = 0;
  var lineStart = 0;
  var segmentStart = 0;
  var brace = false;
  var tag = false;
  var quoted = false;
  var escaped = false;
  var lineComment = false;
  for (var i = 0; i < text.length; i++) {
    final char = text.codeUnitAt(i);
    if (char == 10) {
      lineStart = segmentStart = i + 1;
      lineComment = false;
      continue;
    }
    if (lineComment) continue;
    if (brace) {
      if (char == 125) {
        brace = false;
        if (i - segmentStart >= budget) {
          output ??= StringBuffer();
          output.write(text.substring(copied, i + 1));
          // The leading space is intentional: an originally mid-line '%'
          // after this comment must not become a PGN escape-line marker.
          output.write('\n ');
          copied = i + 1;
          segmentStart = copied;
        }
      }
      continue;
    }
    if (tag) {
      if (escaped) {
        escaped = false;
      } else if (quoted && char == 92) {
        escaped = true;
      } else if (char == 34) {
        quoted = !quoted;
      } else if (!quoted && char == 93) {
        tag = false;
      }
      continue;
    }
    if (char == 37 &&
        (i == lineStart || (i == 1 && text.codeUnitAt(0) == 0xfeff))) {
      lineComment = true;
    } else if (char == 59) {
      lineComment = true;
    } else if (char == 91) {
      tag = true;
    } else if (char == 123) {
      brace = true;
    } else if (char >= 48 &&
        char <= 57 &&
        (i == 0 || _numberBoundary(text.codeUnitAt(i - 1)))) {
      var end = i + 1;
      while (end < text.length &&
          text.codeUnitAt(end) >= 48 &&
          text.codeUnitAt(end) <= 57) {
        end++;
      }
      if (end < text.length && text.codeUnitAt(end) == 46) {
        while (end < text.length && text.codeUnitAt(end) == 46) {
          end++;
        }
        output ??= StringBuffer();
        output.write(text.substring(copied, i));
        output.write(' ');
        copied = end;
        i = end - 1;
      }
    }
  }
  if (output == null) return text;
  output.write(text.substring(copied));
  return output.toString();
}

bool _numberBoundary(int char) =>
    char == 32 ||
    char == 9 ||
    char == 10 ||
    char == 13 ||
    char == 40 ||
    char == 41 ||
    char == 125 ||
    char == 0xfeff;
