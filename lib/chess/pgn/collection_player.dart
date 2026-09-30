import 'package:dartchess/dartchess.dart' show Side;

import 'game_text.dart';

/// Whose side a collection's games are shown from: a collection that is one
/// player's games reads best from that player's chair, whichever colour
/// they had in each game.

/// Whose side the viewer shows each game of a file from.
sealed class Perspective {
  const Perspective();
}

/// The file's own player when it has one ([collectionPlayer]), else the
/// board as each game has it. What a file nobody chose for starts as.
final class FollowCollectionPlayer extends Perspective {
  const FollowCollectionPlayer();
}

/// Each game from [name]'s side, where they played it.
final class FollowPlayer extends Perspective {
  const FollowPlayer(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is FollowPlayer && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// Each game the way the board has it; nobody is followed.
final class FollowNobody extends Perspective {
  const FollowNobody();
}

/// The player at least four games in five of [games] are by — by the name
/// as written, ignoring case — or null for a single game, a match between
/// two players, or a collection of many. The old viewer's rule.
///
/// Example: twenty games, eighteen with `Carlsen, Magnus` as White or
/// Black, is Carlsen's collection; a ten-game match between Carlsen and
/// Nakamura has two such players and so none.
String? collectionPlayer(List<List<PgnHeader>> games) {
  if (games.length < 2) return null;
  final counts = playerCounts(games);
  final enough = (games.length * 0.8).ceil();
  final players = [
    for (final MapEntry(key: name, value: count) in counts.entries)
      if (count >= enough) name,
  ];
  return players.length == 1 ? players.single : null;
}

/// Every player of [games] by the number of games they are in, most first,
/// each under the spelling it first appears with.
Map<String, int> playerCounts(List<List<PgnHeader>> games) {
  final counts = <String, int>{};
  final spelling = <String, String>{};
  for (final tags in games) {
    final seen = <String>{};
    for (final field in const ['White', 'Black']) {
      final name = tagValue(tags, field)?.trim() ?? '';
      if (name.isEmpty || name == '?') continue;
      final key = name.toLowerCase();
      spelling.putIfAbsent(key, () => name);
      if (seen.add(key)) counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  final ranked = counts.keys.toList()
    ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  return {for (final key in ranked) spelling[key]!: counts[key]!};
}

/// The side [player] had in the game [tags] describe, or null when they
/// are not in it or are both players. The name as written wins; failing
/// that, the surname (what comes before a comma), so `Carlsen` finds
/// `Carlsen, Magnus`.
Side? sideOfPlayer(String player, List<PgnHeader> tags) {
  String norm(String? name) => (name ?? '').trim().toLowerCase();
  final wanted = norm(player);
  if (wanted.isEmpty || wanted == '?') return null;
  final white = norm(tagValue(tags, 'White'));
  final black = norm(tagValue(tags, 'Black'));
  final side = _oneOf(white == wanted, black == wanted);
  if (side != null || white == wanted) return side;
  String surname(String name) => name.split(',').first.trim();
  final name = surname(wanted);
  if (name.isEmpty) return null;
  return _oneOf(surname(white) == name, surname(black) == name);
}

Side? _oneOf(bool white, bool black) => white == black
    ? null
    : white
    ? Side.white
    : Side.black;
