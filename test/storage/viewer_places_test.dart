import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_order.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/storage/viewer_places.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/viewer_fixture.dart';

void main() {
  test(
    'canonical identity matches old sessions on real PGN headers and moves',
    () async {
      // The keys the old viewer stored for these games, recorded once.
      final stored =
          jsonDecode(
                await File(
                  'test/fixtures/legacy/viewer_game_keys.json',
                ).readAsString(),
              )
              as List;
      final chapter = await readChapter(
        name: '',
        text: '$threeGameFile\n$oddlySpelledGame',
      );
      expect([for (final line in chapter.lines) readingGameKey(line)], stored);
    },
  );
  test('a Lichess game keeps its key under the /game/ address', () async {
    final chapter = await readChapter(
      name: '',
      text:
          '[Event "a"]\n[Site "https://lichess.org/AbCd1234"]\n\n1. e4 *\n\n'
          '[Event "b"]\n[Site "https://lichess.org/game/AbCd1234/black"]\n\n'
          '1. e4 *\n',
    );
    expect(
      [for (final line in chapter.lines) readingGameKey(line)],
      ['https://lichess.org/AbCd1234', 'https://lichess.org/AbCd1234'],
    );
  });
  test(
    'loads existing session schema and saves under the same per-path key',
    () async {
      SharedPreferences.setMockInitialValues({
        'pgn_viewer.session:/games.pgn': jsonEncode({
          'gameIndex': 2,
          'gameKey': 'known',
          'ply': 3,
          'sort': 'dateDesc',
        }),
      });
      final store = PreferencesViewerPlaces();
      final place = await store.load('/games.pgn');
      expect(place!.game, 2);
      expect(place.path, NodePath.of([0, 0, 0]));
      expect(place.sort, GameOrder.dateDesc);
      await store.save('/games.pgn', place);
      expect((await store.load('/games.pgn'))!.key, 'known');
      expect(await store.load('/absent'), isNull);
    },
  );
}
