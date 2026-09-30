import 'dart:convert';

import 'package:chess_auto_prep/chess/pgn/collection_player.dart';
import 'package:chess_auto_prep/chess/pgn/game_order.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

List<PgnHeader> game(String white, String black) => [
  PgnTag('White', white),
  PgnTag('Black', black),
];

void main() {
  test('a collection is a player\'s when four games in five have them', () {
    final carlsen = [
      for (var i = 0; i < 4; i++) game('Carlsen, Magnus', 'Rival $i'),
      game('Other', 'Else'),
    ];
    expect(collectionPlayer(carlsen), 'Carlsen, Magnus');
    expect(collectionPlayer(carlsen.take(1).toList()), isNull);
    final match = [
      game('Carlsen, Magnus', 'Nakamura, Hikaru'),
      game('Nakamura, Hikaru', 'carlsen, magnus'),
    ];
    expect(collectionPlayer(match), isNull, reason: 'two players qualify');
    expect(playerCounts(match), {'Carlsen, Magnus': 2, 'Nakamura, Hikaru': 2});
  });

  test('a player\'s side is found by the name, else by the surname', () {
    final tags = game('Carlsen, Magnus', 'Nakamura, Hikaru');
    expect(sideOfPlayer('carlsen, magnus', tags), Side.white);
    expect(sideOfPlayer('Nakamura', tags), Side.black);
    expect(sideOfPlayer('Ding', tags), isNull);
    expect(sideOfPlayer('Carlsen', game('Carlsen, M', 'Carlsen, H')), isNull);
    expect(sideOfPlayer('', tags), isNull);
  });

  test('the followed player is kept with the file\'s reading place', () {
    for (final perspective in const [
      FollowPlayer('Carlsen, Magnus'),
      FollowNobody(),
      FollowCollectionPlayer(),
    ]) {
      final place = ReadingPlace(
        game: 0,
        key: 'k',
        path: const NodePath.root(),
        sort: GameOrder.fileOrder,
        perspective: perspective,
      );
      expect(
        ReadingPlace.decode(jsonEncode(place.json))!.perspective,
        perspective,
      );
    }
  });
}
