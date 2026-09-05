@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/features/master_games/controllers/master_practice_controller.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'master_practice_fixtures.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late MasterGamesService service;
  late MasterPracticeController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('master_practice_ctl');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    final dbPath = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(
      MasterGamesImportRequest(
        dbPath: dbPath,
        pgnText: masterPgn,
        twicIssue: 1660,
      ),
    );
    service = MasterGamesService(dbPathProvider: () async => dbPath);
    await service.load();
    controller = MasterPracticeController(service: service);
  });

  tearDown(() async {
    controller.dispose();
    service.dispose();
    await tmp.delete(recursive: true);
  });

  test('runs the review and lands on my most repeated branch point', () async {
    await controller.run(myGames());
    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
    final review = controller.review!;
    expect(controller.selected, same(review.mine.first));
    expect(controller.selected!.games.length, 2);
  });

  test('with no deviations of mine it lands on the next section', () async {
    await controller.run([myGames()[1]]);
    expect(controller.selected, same(controller.review!.theirs.first));
  });

  test('a closed database is an error message, not a crash', () async {
    final closed = MasterPracticeController(
      service: MasterGamesService(dbPathProvider: () async => '/nonexistent'),
    );
    addTearDown(closed.dispose);
    await closed.run(myGames());
    expect(closed.error, contains('not open'));
    expect(closed.review, isNull);
  });

  test(
    'writing the key games gives the viewer one file and an index',
    () async {
      await controller.run(myGames());
      final entry = controller.selected!;
      final focus = entry.keyGames.last.game;
      final written = await controller.writeKeyGames(entry, focus: focus);
      expect(written.index, entry.keyGames.length - 1);
      expect(written.path, endsWith(MasterPracticeController.collectionName));
      final text = await File(written.path).readAsString();
      expect(
        RegExp(r'\[Event ').allMatches(text).length,
        entry.keyGames.length,
      );
      expect(text, contains(focus.white));
    },
  );
}
