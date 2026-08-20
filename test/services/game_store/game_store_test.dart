@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

const _lichess = '''
[Event "Rated blitz game"]
[Site "https://lichess.org/abc12345"]
[UTCDate "2025.06.01"]
[UTCTime "12:00:00"]
[White "me"]
[Black "them"]
[Result "1-0"]
[TimeControl "180+2"]
[WhiteElo "1900"]
[BlackElo "1850"]
[GameId "lichess_abc12345"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0''';

const _chesscom = '''
[Event "Live Chess"]
[Link "https://www.chess.com/game/live/999"]
[Date "2025.06.02"]
[White "them"]
[Black "me"]
[Result "0-1"]
[TimeControl "600"]
[GameId "chesscom_999"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 {[%eval 0.3]} Bc5 0-1''';

const _fromFen = '''
[Event "Study"]
[White "a"]
[Black "b"]
[Result "*"]
[SetUp "1"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]

1... c5 2. Nf3 *''';

void main() {
  late Directory tmp;
  late GameStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gamestore');
    store = GameStore.open('${tmp.path}/app_games.db');
  });
  tearDown(() async {
    store.close();
    await tmp.delete(recursive: true);
  });

  test('imports, keys, indexes headers and opening positions', () {
    final r = store.importPgn(
      '$_lichess\n\n$_chesscom\n\n$_fromFen',
      collection: GameCollections.tactics,
    );
    expect(r.inserted, 3);
    expect(store.count(GameCollections.tactics), 3);

    final g = store.byKey(GameCollections.tactics, 'lichess_abc12345')!;
    expect(g.white, 'me');
    expect(g.speed, GameSpeed.blitz);
    expect(g.whiteElo, 1900);
    expect(g.playedAt, DateTime.utc(2025, 6, 1, 12));
    expect(g.pgn, _lichess);

    // Position after 1.e4 e5 2.Nf3 Nc6: both real games reached it.
    const afterNc6 =
        'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';
    final at = store.gamesAt(afterNc6);
    expect(at.map((x) => x.key).toSet(), {'lichess_abc12345', 'chesscom_999'});
    // Newest first: the chess.com game (June 2) leads.
    expect(at.first.key, 'chesscom_999');

    // The [FEN] game is indexed from its start position.
    const afterC5 =
        'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
    expect(store.gamesAt(afterC5).single.headers['Event'], 'Study');

    expect(store.byPlayer('me').length, 2);
    expect(store.byPlayer('me', collection: 'other'), isEmpty);
  });

  test(
    'summaries carry headers without movetext; header block round-trips',
    () {
      store.importPgn(_lichess, collection: GameCollections.tactics);
      final s = store.summaries(GameCollections.tactics).single;
      expect(s.key, 'lichess_abc12345');
      expect(s.headers['Site'], 'https://lichess.org/abc12345');
      expect(s.headerBlock, contains('[GameId "lichess_abc12345"]'));
      expect(s.headerBlock, isNot(contains('1. e4')));
    },
  );

  test('re-import updates by default, keepExisting appends only, replace '
      'clears', () {
    store.importPgn(_lichess, collection: 'c');
    final edited = _lichess.replaceFirst('1-0', '{note} 1-0');
    final r1 = store.importPgn(edited, collection: 'c');
    expect(r1.updated, 1);
    expect(store.byKey('c', 'lichess_abc12345')!.pgn, contains('{note}'));

    final r2 = store.importPgn(_lichess, collection: 'c', keepExisting: true);
    expect(r2.skipped, 1);
    expect(store.byKey('c', 'lichess_abc12345')!.pgn, contains('{note}'));

    store.importPgn(_chesscom, collection: 'c', replace: true);
    expect(store.count('c'), 1);
    expect(store.byKey('c', 'lichess_abc12345'), isNull);
    // Positions of the removed game are gone with it.
    expect(
      store.raw.select('SELECT COUNT(*) FROM positions').first.columnAt(0),
      lessThanOrEqualTo(kStoreIndexMaxPly),
    );
  });

  test('deleteKeys, exportPgn and collection counts', () {
    store.importPgn('$_lichess\n\n$_chesscom', collection: 'c');
    expect(store.deleteKeys('c', ['chesscom_999', 'missing']), 1);
    expect(store.exportPgn('c'), _lichess);
    expect(store.collectionCounts(), {'c': 1});
    expect(store.totalGames, 1);
    expect(store.collectionUpdatedAt('c'), isNotNull);
  });

  test('empty PGN with replace clears the collection', () {
    store.importPgn(_lichess, collection: 'c');
    store.importPgn('', collection: 'c', replace: true);
    expect(store.count('c'), 0);
  });

  group('GameStoreService', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('gamestore_svc');
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      GameStoreService.setTestInstance(GameStoreService());
    });
    tearDown(() async {
      GameStoreService.instance.close();
      await root.delete(recursive: true);
    });

    test('migrates imported_games.pgn once and keeps a backup', () async {
      final legacy = File(
        '${root.path}/${GameStoreService.legacyTacticsArchiveName}',
      );
      await legacy.writeAsString('$_lichess\n\n$_chesscom');

      final s = await GameStoreService.instance.open();
      expect(s.count(GameCollections.tactics), 2);
      expect(await legacy.exists(), isFalse);
      expect(await File('${legacy.path}.migrated').exists(), isTrue);

      // The storage contract still works, now over the store.
      final text = await StorageFactory.instance.readImportedPgns();
      expect(text, contains('[GameId "chesscom_999"]'));
      await StorageFactory.instance.saveImportedPgns('');
      expect(s.count(GameCollections.tactics), 0);
      expect(await StorageFactory.instance.readImportedPgns(), isNull);
    });

    test(
      'background import runs in an isolate with its own connection',
      () async {
        final r = await GameStoreService.instance.importPgnInBackground(
          collection: 'analysis:x',
          pgnText: _lichess,
        );
        expect(r.inserted, 1);
        final s = await GameStoreService.instance.open();
        expect(s.count('analysis:x'), 1);
      },
    );
  });
}
