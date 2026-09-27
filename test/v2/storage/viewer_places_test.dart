import 'dart:convert';
import 'package:chess_auto_prep/chess_core/pgn/game_identity.dart' as legacy;
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_order.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/v2/storage/viewer_places.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/viewer_fixture.dart';

void main() {
  test(
    'canonical identity matches old sessions on real PGN headers and moves',
    () async {
      final chapter = await readChapter(name: '', text: threeGameFile);
      for (final line in chapter.lines) {
        final tags = {
          for (final tag in line.tags.whereType<PgnTag>()) tag.key: tag.value,
        };
        expect(readingGameKey(line), legacy.canonicalGameKey(tags, line.text));
      }
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
