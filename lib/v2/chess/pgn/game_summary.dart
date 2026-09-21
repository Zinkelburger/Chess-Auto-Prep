import 'chapter_line.dart';
import 'game_text.dart';

/// What a game is, in the words a list or a heading has room for: who
/// played it, how it ended and where.
///
/// Read from the seven-tag roster. A file in the wild leaves tags out or
/// writes `?` where it knows nothing, and neither is a name, so a game with
/// no players is named after its event and, failing that, its place in the
/// file.
final class GameSummary {
  const GameSummary({
    required this.title,
    required this.result,
    required this.setting,
  });

  /// `White – Black`, else the event, else `Game N`.
  final String title;

  /// `1-0`, `0-1` or `½-½`; empty for a game with no result or an unfinished
  /// one, because `*` in a list is noise.
  final String result;

  /// The event and the year, or whichever of them the file gave, or empty.
  final String setting;

  /// The words a search over the games looks through, lowercased.
  String get searchText => '$title $result $setting'.toLowerCase();
}

/// The summary of the game at [index] of a file, counting from zero.
GameSummary summarizeGame(ChapterLine line, {required int index}) {
  final white = _known(tagValue(line.tags, 'White'));
  final black = _known(tagValue(line.tags, 'Black'));
  final event = _known(tagValue(line.tags, 'Event'));
  final players = white != null && black != null
      ? '$white – $black'
      : white ?? black;
  return GameSummary(
    title: players ?? event ?? 'Game ${index + 1}',
    result: _result(tagValue(line.tags, 'Result')),
    setting: [
      if (players != null && event != null) event,
      if (_year(tagValue(line.tags, 'Date')) case final year?) year,
    ].join(' · '),
  );
}

/// [value] trimmed, or null when the file wrote nothing or `?` there.
String? _known(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty || trimmed == '?' ? null : trimmed;
}

String _result(String? value) => switch (value?.trim()) {
  '1-0' => '1-0',
  '0-1' => '0-1',
  '1/2-1/2' => '½-½',
  _ => '',
};

/// The year of a `YYYY.MM.DD` date, or null when the file wrote `????`.
String? _year(String? date) {
  final year = _known(date)?.split('.').first;
  return year == null || year.length != 4 || int.tryParse(year) == null
      ? null
      : year;
}
