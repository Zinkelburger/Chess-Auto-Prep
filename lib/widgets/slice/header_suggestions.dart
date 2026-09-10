import '../../models/pgn_filter_models.dart';

/// One original header spelling and the number of source games containing it.
typedef HeaderSuggestion = ({String value, int count});

/// Lazily indexes only fields the editor uses, once per game-list snapshot.
/// Values keep their original spelling; searching is literal and ignores case.
class HeaderSuggestions {
  HeaderSuggestions(this.games);

  final List<GameRecord> games;
  final _fields = <String, List<HeaderSuggestion>>{};

  List<HeaderSuggestion> matching(String field, String query) {
    final values = _fields.putIfAbsent(field, () => _index(field));
    final lower = query.toLowerCase();
    return [
      for (final value in values)
        if (value.value.toLowerCase().contains(lower)) value,
    ];
  }

  List<HeaderSuggestion> _index(String field) {
    final counts = <String, int>{
      if (field == 'Result') ...{'1-0': 0, '0-1': 0, '1/2-1/2': 0, '*': 0},
    };
    for (final game in games) {
      // A player appearing on both sides still occurs in just one game.
      final values = field == kPlayerHeaderField
          ? {game.headers['White'], game.headers['Black']}
          : {game.headers[field]};
      for (final value in values) {
        if (value == null || value.trim().isEmpty) continue;
        counts[value] = (counts[value] ?? 0) + 1;
      }
    }
    return [
      for (final entry in counts.entries)
        (value: entry.key, count: entry.value),
    ]..sort((a, b) {
      final frequency = b.count.compareTo(a.count);
      if (frequency != 0) return frequency;
      final name = a.value.toLowerCase().compareTo(b.value.toLowerCase());
      return name != 0 ? name : a.value.compareTo(b.value);
    });
  }
}
