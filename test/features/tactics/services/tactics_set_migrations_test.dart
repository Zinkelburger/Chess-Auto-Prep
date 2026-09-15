import 'dart:io';

import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_pgn_codec.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_set_migrations.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:csv/csv.dart';
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

const _fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

const _puzzle = TacticsPosition(
  fen: _fen,
  userMove: 'd4',
  correctLine: ['e4'],
  mistakeType: '??',
  mistakeAnalysis: 'test',
  gameWhite: 'A',
  gameBlack: 'B',
  gameResult: '1-0',
  gameDate: '2024.01.01',
  gameId: 'lichess_x',
);

String _csv(List<List<dynamic>> rows) =>
    Csv().encode([List.filled(22, 'h'), ...rows]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late TacticsSetMigrations migrations;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tactics_migrations');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    migrations = TacticsSetMigrations(
      StorageFactory.instance,
      defaultSetName: 'Default',
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File setCsv(String name) =>
      File(p.join(tempDir.path, 'tactics_sets', '$name.csv'));
  File setPgn(String name) =>
      File(p.join(tempDir.path, 'tactics_sets', '$name.pgn'));
  File study(String name) => File(p.join(tempDir.path, 'studies', '$name.pgn'));

  group('parseTacticsCsv', () {
    test('reads rows after the header and reports bad rows', () {
      final parsed = parseTacticsCsv(
        _csv([
          _puzzle.toCsvRow(),
          ['too', 'short'],
        ]),
      );
      expect(parsed.positions.map((p) => p.fen), [_fen]);
      expect(parsed.warnings, hasLength(1));
      expect(parsed.warnings.single, startsWith('Row 2:'));
    });

    test('an empty file is no positions and no warnings', () {
      final parsed = parseTacticsCsv('  \n');
      expect(parsed.positions, isEmpty);
      expect(parsed.warnings, isEmpty);
    });
  });

  group('convertCsvSetsToPgn', () {
    test('writes the PGN and keeps the CSV as a .bak', () async {
      await setCsv('Old').create(recursive: true);
      await setCsv('Old').writeAsString(_csv([_puzzle.toCsvRow()]));

      await migrations.convertCsvSetsToPgn();

      expect(await setCsv('Old').exists(), isFalse);
      expect(await File('${setCsv('Old').path}.bak').exists(), isTrue);
      final decoded = decodePuzzlesFromPgn(await setPgn('Old').readAsString());
      expect(decoded.puzzles.single.fen, _fen);
      expect(decoded.puzzles.single.correctLine, ['e4']);
    });

    test('leaves a CSV alone when its PGN already exists', () async {
      await setCsv('Old').create(recursive: true);
      await setCsv('Old').writeAsString(_csv([_puzzle.toCsvRow()]));
      await setPgn('Old').writeAsString('existing');

      await migrations.convertCsvSetsToPgn();

      expect(await setCsv('Old').exists(), isTrue);
      expect(await setPgn('Old').readAsString(), 'existing');
    });

    test('refuses a CSV with unreadable rows', () async {
      await setCsv('Bad').create(recursive: true);
      await setCsv('Bad').writeAsString(
        _csv([
          ['not', 'enough', 'columns'],
        ]),
      );

      await expectLater(migrations.convertCsvSetsToPgn(), throwsStateError);
      expect(await setCsv('Bad').exists(), isTrue, reason: 'nothing touched');
      expect(await setPgn('Bad').exists(), isFalse);
    });
  });

  group('moveNamedSetsToStudies', () {
    test('moves every set but the default, suffixing collisions', () async {
      await setPgn('Default').create(recursive: true);
      await setPgn('Default').writeAsString('default');
      await setPgn('Endgames').writeAsString('endgames');
      await setPgn('Taken').writeAsString('taken');
      await study('Taken').create(recursive: true);
      await study('Taken').writeAsString('study');

      await migrations.moveNamedSetsToStudies();

      expect(await setPgn('Default').readAsString(), 'default');
      expect(await setPgn('Endgames').exists(), isFalse);
      expect(await study('Endgames').readAsString(), 'endgames');
      expect(await study('Taken').readAsString(), 'study');
      expect(await study('Taken (tactics)').readAsString(), 'taken');
    });
  });
}
