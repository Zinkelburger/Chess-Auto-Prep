// How often keeping downloaded games reads and writes the file, against a
// store whose answers the test writes.
import 'dart:io';

import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/my_games_fixture.dart';
import '../support/scripted_store.dart';

void main() {
  late Directory folder;
  late ScriptedDocumentStore store;
  late GamesCache cache;
  final when = DateTime(2026, 11, 12);

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('my-games-keep-');
    store = ScriptedDocumentStore();
    cache = GamesCache(store, folder: folder.path);
  });
  tearDown(() => folder.delete(recursive: true));

  test('games that land are read once and written once', () async {
    expect(
      await cache.keep(GameSite.lichess, 'me', [scholarsMate], when),
      isA<GamesKept>(),
    );
    expect(store.opens, 1);
    expect(
      await cache.keep(GameSite.lichess, 'me', [quietChesscomGame], when),
      isA<GamesKept>(),
    );
    expect(store.opens, 2);
    expect(store.requestedSaves, hasLength(1));
  });

  test('a file that may only be read is not tried again', () async {
    store.documents[cache.refFor(GameSite.lichess, 'me')] = const Opened(
      '',
      Revision('ab12'),
      readOnly: 'its encoding was guessed',
    );
    expect(
      await cache.keep(GameSite.lichess, 'me', [scholarsMate], when),
      isA<GamesNotKept>(),
    );
    expect(store.opens, 1);
  });

  test(
    'a file that keeps changing under the write is tried three times',
    () async {
      store.documents[cache.refFor(GameSite.lichess, 'me')] = const Opened(
        '$scholarsMate\n',
        Revision('ab12'),
      );
      store.saves.addAll(const [
        Conflict(null),
        Conflict(null),
        Conflict(null),
      ]);
      expect(
        await cache.keep(GameSite.lichess, 'me', [quietChesscomGame], when),
        isA<GamesNotKept>(),
      );
      expect(store.requestedSaves, hasLength(3));
    },
  );

  test('the book check reads an account\'s newest two hundred games', () {
    expect(bookCheckWindow, 200);
  });
}
