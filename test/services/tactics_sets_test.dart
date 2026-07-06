import 'dart:io';

import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

TacticsPosition _pos(String fen) {
  return TacticsPosition(
    fen: fen,
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: fen,
    positionContext: 'Move 1, White to play',
    userMove: 'd4',
    correctLine: const ['e4'],
    mistakeType: '??',
    mistakeAnalysis: 'test',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tactics_sets_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File legacyCsvFile() => File(p.join(tempDir.path, 'tactics_positions.csv'));
  File setFile(String name) =>
      File(p.join(tempDir.path, 'tactics_sets', '$name.csv'));

  group('legacy migration', () {
    test('legacy CSV becomes the Default set and is renamed to .bak',
        () async {
      // Seed a legacy single-file database via a throwaway db instance.
      final seed = TacticsDatabase();
      await seed.addPosition(_pos('fen-legacy'));
      // Move the written Default.csv back to the legacy location to simulate
      // a pre-sets install.
      final defaultSet = setFile(TacticsDatabase.defaultSetName);
      expect(await defaultSet.exists(), isTrue);
      await defaultSet.rename(legacyCsvFile().path);
      await Directory(p.join(tempDir.path, 'tactics_sets'))
          .delete(recursive: true);

      final db = TacticsDatabase();
      final count = await db.loadPositions();

      expect(count, 1);
      expect(db.positions.single.fen, 'fen-legacy');
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(await defaultSet.exists(), isTrue);
      expect(await legacyCsvFile().exists(), isFalse);
      expect(
          await File('${legacyCsvFile().path}.bak').exists(), isTrue);
    });

    test('fresh install loads empty Default set without creating files',
        () async {
      final db = TacticsDatabase();
      final count = await db.loadPositions();

      expect(count, 0);
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(await setFile(TacticsDatabase.defaultSetName).exists(), isFalse);
    });

    test('migration does not run when a set file already exists', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('fen-a')); // creates Default.csv

      // Plant a legacy file afterwards; it must be left alone.
      await legacyCsvFile().writeAsString('fen\nshould-not-migrate');
      await db.loadPositions();

      expect(db.positions.single.fen, 'fen-a');
      expect(await legacyCsvFile().exists(), isTrue);
    });
  });

  group('set CRUD', () {
    test('createSet switches to a new empty set and lists both', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('fen-a'));

      await db.createSet('Classical');

      expect(db.activeSetName, 'Classical');
      expect(db.positions, isEmpty);
      expect(db.availableSets.map((s) => s.name),
          containsAll(['Default', 'Classical']));
    });

    test('createSet rejects duplicate names', () async {
      final db = TacticsDatabase();
      await db.createSet('Classical');
      await expectLater(db.createSet('Classical'), throwsArgumentError);
    });

    test('switchSet round-trips positions per set', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('fen-default'));
      await db.createSet('Classical');
      await db.addPosition(_pos('fen-classical'));

      await db.switchSet(TacticsDatabase.defaultSetName);
      expect(db.positions.single.fen, 'fen-default');

      await db.switchSet('Classical');
      expect(db.positions.single.fen, 'fen-classical');
    });

    test('renameSet renames the file and keeps the active set loaded',
        () async {
      final db = TacticsDatabase();
      await db.createSet('Old');
      await db.addPosition(_pos('fen-x'));

      await db.renameSet('Old', 'New');

      expect(db.activeSetName, 'New');
      expect(db.positions.single.fen, 'fen-x');
      expect(await setFile('New').exists(), isTrue);
      expect(await setFile('Old').exists(), isFalse);
    });

    test('deleteSetByName removes the file and falls back to another set',
        () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('fen-default'));
      await db.createSet('Doomed');
      await db.addPosition(_pos('fen-doomed'));

      await db.deleteSetByName('Doomed');

      expect(await setFile('Doomed').exists(), isFalse);
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(db.positions.single.fen, 'fen-default');
    });
  });

  group('active-set persistence', () {
    test('active set survives a new database instance', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('fen-default'));
      await db.createSet('Classical');
      await db.addPosition(_pos('fen-classical'));

      final db2 = TacticsDatabase();
      await db2.loadPositions();

      expect(db2.activeSetName, 'Classical');
      expect(db2.positions.single.fen, 'fen-classical');
    });

    test('vanished remembered set falls back to Default', () async {
      SharedPreferences.setMockInitialValues({'tactics_active_set': 'Ghost'});
      final db = TacticsDatabase();
      await db.loadPositions(); // restores "Ghost" from prefs
      await db.addPosition(_pos('fen-ghost')); // creates Ghost.csv
      await db.switchSet(TacticsDatabase.defaultSetName);
      await db.addPosition(_pos('fen-default')); // creates Default.csv
      SharedPreferences.setMockInitialValues({'tactics_active_set': 'Ghost'});

      // Delete Ghost's file externally, then reload with a fresh instance.
      await setFile('Ghost').delete();
      final db2 = TacticsDatabase();
      await db2.loadPositions();

      expect(db2.activeSetName, TacticsDatabase.defaultSetName);
      expect(db2.positions.single.fen, 'fen-default');
    });

    test('listTacticsSets reports position counts', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('fen-a'));
      await db.addPosition(_pos('fen-b'));

      final sets = await StorageFactory.instance.listTacticsSets();
      final defaultSet =
          sets.singleWhere((s) => s.name == TacticsDatabase.defaultSetName);
      expect(defaultSet.positionCount, 2);
    });
  });
}
