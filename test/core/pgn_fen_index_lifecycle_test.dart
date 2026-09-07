import 'dart:io';

import 'package:chess_auto_prep/core/pgn/pgn_fen_index.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('fen_index_lifecycle');
    StorageFactory.instanceForTest = IOStorageService(documentsRoot: directory);
  });
  tearDown(() {
    StorageFactory.instanceForTest = null;
    directory.deleteSync(recursive: true);
  });
  const games = [
    (
      headers: <String, String>{'Event': 'test'},
      pgnText: '[Event "test"]\n\n1. e4 e5 *',
    ),
  ];

  test(
    'background codec round-trips and cancellation preserves pending persistence',
    () async {
      final file = File('${directory.path}/games.pgn')
        ..writeAsStringSync(games.first.pgnText);
      final index = PgnFenIndex(isActive: () => true, onChanged: () {});
      await index.build(games, filePath: file.path, gameTotal: 1);
      expect(index.value, isNotEmpty);
      final expected = index.value;
      file.writeAsStringSync('${games.first.pgnText}\n');
      index.markStale();
      index.cancel();
      await index.flushIfStale(filePath: file.path, gameTotal: 1);
      index.reset();
      await index.tryLoadPersisted(file.path, 1);
      expect(index.value, expected);
    },
  );

  test(
    'reset during build does not install or notify for the old collection',
    () async {
      var changes = 0;
      final index = PgnFenIndex(
        isActive: () => true,
        onChanged: () => changes++,
      );
      final pending = index.build(games, filePath: null, gameTotal: 1);
      index.reset();
      await pending;
      expect(changes, 0);
      expect(index.value, isNull);
    },
  );
}
