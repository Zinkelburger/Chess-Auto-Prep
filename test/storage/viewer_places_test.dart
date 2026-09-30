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

/// A game with no id of its own, spelled as a file may spell it and as
/// v2 does not: `0-0`, a disambiguation it does not need, a promotion with
/// no `=` and checks with no `+`.
const _oddlySpelled = '''
[Event "Casual"]
[Date "2024.02.01"]
[White "White"]
[Black "Black"]
[Result "*"]
[SetUp "1"]
[FEN "8/4P3/2k5/8/8/8/8/RN2K2R w KQ - 0 1"]

1. 0-0 Kd5 2. Nbd2 Kc6 3. e8Q Kb6 4. Qb8 Kc5 *
''';

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
        text: '$threeGameFile\n$_oddlySpelled',
      );
      expect([for (final line in chapter.lines) readingGameKey(line)], stored);
    },
  );
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
