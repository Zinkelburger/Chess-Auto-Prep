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

/// Distinct *valid* FENs (PGN storage needs parseable positions): the
/// standard start with a varying fullmove counter.
String _fen(int n) =>
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 $n';

TacticsPosition _pos(String fen) {
  return TacticsPosition(
    fen: fen,
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: 'game-$fen',
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
      File(p.join(tempDir.path, 'tactics_sets', '$name.pgn'));
  File setCsvFile(String name) =>
      File(p.join(tempDir.path, 'tactics_sets', '$name.csv'));

  group('legacy migration', () {
    test('legacy root CSV becomes the Default set as PGN', () async {
      await legacyCsvFile().create(recursive: true);
      await legacyCsvFile()
          .writeAsString(TacticsDatabase.encodeCsv([_pos(_fen(1))]));

      final db = TacticsDatabase();
      final count = await db.loadPositions();

      expect(count, 1);
      expect(db.positions.single.fen, _fen(1));
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(await setFile(TacticsDatabase.defaultSetName).exists(), isTrue);
      expect(await legacyCsvFile().exists(), isFalse);
      expect(await File('${legacyCsvFile().path}.bak').exists(), isTrue);
    });

    test('legacy per-set CSV files convert to PGN and are renamed .bak',
        () async {
      SharedPreferences.setMockInitialValues(
          {'tactics_active_set': 'Classical'});
      await setCsvFile('Classical').create(recursive: true);
      await setCsvFile('Classical').writeAsString(
          TacticsDatabase.encodeCsv([_pos(_fen(1)), _pos(_fen(2))]));

      final db = TacticsDatabase();
      final count = await db.loadPositions();

      expect(count, 2);
      expect(db.activeSetName, 'Classical');
      expect(db.positions.map((p0) => p0.fen), [_fen(1), _fen(2)]);
      expect(await setFile('Classical').exists(), isTrue);
      expect(await setCsvFile('Classical').exists(), isFalse);
      expect(
          await File('${setCsvFile('Classical').path}.bak').exists(), isTrue);
    });

    test('CSV conversion preserves review stats and mistake metadata',
        () async {
      SharedPreferences.setMockInitialValues({'tactics_active_set': 'Stats'});
      final seeded = _pos(_fen(3)).copyWith(
        reviewCount: 5,
        successCount: 4,
        rating: 2,
        opponentBestResponse: 'e5',
        lastReviewed: DateTime.utc(2026, 7, 1),
      );
      await setCsvFile('Stats').create(recursive: true);
      await setCsvFile('Stats')
          .writeAsString(TacticsDatabase.encodeCsv([seeded]));

      final db = TacticsDatabase();
      await db.loadPositions();

      final out = db.positions.single;
      expect(out.reviewCount, 5);
      expect(out.successCount, 4);
      expect(out.rating, 2);
      expect(out.opponentBestResponse, 'e5');
      expect(out.lastReviewed, DateTime.utc(2026, 7, 1));
      expect(out.userMove, 'd4');
      expect(out.mistakeType, '??');
      expect(out.mistakeAnalysis, 'test');
    });

    test('fresh install loads empty Default set without creating files',
        () async {
      final db = TacticsDatabase();
      final count = await db.loadPositions();

      expect(count, 0);
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(await setFile(TacticsDatabase.defaultSetName).exists(), isFalse);
    });

    test('root-CSV migration does not run when a set file already exists',
        () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1))); // creates Default.pgn

      // Plant a legacy file afterwards; it must be left alone.
      await legacyCsvFile().writeAsString('fen\nshould-not-migrate');
      await db.loadPositions();

      expect(db.positions.single.fen, _fen(1));
      expect(await legacyCsvFile().exists(), isTrue);
    });
  });

  group('set CRUD', () {
    test('createSet switches to a new empty set and lists both', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));

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
      await db.addPosition(_pos(_fen(1)));
      await db.createSet('Classical');
      await db.addPosition(_pos(_fen(2)));

      await db.switchSet(TacticsDatabase.defaultSetName);
      expect(db.positions.single.fen, _fen(1));

      await db.switchSet('Classical');
      expect(db.positions.single.fen, _fen(2));
    });

    test('renameSet renames the file and keeps the active set loaded',
        () async {
      final db = TacticsDatabase();
      await db.createSet('Old');
      await db.addPosition(_pos(_fen(1)));

      await db.renameSet('Old', 'New');

      expect(db.activeSetName, 'New');
      expect(db.positions.single.fen, _fen(1));
      expect(await setFile('New').exists(), isTrue);
      expect(await setFile('Old').exists(), isFalse);
    });

    test('deleteSetByName removes the file and falls back to another set',
        () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));
      await db.createSet('Doomed');
      await db.addPosition(_pos(_fen(2)));

      await db.deleteSetByName('Doomed');

      expect(await setFile('Doomed').exists(), isFalse);
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(db.positions.single.fen, _fen(1));
    });

    test('review stats round-trip through the PGN set file', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));
      await db.recordAttempt(db.positions.single, TacticsResult.correct, 7.5);
      await db.setRating(_fen(1), 4);

      final db2 = TacticsDatabase();
      await db2.loadPositions();

      final out = db2.positions.single;
      expect(out.reviewCount, 1);
      expect(out.successCount, 1);
      expect(out.rating, 4);
      expect(out.lastReviewed, isNotNull);
    });
  });

  group('external sets (review a study as flashcards)', () {
    const studyPgn = '''
[Event "Chapter 1"]
[FEN "6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1"]
[SetUp "1"]

1... Ra1+ {Back rank!} (1... h5 2. Kg2 h4) 2. Kh2 Ra2 *

[Event "Chapter 2"]

1. e4 {Standard-start chapters count too} e5 *
''';

    test('opens chapters as puzzles, including standard-start ones',
        () async {
      final studyFile = File(p.join(tempDir.path, 'studies', 'My study.pgn'));
      await studyFile.create(recursive: true);
      await studyFile.writeAsString(studyPgn);

      final db = TacticsDatabase();
      final count = await db.openExternalSet(studyFile.path);

      expect(count, 2);
      expect(db.isExternalSet, isTrue);
      expect(db.activeSetName, 'My study');
      expect(db.positions[0].correctLine, ['Ra1+', 'Kh2', 'Ra2']);
      expect(db.positions[0].mistakeAnalysis, 'Back rank!');
      expect(db.positions[1].correctLine, ['e4', 'e5']);
    });

    test('recordAttempt patches stats into the study without flattening it',
        () async {
      final studyFile = File(p.join(tempDir.path, 'studies', 'My study.pgn'));
      await studyFile.create(recursive: true);
      await studyFile.writeAsString(studyPgn);

      final db = TacticsDatabase();
      await db.openExternalSet(studyFile.path);
      await db.recordAttempt(db.positions[0], TacticsResult.correct, 3.0);

      final saved = await studyFile.readAsString();
      expect(saved, contains('[ReviewCount "1"]'));
      expect(saved, contains('[SuccessCount "1"]'));
      // The variation and comment survive the write.
      expect(saved, contains('(1... h5 2. Kg2 h4)'));
      expect(saved, contains('{Back rank!}'));

      // Reopening sees the stats.
      final db2 = TacticsDatabase();
      await db2.openExternalSet(studyFile.path);
      expect(db2.positions[0].reviewCount, 1);
    });

    test('switching back to a named set clears the external state', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));

      final studyFile = File(p.join(tempDir.path, 'studies', 'S.pgn'));
      await studyFile.create(recursive: true);
      await studyFile.writeAsString(studyPgn);
      await db.openExternalSet(studyFile.path);
      expect(db.isExternalSet, isTrue);

      await db.switchSet(TacticsDatabase.defaultSetName);
      expect(db.isExternalSet, isFalse);
      expect(db.positions.single.fen, _fen(1));
    });
  });

  group('active-set persistence', () {
    test('active set survives a new database instance', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));
      await db.createSet('Classical');
      await db.addPosition(_pos(_fen(2)));

      final db2 = TacticsDatabase();
      await db2.loadPositions();

      expect(db2.activeSetName, 'Classical');
      expect(db2.positions.single.fen, _fen(2));
    });

    test('an external set is not remembered as the active set', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1))); // Default becomes remembered

      final studyFile = File(p.join(tempDir.path, 'studies', 'S.pgn'));
      await studyFile.create(recursive: true);
      await studyFile.writeAsString('[Event "C"]\n\n1. e4 *\n');
      await db.openExternalSet(studyFile.path);

      final db2 = TacticsDatabase();
      await db2.loadPositions();
      expect(db2.activeSetName, TacticsDatabase.defaultSetName);
      expect(db2.isExternalSet, isFalse);
    });

    test('vanished remembered set falls back to Default', () async {
      SharedPreferences.setMockInitialValues({'tactics_active_set': 'Ghost'});
      final db = TacticsDatabase();
      await db.loadPositions(); // restores "Ghost" from prefs
      await db.addPosition(_pos(_fen(1))); // creates Ghost.pgn
      await db.switchSet(TacticsDatabase.defaultSetName);
      await db.addPosition(_pos(_fen(2))); // creates Default.pgn
      SharedPreferences.setMockInitialValues({'tactics_active_set': 'Ghost'});

      // Delete Ghost's file externally, then reload with a fresh instance.
      await setFile('Ghost').delete();
      final db2 = TacticsDatabase();
      await db2.loadPositions();

      expect(db2.activeSetName, TacticsDatabase.defaultSetName);
      expect(db2.positions.single.fen, _fen(2));
    });

    test('listTacticsSets reports position counts', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));
      await db.addPosition(_pos(_fen(2)));

      final sets = await StorageFactory.instance.listTacticsSets();
      final defaultSet =
          sets.singleWhere((s) => s.name == TacticsDatabase.defaultSetName);
      expect(defaultSet.positionCount, 2);
    });
  });
}
