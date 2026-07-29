import 'dart:io';

import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The per-game deviation walker: SAN-prefix matching of a game against the
/// designated repertoire chapters, deepest-matching chapter wins, side-aware
/// "who left book".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MyRepertoireSettings settings;
  late GameDeviationService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('deviation_test_');
    settings = MyRepertoireSettings.forTest();
    service = GameDeviationService(settings: settings);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<String> writeChapter(String name, String content) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString(content);
    return file.path;
  }

  const mainChapter = '''
// Color: White

[Event "QGD"]
[Result "*"]

1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Bg5 *

[Event "Slav"]
[Result "*"]

1. d4 d5 2. c4 c6 3. Nf3 Nf6 *
''';

  test('reports my deviation with move number and expected moves', () async {
    await writeChapter('Main.pgn', mainChapter);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    // I (White) play 3. Nf3 where the book has only 3. Nc3.
    final report = await service.analyzeGame(
      gameSans: ['d4', 'd5', 'c4', 'e6', 'Nf3', 'Nf6'],
      meWhite: true,
    );

    expect(report, isNotNull);
    expect(report!.inBook, isFalse);
    expect(report.matchedPlies, 4);
    expect(report.moveNumber, 3);
    expect(report.byMe, isTrue);
    expect(report.playedSan, 'Nf3');
    expect(report.expectedSans, ['Nc3']);
    expect(report.pathSans, ['d4', 'd5', 'c4', 'e6']);
    expect(report.chapterName, 'Main');
  });

  test('reports the opponent leaving book', () async {
    await writeChapter('Main.pgn', mainChapter);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    // Black answers 1. d4 with 1... Nf6, which this book has no line for.
    final report = await service.analyzeGame(
      gameSans: ['d4', 'Nf6', 'c4', 'g6'],
      meWhite: true,
    );

    expect(report!.byMe, isFalse);
    expect(report.matchedPlies, 1);
    expect(report.playedSan, 'Nf6');
    expect(report.expectedSans, ['d5']);
  });

  test('running past the end of the prepared line reports bookEnded', () async {
    await writeChapter('Main.pgn', mainChapter);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    // The QGD line ends after 4. Bg5; the game keeps going.
    final report = await service.analyzeGame(
      gameSans: ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Bg5', 'Be7'],
      meWhite: true,
    );

    expect(report!.inBook, isFalse);
    expect(report.bookEnded, isTrue);
    expect(report.matchedPlies, 7);
    expect(report.playedSan, 'Be7');
    expect(report.expectedSans, isEmpty);
  });

  test('a game that stays in book reports inBook', () async {
    await writeChapter('Main.pgn', mainChapter);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    final report = await service.analyzeGame(
      gameSans: ['d4', 'd5', 'c4', 'c6'],
      meWhite: true,
    );

    expect(report!.inBook, isTrue);
    expect(report.byMe, isNull);
    expect(report.matchedPlies, 4);
  });

  test('matching tolerates check suffixes in either source', () async {
    await writeChapter('Checks.pgn', '''
// Color: White

[Event "L"]
[Result "*"]

1. e4 f6 2. Qh5+ g6 *
''');
    await settings.setPaths(white: true, paths: [tempDir.path]);

    final report = await service.analyzeGame(
      // The game's PGN writes the check without the plus.
      gameSans: ['e4', 'f6', 'Qh5', 'g6', 'Qe5'],
      meWhite: true,
    );
    expect(report!.matchedPlies, 4);
    expect(report.playedSan, 'Qe5');
  });

  test('the deepest-matching chapter across folders wins', () async {
    await writeChapter('Shallow.pgn', '''
// Color: Black

[Event "S"]
[Result "*"]

1. e4 e5 *
''');
    await writeChapter('Deep.pgn', '''
// Color: Black

[Event "D"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *
''');
    await settings.setPaths(white: false, paths: [tempDir.path]);

    final report = await service.analyzeGame(
      gameSans: ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4', 'Bc5'],
      meWhite: false,
    );

    expect(report!.chapterName, 'Deep');
    expect(report.matchedPlies, 4);
    expect(report.byMe, isFalse, reason: 'ply 4 is a White move; I am Black');
  });

  test('no designation for the color returns null', () async {
    await writeChapter('Main.pgn', mainChapter);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    expect(
      await service.analyzeGame(gameSans: ['e4', 'e5'], meWhite: false),
      isNull,
    );
  });

  test('a deleted folder or file is skipped, not a crash', () async {
    await settings.setPaths(white: true, paths: ['${tempDir.path}/gone']);
    expect(await service.analyzeGame(gameSans: ['e4'], meWhite: true), isNull);
  });

  test('edited chapters are re-read (mtime cache invalidation)', () async {
    final path = await writeChapter('Main.pgn', mainChapter);
    await settings.setPaths(white: true, paths: [tempDir.path]);

    final before = await service.analyzeGame(
      gameSans: ['d4', 'g6'],
      meWhite: true,
    );
    expect(before!.matchedPlies, 1);

    // Add a 1... g6 line; backdate-proof by bumping mtime explicitly.
    final file = File(path);
    await file.writeAsString(
      '$mainChapter\n[Event "KID"]\n[Result "*"]\n\n1. d4 g6 2. c4 Bg7 *\n',
    );
    await file.setLastModified(DateTime.now().add(const Duration(seconds: 2)));

    final after = await service.analyzeGame(
      gameSans: ['d4', 'g6'],
      meWhite: true,
    );
    expect(after!.matchedPlies, 2);
  });
}
