import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/models/analysis_player_info.dart';
import 'package:chess_auto_prep/services/analysis/player_corpus_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

String _game(String moves) =>
    '[Event "Test"]\n[Site "Local"]\n[Date "2026.09.04"]\n[Round "1"]\n'
    '[White "A"]\n[Black "B"]\n[Result "*"]\n\n$moves *';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform original;
  const alice = AnalysisPlayerInfo(platform: 'import', username: 'Alice');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('player-corpus-');
    await Directory(p.join(root.path, 'support')).create();
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    StorageFactory.instanceForTest = IOStorageService();
    GameStoreService.setTestInstance(
      GameStoreService(
        dbPathProvider: () async => p.join(root.path, 'support', 'games.db'),
      ),
    );
  });
  tearDown(() async {
    GameStoreService.instance.close();
    GameStoreService.setTestInstance(GameStoreService());
    StorageFactory.instanceForTest = null;
    PathProviderPlatform.instance = original;
    await root.delete(recursive: true);
  });

  test('save publishes a generation the manifest points at', () async {
    final store = PlayerCorpusStore();
    final saved = await store.save(alice, _game('1. e4 e5'));
    expect(saved.info.gameCount, 1);
    expect(saved.info.storageWarning, isNull);
    expect(await File(saved.pgnPath).readAsString(), _game('1. e4 e5'));

    final manifest = jsonDecode(
      await File(p.join(saved.directory.path, 'current.json')).readAsString(),
    );
    expect(manifest['revision'], saved.revision);
    expect(manifest['fingerprint'], saved.fingerprint);
    expect(manifest['deleted'], isFalse);

    final loaded = await store.load('import', 'alice');
    expect(loaded!.revision, saved.revision);
    expect(
      (await GameStoreService.instance.open()).count(
        GameCollections.analysis(loaded.info.playerKey),
      ),
      1,
    );
    expect((await store.list()).single.username, 'Alice');
  });

  test('an edited PGN re-fingerprints the manifest on load', () async {
    final store = PlayerCorpusStore();
    final saved = await store.save(alice, _game('1. e4 e5'));
    await File(saved.pgnPath).writeAsString(_game('1. d4 d5'));
    final loaded = await store.load('import', 'alice');
    expect(loaded!.revision, saved.revision);
    expect(loaded.fingerprint, isNot(saved.fingerprint));
    expect(
      (await store.load('import', 'alice', reconcile: false))!.fingerprint,
      loaded.fingerprint,
    );
  });

  test('legacy flat files migrate once and a tombstone stays', () async {
    final legacyDir = Directory(p.join(root.path, 'analysis_games'));
    await legacyDir.create();
    final base = p.join(legacyDir.path, alice.legacyPlayerKey);
    await File('$base.pgn').writeAsString(_game('1. e4 e5'));
    await File('$base.json').writeAsString(jsonEncode(alice.toJson()));
    // Unrelated and unreadable siblings are skipped, never deleted.
    await File(p.join(legacyDir.path, 'bob.json')).writeAsString(
      jsonEncode(
        const AnalysisPlayerInfo(platform: 'import', username: 'bob').toJson(),
      ),
    );
    await File(p.join(legacyDir.path, 'junk.json')).writeAsString('{');

    final store = PlayerCorpusStore();
    final migrated = await store.load('import', 'ALICE');
    expect(migrated, isNotNull);
    expect(migrated!.info.username, 'Alice');
    expect(await File('$base.pgn').exists(), isTrue);

    await store.tombstone('import', 'alice');
    expect(await store.load('import', 'alice'), isNull);
    expect(await File(migrated.pgnPath).exists(), isTrue);
    expect(
      (await store.list()).map((i) => i.username),
      isNot(contains('Alice')),
    );
  });
}
