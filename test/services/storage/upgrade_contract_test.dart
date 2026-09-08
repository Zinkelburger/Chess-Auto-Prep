import 'dart:io';

import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('upgrade-contract-');
    path = p.join(dir.path, 'games.db');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'frozen v1 games migrate, reopen and retain PGN, positions and metadata',
    () {
      final old = sqlite3.open(path);
      old.execute(
        File('test/fixtures/storage/app_games_v1.sql').readAsStringSync(),
      );
      final originalPgn = old.select('SELECT pgn FROM games').single['pgn'];
      old.close();
      var store = GameStore.open(path);
      expect(store.raw.select('PRAGMA user_version').single.columnAt(0), 2);
      expect(
        store.raw.select('SELECT pgn FROM games').single['pgn'],
        originalPgn,
      );
      expect(
        store.raw.select('SELECT game_id FROM positions').single['game_id'],
        42,
      );
      expect(
        store.raw
            .select('SELECT meta_json FROM collections')
            .single['meta_json'],
        '{"personal":true}',
      );
      store.close();
      final backup = sqlite3.open('$path.before-schema-2.sqlite');
      expect(backup.select('PRAGMA user_version').single.columnAt(0), 1);
      expect(
        backup.select('SELECT game_key FROM games').single['game_key'],
        'old-key',
      );
      backup.close();
      store = GameStore.open(path);
      expect(store.exportPgn('my-games'), contains('Keep my annotation'));
      store.close();
    },
  );

  test(
    'failed migration rolls schema and data back and keeps recovery snapshot',
    () {
      final old = sqlite3.open(path);
      old.execute(
        File('test/fixtures/storage/app_games_v1.sql').readAsStringSync(),
      );
      old.execute("UPDATE games SET headers_json = 'invalid json'");
      old.close();
      expect(() => GameStore.open(path), throwsFormatException);
      final intact = sqlite3.open(path);
      expect(intact.select('PRAGMA user_version').single.columnAt(0), 1);
      expect(
        intact.select('SELECT game_key FROM games').single['game_key'],
        'old-key',
      );
      expect(
        intact.select(
          "SELECT name FROM sqlite_master WHERE name = 'game_trash'",
        ),
        isEmpty,
      );
      intact.close();
      expect(File('$path.before-schema-2.sqlite').existsSync(), isTrue);
    },
  );

  for (final master in [false, true]) {
    test(
      'future ${master ? 'master' : 'user'} database is refused and unchanged',
      () {
        final future = sqlite3.open(path);
        future.execute(
          'PRAGMA user_version = 999; CREATE TABLE future_data(value TEXT);',
        );
        future.execute("INSERT INTO future_data VALUES ('precious')");
        future.close();
        final before = File(path).readAsBytesSync();
        expect(
          () => master ? MasterGamesDb.open(path) : GameStore.open(path),
          throwsStateError,
        );
        expect(File(path).readAsBytesSync(), before);
        expect(dir.listSync().whereType<File>().length, 1);
      },
    );
  }
}
