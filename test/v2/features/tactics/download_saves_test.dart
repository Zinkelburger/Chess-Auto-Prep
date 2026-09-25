import 'dart:io';

import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/features/tactics/download_saves.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/my_games_fixture.dart';
import '../../support/scripted_store.dart';

void main() {
  late Directory folder;
  late ScriptedDocumentStore documents;
  late GamesCache cache;
  late MemoryAccounts accounts;
  late PendingWrites pending;
  late DownloadSaves saves;
  final when = DateTime(2026, 9, 24);
  setUp(() {
    folder = Directory.systemTemp.createTempSync('download-saves-');
    documents = ScriptedDocumentStore();
    cache = GamesCache(documents, folder: folder.path);
    accounts = MemoryAccounts({GameSite.lichess: const Account('Me')});
    pending = PendingWrites();
    saves = DownloadSaves(cache, accounts, pending);
  });
  tearDown(() => folder.deleteSync(recursive: true));

  test(
    'registry owns frozen accepted HTTP result after caller goes away',
    () async {
      documents.creates.add(const IoFailure('full'));
      final fetched = [scholarsMate];
      expect(
        await saves.accept(GameSite.lichess, 'Me', fetched, when),
        isA<GamesNotKept>(),
      );
      fetched.clear();
      // No method on the original owner is necessary for shutdown retry.
      await pending.retry(cache.refFor(GameSite.lichess, 'Me'));
      expect(await cache.all(GameSite.lichess, 'Me'), [scholarsMate]);
      expect(accounts.accounts[GameSite.lichess]!.downloaded, when);
      expect(await pending.settle(), isNull);
    },
  );

  test(
    'successor HTTP result is retained behind an earlier failed save',
    () async {
      documents.creates.add(const IoFailure('full'));
      await saves.accept(GameSite.lichess, 'Me', [scholarsMate], when);
      expect(
        await saves.accept(GameSite.lichess, 'Me', [quietChesscomGame], when),
        isA<GamesNotKept>(),
      );
      await saves.retry();
      expect(await cache.all(GameSite.lichess, 'Me'), [
        scholarsMate,
        quietChesscomGame,
      ]);
      expect(await pending.settle(), isNull);
    },
  );

  test(
    'retry of a saved old corpus never stamps a replacement account',
    () async {
      final stamp = Directory(
        '${cache.refFor(GameSite.lichess, 'Me').path}.fetched',
      )..createSync();
      expect(
        await saves.accept(GameSite.lichess, 'Me', [scholarsMate], when),
        isA<GamesNotKept>(),
      );
      await accounts.setUsername(GameSite.lichess, 'New');
      stamp.deleteSync();
      await pending.retry(cache.refFor(GameSite.lichess, 'Me'));
      expect(accounts.accounts[GameSite.lichess]!.username, 'New');
      expect(accounts.accounts[GameSite.lichess]!.downloaded, isNull);
      expect(await pending.settle(), isNull);
    },
  );

  test(
    'unknown create acknowledgement retries already installed games once',
    () async {
      documents.documents[cache.refFor(GameSite.lichess, 'Me')] = Opened(
        '$scholarsMate\n',
        scriptedRevision('$scholarsMate\n'),
      );
      final stamp = Directory(
        '${cache.refFor(GameSite.lichess, 'Me').path}.fetched',
      )..createSync();
      await saves.accept(GameSite.lichess, 'Me', [
        scholarsMate,
        scholarsMate,
      ], when);
      stamp.deleteSync();
      await saves.retry();
      expect(await cache.all(GameSite.lichess, 'Me'), [scholarsMate]);
      expect(documents.requestedSaves, isEmpty);
    },
  );
}
