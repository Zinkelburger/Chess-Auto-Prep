/// What the games library does when the download does not happen.
///
/// The rule: a failed fetch never costs the user the games already on this
/// computer. Offline, a stale cache is the whole answer — and `forceRefresh`
/// ("check for new games") must not turn a failed check into an empty list.
@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

String _game(String link, String date) =>
    '[Event "Live Chess"]\n'
    '[Date "$date"]\n'
    '[White "me"]\n'
    '[Black "them"]\n'
    '[Link "$link"]\n'
    '[TimeControl "600"]\n'
    '[Result "1-0"]\n'
    '\n'
    '1. e4 e5 1-0';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('games_library_offline');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Write a cache file the way a previous successful download would have.
  Future<void> seedCache(String pgn) async {
    final dir = Directory(
      p.join(root.path, AppPaths.gamesLibraryDirectoryName),
    );
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'lichess_me.pgn')).writeAsString(pgn);
  }

  /// A library that always goes to the network (an expired cache) and never
  /// reaches it — the state a machine is in twelve hours after its last
  /// download, with the wifi off.
  GamesLibraryService offlineLibrary({Object? error}) => GamesLibraryService(
    cacheTtl: Duration.zero,
    lichessFetcher:
        (
          username, {
          int maxGames = 300,
          DateTime? since,
          void Function(String message)? onProgress,
        }) async => throw error ?? const SocketException('Failed host lookup'),
  );

  test('an expired cache plus a failed fetch still lists the games', () async {
    await seedCache('${_game('https://x/1', '2026.09.01')}\n\n'
        '${_game('https://x/2', '2026.09.02')}');

    Object? reported;
    var sawStale = false;
    final games = await offlineLibrary().getGames(
      platform: GamesPlatform.lichess,
      username: 'me',
      onStaleCache: (e) {
        sawStale = true;
        reported = e;
      },
    );

    expect(games, hasLength(2));
    expect(sawStale, isTrue, reason: 'the caller must be able to say so');
    expect(reported, isA<SocketException>());
  });

  test('forceRefresh still falls back: a failed check keeps the games', () async {
    await seedCache(_game('https://x/1', '2026.09.01'));

    final games = await offlineLibrary().getGames(
      platform: GamesPlatform.lichess,
      username: 'me',
      forceRefresh: true,
    );

    expect(games, hasLength(1));
  });

  test('the failed download leaves the cache file untouched', () async {
    final cached = _game('https://x/1', '2026.09.01');
    await seedCache(cached);

    await offlineLibrary().getGames(
      platform: GamesPlatform.lichess,
      username: 'me',
      forceRefresh: true,
    );

    final file = File(
      p.join(root.path, AppPaths.gamesLibraryDirectoryName, 'lichess_me.pgn'),
    );
    expect(await file.readAsString(), cached);
  });

  test('with no cache at all the failure reaches the caller', () async {
    await expectLater(
      offlineLibrary().getGames(
        platform: GamesPlatform.lichess,
        username: 'me',
      ),
      throwsA(isA<SocketException>()),
    );
  });

  test('a successful fetch clears no notice and reports no staleness', () async {
    await seedCache(_game('https://x/1', '2026.09.01'));
    final library = GamesLibraryService(
      lichessFetcher:
          (
            username, {
            int maxGames = 300,
            DateTime? since,
            void Function(String message)? onProgress,
          }) async => _game('https://x/2', '2026.09.02'),
    );

    var sawStale = false;
    final games = await library.getGames(
      platform: GamesPlatform.lichess,
      username: 'me',
      forceRefresh: true,
      onStaleCache: (_) => sawStale = true,
    );

    expect(sawStale, isFalse);
    expect(games, hasLength(2), reason: 'fresh game merged into the cache');
  });

  test('cachedPgn reads what is saved and nothing when there is none', () async {
    final library = GamesLibraryService();
    expect(
      await library.cachedPgn(GamesPlatform.lichess, 'me'),
      isNull,
    );
    await seedCache(_game('https://x/1', '2026.09.01'));
    expect(
      await library.cachedPgn(GamesPlatform.lichess, 'me'),
      contains('https://x/1'),
    );
  });

  test('parseGameRecords sees the cached games as records', () async {
    await seedCache(_game('https://x/1', '2026.09.01'));
    final pgn = await GamesLibraryService().cachedPgn(
      GamesPlatform.lichess,
      'me',
    );
    expect(parseGameRecords(pgn!), hasLength(1));
  });
}
