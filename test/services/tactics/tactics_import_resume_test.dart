import 'dart:io';

import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:chess_auto_prep/services/tactics_import_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Routes path_provider's documents directory to a per-test temp dir so the
/// real IOStorageService reads/writes real files without touching the user's
/// data.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// A lichess-export-shaped game: lichess natively includes a *bare*
/// [GameId] header (no `lichess_` prefix) alongside the Site URL.
String _lichessGame(String id, {String? date}) => '''
[Event "Rated blitz game"]
[Site "https://lichess.org/$id"]
${date != null ? '[UTCDate "$date"]\n' : ''}[White "userA"]
[Black "userB"]
[Result "1-0"]
[GameId "$id"]

1. e4 e5 1-0''';

/// A game as stored by our own importer, with a prefixed GameId injected.
String _prefixedGame(String prefixedId) => '''
[Event "Live Chess"]
[White "userA"]
[Black "userB"]
[Result "0-1"]
[GameId "$prefixedId"]

1. d4 d5 0-1''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tactics_resume_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<TacticsImportService> serviceWithAnalyzed(List<String> ids) async {
    await StorageFactory.instance.saveAnalyzedGameIds(ids);
    final db = TacticsDatabase();
    await db.loadPositions();
    return TacticsImportService(database: db);
  }

  group('countPendingGames', () {
    test('native lichess GameId headers count as lichess games', () async {
      await StorageFactory.instance.saveImportedPgns([
        _lichessGame('abc12345'),
        _prefixedGame('chesscom_111'),
        _prefixedGame('lichess_def67890'),
      ].join('\n\n'));
      final service = await serviceWithAnalyzed([]);

      final both = await service.countPendingGames(
          lichessUsername: 'userA', chesscomUsername: 'userA');
      expect(both.total, 3);
      expect(both.pending, 3);

      // Without a lichess username the bare-header game must not be
      // counted either — resume could not process it.
      final chessComOnly =
          await service.countPendingGames(chesscomUsername: 'userA');
      expect(chessComOnly.pending, 1);

      final none = await service.countPendingGames();
      expect(none.pending, 0);
    });

    test('games before the window are expired, not pending', () async {
      String fmt(DateTime d) => '${d.year}.'
          '${d.month.toString().padLeft(2, '0')}.'
          '${d.day.toString().padLeft(2, '0')}';
      final now = DateTime.now();
      await StorageFactory.instance.saveImportedPgns([
        _lichessGame('old00000', date: fmt(now.subtract(const Duration(days: 90)))),
        _lichessGame('new00000', date: fmt(now.subtract(const Duration(days: 2)))),
        _lichessGame('nodate00'), // no date header: kept (lenient)
      ].join('\n\n'));
      final service = await serviceWithAnalyzed([]);

      final counts = await service.countPendingGames(
        lichessUsername: 'userA',
        since: now.subtract(const Duration(days: 14)),
      );
      expect(counts.total, 3);
      expect(counts.pending, 2);

      final noWindow =
          await service.countPendingGames(lichessUsername: 'userA');
      expect(noWindow.pending, 3);
    });

    test('legacy bare analyzed IDs still mark lichess games analyzed',
        () async {
      await StorageFactory.instance.saveImportedPgns([
        _lichessGame('abc12345'),
        _lichessGame('zzz98765'),
      ].join('\n\n'));
      // Old builds recorded the bare ID; the game must not re-pend now
      // that extraction returns lichess_-prefixed IDs.
      final service = await serviceWithAnalyzed(['abc12345']);

      final counts = await service.countPendingGames(
          lichessUsername: 'userA', chesscomUsername: 'userA');
      expect(counts.total, 2);
      expect(counts.pending, 1);
    });
  });

  group('pruneStoredPgns', () {
    String fmt(DateTime d) => '${d.year}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${d.day.toString().padLeft(2, '0')}';

    test('drops analyzed and expired games, keeps the live queue', () async {
      final now = DateTime.now();
      await StorageFactory.instance.saveImportedPgns([
        _lichessGame('done1111', date: fmt(now)), // analyzed (legacy bare id)
        _lichessGame('old00000',
            date: fmt(now.subtract(const Duration(days: 90)))), // expired
        _lichessGame('new00000',
            date: fmt(now.subtract(const Duration(days: 2)))), // pending
        _prefixedGame('chesscom_111'), // pending, no date: kept
      ].join('\n\n'));
      final service = await serviceWithAnalyzed(['done1111']);

      final removed = await service.pruneStoredPgns(
          since: now.subtract(const Duration(days: 14)));
      expect(removed, 2);

      final content = await StorageFactory.instance.readImportedPgns();
      expect(content, isNot(contains('done1111')));
      expect(content, isNot(contains('old00000')));
      expect(content, contains('new00000'));
      expect(content, contains('chesscom_111'));

      // The pending queue is unchanged by pruning.
      final counts = await service.countPendingGames(
        lichessUsername: 'userA',
        chesscomUsername: 'userA',
        since: now.subtract(const Duration(days: 14)),
      );
      expect(counts.pending, 2);
    });

    test('no rewrite when nothing to prune', () async {
      final pgn = _lichessGame('new00000', date: fmt(DateTime.now()));
      await StorageFactory.instance.saveImportedPgns(pgn);
      final service = await serviceWithAnalyzed([]);

      final removed = await service.pruneStoredPgns(
          since: DateTime.now().subtract(const Duration(days: 14)));
      expect(removed, 0);
      expect(await StorageFactory.instance.readImportedPgns(), pgn);
    });
  });
}
