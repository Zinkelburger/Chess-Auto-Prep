/// Small header edits on the text of one PGN game, for the edits that pin
/// what a line shows into its own headers before its file changes.
library;

/// The `[Event "…"]` header line.
final RegExp eventHeaderPattern = RegExp(r'^\[Event .*\]$', multiLine: true);

/// The value of the `[key "…"]` header in [gameText], or null.
String? pgnHeaderValue(String gameText, String key) => RegExp(
  '^\\[$key\\s+"([^"]*)"\\]\$',
  multiLine: true,
).firstMatch(gameText)?.group(1);

/// [gameText] with [headers] (one or more header lines) added straight after
/// its `[Event]` line, or at the top when it has none.
String insertHeadersAfterEvent(String gameText, String headers) {
  final event = eventHeaderPattern.firstMatch(gameText);
  return event == null
      ? '$headers\n$gameText'
      : gameText.replaceRange(event.end, event.end, '\n$headers');
}
