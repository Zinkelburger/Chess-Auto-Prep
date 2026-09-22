// The orderings behind the PGN viewer's sort modes.

import 'package:chess_auto_prep/chess_core/pgn/pgn_game_sorting.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:flutter_test/flutter_test.dart';

PgnGameEntry _game(String name, {String? date, int rating = 0}) => PgnGameEntry(
  headers: {'White': name, 'Date': ?date},
  pgnText: '',
  studyRating: rating,
);

List<String> _names(List<PgnGameEntry> games) => [
  for (final g in games) g.headers['White']!,
];

void main() {
  test('newest first, with undated games last', () {
    final games = [
      _game('undated'),
      _game('old', date: '2020.01.01'),
      _game('new', date: '2026.09.01'),
      _game('unknown', date: '????.??.??'),
    ];

    sortGamesInPlace(games, GameSortMode.dateDesc);

    expect(_names(games).take(2), ['new', 'old']);
    expect(_names(games).skip(2), containsAll(['undated', 'unknown']));
  });

  test('ratings sort both ways with unrated games in the middle', () {
    final games = [
      _game('five', rating: 5),
      _game('unrated'),
      _game('one', rating: 1),
      _game('four', rating: 4),
    ];

    sortGamesInPlace(games, GameSortMode.ratingDesc);
    expect(_names(games), ['five', 'four', 'unrated', 'one']);

    sortGamesInPlace(games, GameSortMode.ratingAsc);
    expect(_names(games), ['one', 'unrated', 'four', 'five']);
  });

  test('file order leaves the list alone', () {
    final games = [_game('b', rating: 2), _game('a', rating: 5)];
    sortGamesInPlace(games, GameSortMode.fileOrder);
    expect(_names(games), ['b', 'a']);
  });
}
