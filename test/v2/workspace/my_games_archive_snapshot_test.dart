import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/game_store.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/workspace/local_games.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../storage/store_fixture.dart';
import '../support/my_games_fixture.dart';
import '../storage/game_store_test.dart' show create, insert;

const _download = '[Event "Downloaded"]\n\n1. h4 h5 *';
const _newArchive = '[Event "New archive"]\n\n1. f4 f5 *';

void main() {
  for (final absent in [false, true]) {
    test(
      'archive ${absent ? "creation" : "WAL commit"} during build revokes the whole answer',
      () async {
        final disk = await StoreFixture.create();
        addTearDown(disk.dispose);
        final path = p.join(disk.support.path, 'app_games.db');
        Database? writer;
        if (!absent) {
          writer = create(path)..execute('PRAGMA wal_autocheckpoint = 0');
        }
        addTearDown(() => writer?.close());
        final archive = _HeldRead(SqliteGameStore(path));
        final accounts = MemoryAccounts({
          GameSite.lichess: const Account('Me'),
        });
        final cache = GamesCache(
          disk.store,
          folder: p.join(disk.documents.path, 'games_library'),
        );
        await disk.put(cache.refFor(GameSite.lichess, 'Me'), _download);
        final tree = MyGamesTree(
          accounts: accounts,
          cache: cache,
          store: archive,
          files: ChapterDirectory(
            Directory(p.join(disk.documents.path, 'repertoires')),
            recovery: disk.store.recovery,
          ),
        );
        addTearDown(tree.dispose);
        tree.want();
        await archive.entered.future;
        writer ??= create(path)..execute('PRAGMA wal_autocheckpoint = 0');
        insert(writer, 'tactics', 'later', _newArchive, playedAt: 100);
        archive.release.complete();
        await _settled(tree);
        expect(tree.state, isA<TreeFailed>());
        expect(tree.answerAt(Fen.initial), isNull);
        tree.forget();
        tree.want();
        await _settled(tree);
        expect(tree.state, isA<TreeBuilt>());
        final rebuilt = tree.answerAt(Fen.initial)!;
        expect(
          rebuilt.moves.map((move) => move.uci),
          containsAll(['f2f4', 'h2h4']),
        );
        tree.forget();
        tree.want();
        await _settled(tree);
        expect(
          tree.answerAt(Fen.initial)!.moves.map((move) => move.uci),
          rebuilt.moves.map((move) => move.uci),
        );
      },
      skip: !Platform.isLinux,
    );
  }
}

Future<void> _settled(MyGamesTree tree) async {
  while (tree.state is TreeReading) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _HeldRead implements GameStore {
  _HeldRead(this.store);
  final GameStore store;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<StoredGamesRead> read(Set<String> collections) async {
    final read = await store.read(collections);
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return read;
  }
}
