/// Searchable chapter navigation for the PGN collection counter.
library;

import 'game_nav_item.dart';

/// A chapter's games in the current filtered/sorted navigation order.
class GameNavChapter {
  final String? name;
  final List<int> gameIndices;

  const GameNavChapter({required this.name, required this.gameIndices});

  String get label => name ?? 'Other games';

  /// Repeated, non-contiguous chapter titles share one row. Null titles get
  /// a separate row so illustrative games remain reachable too.
  static List<GameNavChapter> fromGames(List<GameNavItem> games) {
    final groups = <String?, List<int>>{};
    for (var i = 0; i < games.length; i++) {
      (groups[games[i].chapter] ??= []).add(i);
    }
    return [
      for (final entry in groups.entries)
        GameNavChapter(
          name: entry.key,
          gameIndices: List.unmodifiable(entry.value),
        ),
    ];
  }
}

/// Event/site groups only help navigation when at least five games share them.
/// Keep years separate so annual events do not become one giant bucket.
List<GameNavChapter> gameBrowserGroups(List<GameNavItem> games) {
  if (games.any((game) => game.chapter != null)) {
    return GameNavChapter.fromGames(games);
  }
  String clean(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ||
            RegExp(r'^[?\s.]+$').hasMatch(text) ||
            text.toLowerCase() == 'unknown'
        ? ''
        : text;
  }

  final groups = <String, List<int>>{};
  for (var i = 0; i < games.length; i++) {
    final headers = games[i].headers;
    final event = clean(headers['Event']);
    final site = clean(headers['Site']);
    final place = event.isNotEmpty ? event : site;
    if (place.isEmpty) continue;
    final year =
        RegExp(r'^\d{4}').stringMatch(headers['EventDate'] ?? '') ??
        RegExp(r'^\d{4}').stringMatch(headers['Date'] ?? '');
    final label = year == null || place.contains(year) ? place : '$place $year';
    (groups[label] ??= []).add(i);
  }
  return [
    for (final entry in groups.entries)
      if (entry.value.length > 4)
        GameNavChapter(
          name: entry.key,
          gameIndices: List.unmodifiable(entry.value),
        ),
  ];
}
