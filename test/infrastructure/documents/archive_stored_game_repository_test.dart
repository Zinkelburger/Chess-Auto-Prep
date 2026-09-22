import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/infrastructure/documents/archive_stored_game_repository.dart';
import 'package:chess_auto_prep/services/game_store/game_store.dart';

void main() {
  test(
    'archive lookup is keyed and confined to the tactics collection',
    () async {
      final root = await Directory.systemTemp.createTemp('archive-repository-');
      final store = GameStore.open('${root.path}/games.db');
      addTearDown(() async {
        store.close();
        await root.delete(recursive: true);
      });
      const source = '[Event "Archive fixture"]\n[GameId "same"]\n\n1. d4 *';
      store.importPgn(source, collection: GameCollections.tactics);
      store.importPgn('[GameId "same"]\n\n1. e4 *', collection: 'other');
      final repository = ArchiveStoredGameRepository(() async => store);
      expect(await repository.findById('same'), source);
      expect(await repository.findById('missing'), isNull);
      expect(store.count(GameCollections.tactics), 1);
    },
  );

  test(
    'empty identity does not open the archive; open failure remains visible',
    () async {
      var opens = 0;
      final repository = ArchiveStoredGameRepository(() async {
        opens++;
        throw StateError('offline');
      });
      expect(await repository.findById(''), isNull);
      expect(opens, 0);
      await expectLater(repository.findById('known'), throwsStateError);
      expect(opens, 1);
    },
  );
}
