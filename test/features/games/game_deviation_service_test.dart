import 'dart:io';

import 'package:chess_auto_prep/features/games/services/game_deviation_service.dart';
import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The per-game deviation walker: a game against the designated repertoire
/// chapters — every path in them, matched as moves rather than SAN spellings —
/// deepest match wins, side-aware "who left book".
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

  test('a model game in the file is not part of the book', () async {
    // A course export: two real lines, plus a model game whose moves run far
    // past where the preparation actually stops.
    await writeChapter('Main.pgn', '''
$mainChapter
[Event "QGD"]
[White "3. Model games"]
[Black "Kasparov, G – Karpov, A"]
[Result "*"]
[ModelGameWhite "Kasparov, G"]
[ModelGameBlack "Karpov, A"]
[ModelGameResult "1-0"]

1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Bg5 Be7 5. e3 O-O *
''');
    await settings.setPaths(white: true, paths: [tempDir.path]);

    // 4... Be7 is in the model game but not in the repertoire, which ends at
    // 4. Bg5 — the deviation must be reported there, not swallowed.
    final report = await service.analyzeGame(
      gameSans: ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6', 'Bg5', 'Be7'],
      meWhite: true,
    );

    expect(report!.inBook, isFalse);
    expect(report.bookEnded, isTrue);
    expect(report.matchedPlies, 7);
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

  group('analyzeGameByRepertoire (one verdict per designated book)', () {
    // Two White books that diverge from the same game at different points:
    // the aggregate "deepest match wins" answer hides what the other says.
    const shallowChapter = '''
// Color: White

[Event "London"]
[Result "*"]

1. d4 d5 2. Bf4 *
''';

    test('reports every designated folder separately', () async {
      final deep = await Directory('${tempDir.path}/deep').create();
      final shallow = await Directory('${tempDir.path}/shallow').create();
      await File('${deep.path}/Main.pgn').writeAsString(mainChapter);
      await File('${shallow.path}/London.pgn').writeAsString(shallowChapter);
      await settings.setPaths(white: true, paths: [deep.path, shallow.path]);

      final reports = await service.analyzeGameByRepertoire(
        gameSans: ['d4', 'd5', 'c4', 'e6', 'Nf3'],
        meWhite: true,
      );

      expect(reports.keys, unorderedEquals([deep.path, shallow.path]));
      expect(reports[deep.path]!.matchedPlies, 4);
      expect(reports[deep.path]!.playedSan, 'Nf3');
      expect(reports[shallow.path]!.matchedPlies, 2);
      expect(reports[shallow.path]!.playedSan, 'c4');
    });

    test('analyzeGame still collapses to the deepest of them', () async {
      final deep = await Directory('${tempDir.path}/deep2').create();
      final shallow = await Directory('${tempDir.path}/shallow2').create();
      await File('${deep.path}/Main.pgn').writeAsString(mainChapter);
      await File('${shallow.path}/London.pgn').writeAsString(shallowChapter);
      await settings.setPaths(white: true, paths: [shallow.path, deep.path]);

      final report = await service.analyzeGame(
        gameSans: ['d4', 'd5', 'c4', 'e6', 'Nf3'],
        meWhite: true,
      );
      expect(report!.matchedPlies, 4, reason: 'the deeper book wins');
    });

    test('an explicit folder list overrides the designations', () async {
      final other = await Directory('${tempDir.path}/other').create();
      await File('${other.path}/London.pgn').writeAsString(shallowChapter);
      await settings.setPaths(white: true, paths: [tempDir.path]);

      final reports = await service.analyzeGameByRepertoire(
        gameSans: ['d4', 'd5', 'c4'],
        meWhite: true,
        folders: [other.path],
      );
      expect(reports.keys, [other.path]);
    });

    test('a game with no moves yields nothing', () async {
      await settings.setPaths(white: true, paths: [tempDir.path]);
      expect(
        await service.analyzeGameByRepertoire(gameSans: [], meWhite: true),
        isEmpty,
      );
    });
  });

  group('[%transposes] graft', () {
    // A generated book: the Nf6 move order is cut where it transposes into
    // the d5 line, which carries the continuation.
    const transposing = '''
// Color: White

[Event "Main"]
[Result "*"]

1. Nf3 d5 2. d4 Nf6 3. c4 e6 4. Nc3 *

[Event "Cut"]
[Result "*"]

1. Nf3 Nf6 2. d4 d5 3. c4 {Transposes to 1. Nf3 d5 2. d4 Nf6 3. c4. [%transposes Nf3 d5 d4 Nf6 c4]} *
''';

    test(
      'a game following the cut move order stays in book past the cut',
      () async {
        await writeChapter('T.pgn', transposing);
        await settings.setPaths(white: true, paths: [tempDir.path]);

        final report = await service.analyzeGame(
          gameSans: ['Nf3', 'Nf6', 'd4', 'd5', 'c4', 'e6', 'Nc3', 'Be7'],
          meWhite: true,
        );

        expect(report, isNotNull);
        // 4...Be7 is past the end of the owner line: book ended, no deviation
        // was reported at 3...e6 or 4.Nc3.
        expect(report!.matchedPlies, 7);
        expect(report.bookEnded, isTrue);
      },
    );

    test(
      'a deviation after the cut names the owner\'s expected move',
      () async {
        await writeChapter('T.pgn', transposing);
        await settings.setPaths(white: true, paths: [tempDir.path]);

        final report = await service.analyzeGame(
          gameSans: ['Nf3', 'Nf6', 'd4', 'd5', 'c4', 'e6', 'Nf3'],
          meWhite: true,
        );

        expect(report!.matchedPlies, 6);
        expect(report.byMe, isTrue);
        expect(report.expectedSans, ['Nc3']);
      },
    );

    test('a pointer to a line the chapter lacks is ignored', () async {
      await writeChapter('T.pgn', '''
// Color: White

[Event "Cut"]
[Result "*"]

1. Nf3 Nf6 2. d4 d5 3. c4 {[%transposes Nf3 d5 d4 Nf6 c4]} *
''');
      await settings.setPaths(white: true, paths: [tempDir.path]);
      final report = await service.analyzeGame(
        gameSans: ['Nf3', 'Nf6', 'd4', 'd5', 'c4', 'e6'],
        meWhite: true,
      );
      expect(report!.matchedPlies, 5);
      expect(report.bookEnded, isTrue);
    });
  });

  group('variations and spellings', () {
    test('a variation in brackets is part of the book', () async {
      // A study export: most of the theory is in brackets.
      await writeChapter('Study.pgn', '''
// Color: White

[Event "Open games"]
[Result "*"]

1. e4 e5 (1... c5 2. Nf3 d6 (2... Nc6 3. Bb5 g6) 3. d4) 2. Nf3 Nc6 3. Bb5 *
''');
      await settings.setPaths(white: true, paths: [tempDir.path]);

      // The game follows the nested variation, then I leave it.
      final report = await service.analyzeGame(
        gameSans: ['e4', 'c5', 'Nf3', 'Nc6', 'Bc4'],
        meWhite: true,
      );
      expect(report!.matchedPlies, 4);
      expect(report.playedSan, 'Bc4');
      expect(report.byMe, isTrue);
      expect(report.expectedSans, ['Bb5']);

      // The opponent's choices at a fork are mainline and variation together.
      final atMoveOne = await service.analyzeGame(
        gameSans: ['e4', 'd5'],
        meWhite: true,
      );
      expect(atMoveOne!.expectedSans, unorderedEquals(['e5', 'c5']));

      // Running past the end of a variation is a book end, like the mainline.
      final past = await service.analyzeGame(
        gameSans: ['e4', 'c5', 'Nf3', 'Nc6', 'Bb5', 'g6', 'O-O'],
        meWhite: true,
      );
      expect(past!.bookEnded, isTrue);
      expect(past.matchedPlies, 6);
    });

    test('the same move spelled differently still matches', () async {
      await writeChapter('Spelling.pgn', '''
// Color: White

[Event "L"]
[Result "*"]

1. e4 e5 2. Ngf3 Nc6 3. Bb5+ a6 4. Bxc6 dxc6 5. O-O Bd6 *
''');
      await settings.setPaths(white: true, paths: [tempDir.path]);

      // Minimal disambiguation, no check mark, a glyph on a move, and the
      // castling the site exports — all the same moves.
      final report = await service.analyzeGame(
        gameSans: [
          'e4',
          'e5',
          'Nf3',
          'Nc6',
          'Bb5',
          'a6?!',
          'Bxc6',
          'dxc6',
          'O-O',
          'Bc5',
        ],
        meWhite: true,
      );
      expect(report!.matchedPlies, 9);
      expect(report.playedSan, 'Bc5');
      expect(report.expectedSans, ['Bd6']);
    });

    test('an illegal move in the book ends that line, not the walk', () async {
      await writeChapter('Broken.pgn', '''
// Color: White

[Event "Typo"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Bxe5 Nf6 *

[Event "Fine"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 *
''');
      await settings.setPaths(white: true, paths: [tempDir.path]);
      final report = await service.analyzeGame(
        gameSans: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Bc4'],
        meWhite: true,
      );
      expect(report!.matchedPlies, 6);
      expect(report.expectedSans, [
        'Ba4',
      ], reason: 'the typo is not a book move');
    });
  });

  group('chapters that reach the same depth', () {
    test(
      'are read as one book: an ending chapter cannot hide a move',
      () async {
        // Alphabetically first, so it is walked first.
        await writeChapter('Anti.pgn', '''
// Color: White

[Event "Anti"]
[Result "*"]

1. e4 c5 2. Nf3 *
''');
        await writeChapter('Najdorf.pgn', '''
// Color: White

[Event "Najdorf"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 *
''');
        await settings.setPaths(white: true, paths: [tempDir.path]);

        final report = await service.analyzeGame(
          gameSans: ['e4', 'c5', 'Nf3', 'e6', 'd4'],
          meWhite: true,
        );
        expect(report!.matchedPlies, 3);
        expect(
          report.bookEnded,
          isFalse,
          reason: 'Najdorf still has a move here',
        );
        expect(report.byMe, isFalse);
        expect(report.expectedSans, ['d6']);
        expect(report.chapterName, 'Najdorf');
      },
    );

    test('offer the union of their moves', () async {
      await writeChapter('Anti.pgn', '''
// Color: White

[Event "Anti"]
[Result "*"]

1. e4 c5 2. Nf3 Nc6 3. Bb5 *
''');
      await writeChapter('Najdorf.pgn', '''
// Color: White

[Event "Najdorf"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 *
''');
      await settings.setPaths(white: true, paths: [tempDir.path]);

      final report = await service.analyzeGame(
        gameSans: ['e4', 'c5', 'Nf3', 'e6'],
        meWhite: true,
      );
      expect(report!.expectedSans, unorderedEquals(['Nc6', 'd6']));
    });

    test(
      'across folders, a book with a move here beats one that ended',
      () async {
        final ending = await Directory('${tempDir.path}/a-ending').create();
        final living = await Directory('${tempDir.path}/b-living').create();
        await File('${ending.path}/Main.pgn').writeAsString('''
// Color: White

[Event "E"]
[Result "*"]

1. e4 c5 2. Nf3 *
''');
        await File('${living.path}/Main.pgn').writeAsString('''
// Color: White

[Event "L"]
[Result "*"]

1. e4 c5 2. Nf3 d6 *
''');
        await settings.setPaths(white: true, paths: [ending.path, living.path]);

        final report = await service.analyzeGame(
          gameSans: ['e4', 'c5', 'Nf3', 'e6'],
          meWhite: true,
        );
        expect(report!.bookEnded, isFalse);
        expect(report.chapterPath, '${living.path}/Main.pgn');
      },
    );
  });
}
