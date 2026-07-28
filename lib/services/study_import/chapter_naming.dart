/// Naming imported chapters.
///
/// A study stores each chapter's name in its `[Event]` tag, so renaming a
/// chapter on import means rewriting that header before the PGN hits disk.
/// Downloaded games rarely arrive usefully named — every game in a
/// chessgames.com collection repeats the *tournament* in `[Event]` — so each
/// import path derives a name and stamps it in here.
library;

/// Replace (or insert) [gameText]'s `[Event]` tag with [event].
String withEventHeader(String gameText, String event) {
  final tag = '[Event "${escapeHeaderValue(event)}"]';
  final existing = RegExp(
    r'^\[Event\s+"(?:[^"\\]|\\.)*"\][ \t]*$',
    multiLine: true,
  );
  if (existing.hasMatch(gameText)) {
    return gameText.replaceFirst(existing, tag);
  }
  return '$tag\n$gameText';
}

/// Escape a PGN header value the way [StudyChapter.toPgn] does.
String escapeHeaderValue(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// A readable chapter name for one downloaded game, e.g.
/// `Fischer, R - Spassky, B, World Championship 1972 (1-0)`.
///
/// Everything is optional: whatever the headers actually carry gets used, and
/// [fallback] covers a game with no players at all. `?` is PGN's "unknown"
/// and is treated as absent.
String gameChapterName(
  Map<String, String> headers, {
  required String fallback,
}) {
  String? tag(String key) {
    final value = headers[key]?.trim();
    if (value == null || value.isEmpty || value == '?') return null;
    return value;
  }

  final white = tag('White');
  final black = tag('Black');
  final event = tag('Event');
  final result = tag('Result');
  final year = _year(tag('Date') ?? tag('EventDate') ?? tag('UTCDate'));

  final players = white != null && black != null
      ? '$white - $black'
      : (white ?? black);

  // The year is usually already inside a chessgames event name
  // ("World Championship 1972"); don't say it twice.
  final occasion = [
    ?event,
    if (year != null && (event == null || !event.contains(year))) year,
  ].join(' ');

  final head = [?players, if (occasion.isNotEmpty) occasion].join(', ');

  final name = head.isEmpty ? fallback : head;
  return result != null && result != '*' ? '$name ($result)' : name;
}

/// The 4-digit year in a PGN date (`1972.07.11`, `1972.??.??`, `1972`).
String? _year(String? date) {
  if (date == null) return null;
  final match = RegExp(r'^(\d{4})').firstMatch(date);
  return match?.group(1);
}
