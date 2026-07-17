import 'dart:io';

import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/models/tactics_session_settings.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:csv/csv.dart';
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

/// Legacy tactics-CSV content (header + rows) for seeding migration inputs;
/// mirrors the format the app used to write before PGN storage.
String _csv(List<TacticsPosition> rows) {
  return Csv().encode([
    [
      'fen',
      'game_white',
      'game_black',
      'game_result',
      'game_date',
      'game_id',
      'game_url',
      'position_context',
      'user_move',
      'correct_line',
      'mistake_type',
      'mistake_analysis',
      'review_count',
      'success_count',
      'last_reviewed',
      'time_to_solve',
      'hints_used',
      'opponent_best_response',
      'rating',
    ],
    for (final pos in rows) pos.toCsvRow(),
  ]);
}

/// Session settings that don't depend on today's date (the fixtures use a
/// fixed old game date).
const _allTime = TacticsSessionSettings(maxAgeDays: null);

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
  File studyFile(String name) =>
      File(p.join(tempDir.path, 'studies', '$name.pgn'));

  group('legacy migration', () {
    test('legacy root CSV becomes the Default set as PGN', () async {
      await legacyCsvFile().create(recursive: true);
      await legacyCsvFile().writeAsString(_csv([_pos(_fen(1))]));

      final db = TacticsDatabase();
      final count = await db.loadPositions();

      expect(count, 1);
      expect(db.positions.single.fen, _fen(1));
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(await setFile(TacticsDatabase.defaultSetName).exists(), isTrue);
      expect(await legacyCsvFile().exists(), isFalse);
      expect(await File('${legacyCsvFile().path}.bak').exists(), isTrue);
    });

    test(
      'CSV conversion preserves review stats and mistake metadata',
      () async {
        final seeded = _pos(_fen(3)).copyWith(
          reviewCount: 5,
          successCount: 4,
          rating: 2,
          opponentBestResponse: 'e5',
          lastReviewed: DateTime.utc(2026, 7, 1),
        );
        await legacyCsvFile().create(recursive: true);
        await legacyCsvFile().writeAsString(_csv([seeded]));

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
      },
    );

    test('legacy per-set CSV converts to PGN and lands in the studies '
        'directory (multi-set era cleanup)', () async {
      await setCsvFile('Classical').create(recursive: true);
      await setCsvFile(
        'Classical',
      ).writeAsString(_csv([_pos(_fen(1)), _pos(_fen(2))]));

      final db = TacticsDatabase();
      final count = await db.loadPositions();

      expect(count, 0, reason: 'the tactics database itself stays empty');
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(await setCsvFile('Classical').exists(), isFalse);
      expect(
        await File('${setCsvFile('Classical').path}.bak').exists(),
        isTrue,
      );
      expect(
        await setFile('Classical').exists(),
        isFalse,
        reason: 'moved out of tactics_sets',
      );
      expect(await studyFile('Classical').exists(), isTrue);
    });

    test(
      'fresh install loads empty Default set without creating files',
      () async {
        final db = TacticsDatabase();
        final count = await db.loadPositions();

        expect(count, 0);
        expect(db.activeSetName, TacticsDatabase.defaultSetName);
        expect(await setFile(TacticsDatabase.defaultSetName).exists(), isFalse);
      },
    );

    test(
      'root-CSV migration does not run when a set file already exists',
      () async {
        final db = TacticsDatabase();
        await db.addPosition(_pos(_fen(1))); // creates Default.pgn

        // Plant a legacy file afterwards; it must be left alone.
        await legacyCsvFile().writeAsString('fen\nshould-not-migrate');
        await db.loadPositions();

        expect(db.positions.single.fen, _fen(1));
        expect(await legacyCsvFile().exists(), isTrue);
      },
    );
  });

  group('multi-set era cleanup', () {
    test('non-Default set files are moved into studies on load', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1))); // creates Default.pgn
      final defaultContent = await setFile(
        TacticsDatabase.defaultSetName,
      ).readAsString();
      await setFile('Extra').writeAsString(defaultContent);

      final db2 = TacticsDatabase();
      await db2.loadPositions();

      expect(await setFile('Extra').exists(), isFalse);
      expect(await studyFile('Extra').exists(), isTrue);
      expect(
        await studyFile('Extra').readAsString(),
        defaultContent,
        reason: 'moved verbatim — nothing is lost',
      );
      expect(
        await setFile(TacticsDatabase.defaultSetName).exists(),
        isTrue,
        reason: 'the database file itself stays put',
      );
    });

    test('a name collision in studies gets a suffix', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));
      final content = await setFile(
        TacticsDatabase.defaultSetName,
      ).readAsString();
      await setFile('Extra').writeAsString(content);
      await studyFile('Extra').create(recursive: true);
      await studyFile('Extra').writeAsString('existing study');

      final db2 = TacticsDatabase();
      await db2.loadPositions();

      expect(
        await studyFile('Extra').readAsString(),
        'existing study',
        reason: 'never overwrites an existing study',
      );
      expect(await studyFile('Extra (tactics)').exists(), isTrue);
    });

    test('a stale remembered-set preference is ignored', () async {
      SharedPreferences.setMockInitialValues({'tactics_active_set': 'Ghost'});
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));

      final db2 = TacticsDatabase();
      await db2.loadPositions();

      expect(db2.activeSetName, TacticsDatabase.defaultSetName);
      expect(db2.positions.single.fen, _fen(1));
    });
  });

  group('session queue', () {
    test(
      'the queue does not wrap: next past the end reports exhaustion',
      () async {
        final db = TacticsDatabase();
        await db.addPosition(_pos(_fen(1)));
        await db.addPosition(_pos(_fen(2)));

        db.startSession(_allTime);
        expect(db.sessionQueueLength, 2);
        final first = db.sessionPositionIndex;

        expect(db.nextSessionPosition(), isNotNull);
        final last = db.sessionPositionIndex;
        expect(
          db.nextSessionPosition(),
          isNull,
          reason: 'past the last puzzle — session over',
        );
        expect(db.sessionPositionIndex, last, reason: 'stays on the last');

        expect(db.previousSessionPosition(), first);
        expect(
          db.previousSessionPosition(),
          first,
          reason: 'previous stops at the first puzzle',
        );
      },
    );

    test(
      'startSessionWithPositions queues exactly the subset, in order',
      () async {
        final db = TacticsDatabase();
        await db.addPosition(_pos(_fen(1)));
        await db.addPosition(_pos(_fen(2)));
        await db.addPosition(_pos(_fen(3)));

        db.startSessionWithPositions([
          db.positions[2],
          db.positions[0],
          _pos(_fen(99)),
        ]);

        expect(db.sessionQueueLength, 2, reason: 'unknown FEN skipped');
        expect(db.sessionPositionIndex, 2);
        expect(db.nextSessionPosition(), 0);
        expect(db.nextSessionPosition(), isNull);
      },
    );
  });

  group('tactics database persistence', () {
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

    test('listTacticsSets reports position counts', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));
      await db.addPosition(_pos(_fen(2)));

      final sets = await StorageFactory.instance.listTacticsSets();
      final defaultSet = sets.singleWhere(
        (s) => s.name == TacticsDatabase.defaultSetName,
      );
      expect(defaultSet.positionCount, 2);
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

    test('opens chapters as puzzles, including standard-start ones', () async {
      final study = studyFile('My study');
      await study.create(recursive: true);
      await study.writeAsString(studyPgn);

      final db = TacticsDatabase();
      final count = await db.openExternalSet(study.path);

      expect(count, 2);
      expect(db.isExternalSet, isTrue);
      expect(db.activeSetName, 'My study');
      expect(db.positions[0].correctLine, ['Ra1+', 'Kh2', 'Ra2']);
      expect(db.positions[0].mistakeAnalysis, 'Back rank!');
      expect(db.positions[1].correctLine, ['e4', 'e5']);
    });

    test(
      'recordAttempt patches stats into the study without flattening it',
      () async {
        final study = studyFile('My study');
        await study.create(recursive: true);
        await study.writeAsString(studyPgn);

        final db = TacticsDatabase();
        await db.openExternalSet(study.path);
        await db.recordAttempt(db.positions[0], TacticsResult.correct, 3.0);

        final saved = await study.readAsString();
        expect(saved, contains('[ReviewCount "1"]'));
        expect(saved, contains('[SuccessCount "1"]'));
        // The variation and comment survive the write.
        expect(saved, contains('(1... h5 2. Kg2 h4)'));
        expect(saved, contains('{Back rank!}'));

        // Reopening sees the stats.
        final db2 = TacticsDatabase();
        await db2.openExternalSet(study.path);
        expect(db2.positions[0].reviewCount, 1);
      },
    );

    test('closeExternalSet returns to the tactics database', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos(_fen(1)));

      final study = studyFile('S');
      await study.create(recursive: true);
      await study.writeAsString(studyPgn);
      await db.openExternalSet(study.path);
      expect(db.isExternalSet, isTrue);

      await db.closeExternalSet();
      expect(db.isExternalSet, isFalse);
      expect(db.activeSetName, TacticsDatabase.defaultSetName);
      expect(db.positions.single.fen, _fen(1));
    });

    test(
      'an external set is never the loaded set on a fresh instance',
      () async {
        final db = TacticsDatabase();
        await db.addPosition(_pos(_fen(1)));

        final study = studyFile('S');
        await study.create(recursive: true);
        await study.writeAsString('[Event "C"]\n\n1. e4 *\n');
        await db.openExternalSet(study.path);

        final db2 = TacticsDatabase();
        await db2.loadPositions();
        expect(db2.activeSetName, TacticsDatabase.defaultSetName);
        expect(db2.isExternalSet, isFalse);
      },
    );
  });
}
