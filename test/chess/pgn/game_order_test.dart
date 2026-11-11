import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/game_order.dart';
import 'package:flutter_test/flutter_test.dart';

/// One game per entry, rated as the strings say (null leaves a tag out).
List<ChapterLine> rated(List<(String?, String?)> elos) => parseChapter(
  name: 'Games',
  text: [
    for (final (index, (white, black)) in elos.indexed)
      '[Event "G$index"]\n'
          '${white == null ? '' : '[WhiteElo "$white"]\n'}'
          '${black == null ? '' : '[BlackElo "$black"]\n'}'
          '\n1. e4 *\n',
  ].join('\n'),
).lines;

List<int> byRating(List<ChapterLine> lines, GameOrder order) =>
    orderGames(lines, [for (var i = 0; i < lines.length; i++) i], order);

void main() {
  test('unrated games come last, in file order', () {
    final lines = rated([(null, null), ('1500', null), (null, null)]);
    expect(byRating(lines, GameOrder.ratingDesc), [1, 0, 2]);
    expect(byRating(lines, GameOrder.ratingAsc), [1, 0, 2]);
  });

  test(
    'a rating of nothing, below nothing or past any number is no rating',
    () {
      final lines = rated([
        ('0', '2000'),
        ('1500', '1500'),
        ('-5', null),
        ('Infinity', null),
        ('1', null),
      ]);
      // 0 is FICS's guest: the game is rated 2000 by its other player.
      expect(byRating(lines, GameOrder.ratingDesc), [0, 1, 4, 2, 3]);
    },
  );
}
