import 'dart:io';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';

/// The library against real files: create a repertoire, add a chapter, rename
/// it, move it, delete it, and check the chapter PGNs and the training rows
/// that name them end up where they should.
void main() {
  late Directory documents;
  late Directory support;
  late Library library;
  late DocumentSession session;
  late DocumentSaver saver;

  String at(String relative) => p.join(documents.path, relative);

  bool exists(String relative) => File(at(relative)).existsSync();

  String reviews() => File(at('repertoire_reviews.csv')).readAsStringSync();

  /// A review row naming [chapter], as the trainer writes it.
  String review(String chapter, String line) =>
      '"${at(chapter)}",$line,Main,2.50,1.00,2026-09-20T00:00:00.000Z,good,,'
      '1,0,false';

  const reviewsHeader =
      'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,'
      'last_rating,last_reviewed_utc,pass_count,fail_count,excluded';

  /// One review row naming [chapter], as the trainer would leave it.
  void trainOn(String chapter) => File(
    at('repertoire_reviews.csv'),
  ).writeAsStringSync('$reviewsHeader\n${review(chapter, 'line_1')}\n');

  RepertoireFolder named(String name) =>
      library.repertoires.firstWhere((folder) => folder.name == name);

  ChapterRef chapter(String repertoire, String name) =>
      named(repertoire).chapters.firstWhere((c) => c.name == name);

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('v2-library-');
    support = await Directory.systemTemp.createTemp('v2-library-support-');
    final root = p.join(documents.path, 'repertoires');
    final store = PgnFileStore(documents: documents, support: support);
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    final files = ChapterDirectory(Directory(root));
    library = libraryOver(files, store, session, saver, root: root);
    await library.refresh();
  });

  tearDown(() async {
    library.dispose();
    session.dispose();
    saver.dispose();
    await documents.delete(recursive: true);
    await support.delete(recursive: true);
  });

  test('a new repertoire is a folder with one chapter in it', () async {
    expect(
      await library.createRepertoire('Benoni', Side.black),
      isA<LibraryAdded>(),
    );
    expect(
      File(at('repertoires/Benoni/Main.pgn')).readAsStringSync(),
      startsWith('// Benoni\n// Color: Black\n'),
    );
    expect(named('Benoni').chapters.single.name, 'Main');
  });

  test(
    'an imported study is one course file of chapters, with no staging left',
    () async {
      const study =
          '[Event "S: A"]\n[ChapterName "A"]\n\n1. e4 e5 (1... c5) *\n\n'
          '[Event "S: B"]\n[ChapterName "B"]\n\n1. d4 d5 *\n';
      final result = await library.importText(study, name: 'Study');
      expect(result, isA<LibraryAdded>());
      final first = (result as LibraryAdded).first;
      expect(first.path, at('repertoires/Study/Study.pgn'));
      expect(first.section, 'A');
      expect(
        File(at('repertoires/Study/Study.pgn')).readAsStringSync(),
        contains('1. e4 c5 *'),
      );
      expect(
        Directory(at('repertoires'))
            .listSync()
            .map((entry) => p.basename(entry.path))
            .where((name) => name.startsWith('.')),
        isEmpty,
      );
      expect(named('Study').chapters.map((c) => c.name), ['A', 'B']);
    },
  );

  test('a renamed chapter takes its training rows with it', () async {
    await library.createRepertoire('Benoni', Side.black);
    await library.createChapter(named('Benoni'), 'Modern');
    trainOn('repertoires/Benoni/Modern.pgn');
    expect(
      await library.renameChapter(chapter('Benoni', 'Modern'), 'Modern Benoni'),
      isA<LibraryDone>(),
    );
    expect(exists('repertoires/Benoni/Modern Benoni.pgn'), isTrue);
    expect(exists('repertoires/Benoni/Modern.pgn'), isFalse);
    expect(reviews(), contains(at('repertoires/Benoni/Modern Benoni.pgn')));
  });

  test('a chapter moved to another repertoire keeps its rows', () async {
    await library.createRepertoire('Benoni', Side.black);
    await library.createChapter(named('Benoni'), 'Modern');
    trainOn('repertoires/Benoni/Modern.pgn');
    await library.createRepertoire('Sidelines', Side.black);
    expect(
      await library.moveChapter(
        chapter('Benoni', 'Modern'),
        named('Sidelines'),
      ),
      isA<LibraryDone>(),
    );
    expect(exists('repertoires/Sidelines/Modern.pgn'), isTrue);
    expect(reviews(), contains(at('repertoires/Sidelines/Modern.pgn')));
  });

  test('a deleted repertoire is in recovery, rows and all', () async {
    await library.createRepertoire('Sidelines', Side.black);
    await library.createChapter(named('Sidelines'), 'Modern');
    trainOn('repertoires/Sidelines/Modern.pgn');
    expect(
      await library.deleteRepertoire(named('Sidelines')),
      isA<LibraryDone>(),
    );
    expect(
      Directory(at('repertoires/Sidelines/.cap-pgn-history')).listSync(),
      hasLength(2),
    );
    // A folder with no chapters left is not a repertoire any more.
    expect(library.repertoires, isEmpty);
    // The rows followed the chapter into recovery, so restoring it restores
    // its schedule with it.
    expect(reviews(), contains('.cap-pgn-history'));
  });

  Future<List<DeletedChapter>> deletedChapters() async =>
      (await library.deleted() as DeletedChapters).chapters;

  test(
    'a deleted repertoire comes back chapter by chapter, rows and all',
    () async {
      await library.createRepertoire('Sidelines', Side.black);
      await library.createChapter(named('Sidelines'), 'Modern');
      trainOn('repertoires/Sidelines/Modern.pgn');
      await library.deleteRepertoire(named('Sidelines'));
      final gone = await deletedChapters();
      expect(gone.map((c) => c.name), unorderedEquals(['Main', 'Modern']));
      expect(gone.every((c) => c.repertoire == 'Sidelines'), isTrue);

      for (final chapter in gone) {
        expect(await library.restoreChapter(chapter), isA<LibraryDone>());
      }
      expect(named('Sidelines').chapters.map((c) => c.name), [
        'Main',
        'Modern',
      ]);
      expect(
        File(at('repertoires/Sidelines/Modern.pgn')).readAsStringSync(),
        startsWith('// Modern\n'),
      );
      expect(reviews(), contains(at('repertoires/Sidelines/Modern.pgn')));
      expect(reviews(), isNot(contains('.cap-pgn-history')));
      expect(await deletedChapters(), isEmpty);
    },
  );

  test('a deleted repertoire takes its course file to recovery once', () async {
    final folder = Directory(at('repertoires/Course'))
      ..createSync(recursive: true);
    File(p.join(folder.path, 'Course.pgn')).writeAsStringSync(
      '// Color: White\n\n'
      '[Event "Ruy"]\n[ChapterName "Open games"]\n\n1. e4 e5 2. Nf3 *\n\n'
      '[Event "Alapin"]\n[ChapterName "Sicilian"]\n\n1. e4 c5 2. c3 *\n',
    );
    File(
      p.join(folder.path, 'Zeta.pgn'),
    ).writeAsStringSync('// Zeta\n// Color: White\n\n');
    await library.refresh();
    expect(named('Course').chapters.map((c) => c.name), [
      'Open games',
      'Sicilian',
      'Zeta',
    ]);

    expect(await library.deleteRepertoire(named('Course')), isA<LibraryDone>());
    expect(library.repertoires, isEmpty);
    expect(
      (await deletedChapters()).map((c) => c.name),
      unorderedEquals(['Course', 'Zeta']),
    );
  });

  test(
    'an import named like a deleted repertoire takes the next name',
    () async {
      await library.createRepertoire('Sidelines', Side.black);
      await library.deleteRepertoire(named('Sidelines'));
      // The folder stays, holding the chapter's recovery copy, and a folder
      // with no chapter in it is not listed.
      expect(Directory(at('repertoires/Sidelines')).existsSync(), isTrue);
      expect(library.repertoires, isEmpty);

      final result = await library.importText(
        '[Event "x"]\n\n1. e4 e5 *\n',
        name: 'Sidelines',
      );
      expect(result, isA<LibraryAdded>());
      expect(
        p.dirname((result as LibraryAdded).first.path),
        at('repertoires/Sidelines (2)'),
      );
      expect(named('Sidelines (2)').chapters, hasLength(1));
      expect(await deletedChapters(), hasLength(1), reason: 'still restorable');
    },
  );

  test('a restore never replaces a chapter of the same name', () async {
    await library.createRepertoire('Benoni', Side.black);
    await library.createChapter(named('Benoni'), 'Modern');
    await library.deleteChapter(chapter('Benoni', 'Modern'));
    await library.createChapter(named('Benoni'), 'Modern');
    File(at('repertoires/Benoni/Modern.pgn')).writeAsStringSync('// New\n');
    final gone = (await deletedChapters()).single;

    expect(await library.restoreChapter(gone), isA<LibraryNameTaken>());
    expect(
      File(at('repertoires/Benoni/Modern.pgn')).readAsStringSync(),
      '// New\n',
    );
    expect(
      await library.restoreChapter(gone, name: 'Modern (restored)'),
      isA<LibraryDone>(),
    );
    expect(
      File(at('repertoires/Benoni/Modern (restored).pgn')).readAsStringSync(),
      startsWith('// Modern\n'),
    );
    expect(await deletedChapters(), isEmpty);
  });

  /// A repertoire as generation leaves it: two chapters, the raw-game sidecar
  /// written beside one of them, and the bundle folder under it.
  Future<void> generatedRepertoire() async {
    await library.createRepertoire('Benoni', Side.black);
    await library.createChapter(named('Benoni'), 'Modern');
    File(at('repertoires/Benoni/Modern_raw_games.pgn'))
      ..createSync()
      ..writeAsStringSync('[Event "?"]\n\n1. d4 *\n');
    Directory(at('repertoires/Benoni/.cap-generation')).createSync();
    File(
      at('repertoires/Benoni/.cap-generation/run.json'),
    ).writeAsStringSync('{}');
    await library.refresh();
  }

  test('a renamed repertoire takes everything in it', () async {
    await generatedRepertoire();
    trainOn('repertoires/Benoni/Main.pgn');
    expect(
      await library.renameRepertoire(named('Benoni'), 'Modern Benoni'),
      isA<LibraryDone>(),
    );
    expect(exists('repertoires/Modern Benoni/Main.pgn'), isTrue);
    expect(exists('repertoires/Modern Benoni/Modern.pgn'), isTrue);
    expect(exists('repertoires/Modern Benoni/Modern_raw_games.pgn'), isTrue);
    expect(
      File(
        at('repertoires/Modern Benoni/.cap-generation/run.json'),
      ).existsSync(),
      isTrue,
    );
    // Nothing of the old folder is left, not even the folder.
    expect(Directory(at('repertoires/Benoni')).existsSync(), isFalse);
  });

  test('the training rows of every chapter follow the folder', () async {
    await generatedRepertoire();
    File(at('repertoire_reviews.csv')).writeAsStringSync(
      '$reviewsHeader\n'
      '${review('repertoires/Benoni/Main.pgn', 'line_1')}\n'
      '${review('repertoires/Benoni/Modern.pgn', 'line_2')}\n',
    );
    expect(
      await library.renameRepertoire(named('Benoni'), 'Modern Benoni'),
      isA<LibraryDone>(),
    );
    expect(reviews(), contains(at('repertoires/Modern Benoni/Main.pgn')));
    expect(reviews(), contains(at('repertoires/Modern Benoni/Modern.pgn')));
    expect(reviews(), isNot(contains(at('repertoires/Benoni/'))));
  });

  test('a repertoire rename onto a folder in use replaces nothing', () async {
    await library.createRepertoire('Benoni', Side.black);
    await library.createRepertoire('Sidelines', Side.white);
    // The list has both, so this is refused before it reaches the disk; the
    // store refuses it again if it ever gets there.
    expect(
      await library.renameRepertoire(named('Benoni'), 'Sidelines'),
      isA<LibraryNameTaken>(),
    );
    expect(
      File(at('repertoires/Sidelines/Main.pgn')).readAsStringSync(),
      contains('// Color: White'),
    );
    expect(exists('repertoires/Benoni/Main.pgn'), isTrue);
  });

  test('the open chapter autosaves to its renamed folder', () async {
    await library.createRepertoire('Benoni', Side.black);
    expect(
      await session.open(chapter('Benoni', 'Main')),
      isA<DocumentOpened>(),
    );
    expect(
      await library.renameRepertoire(named('Benoni'), 'Modern Benoni'),
      isA<LibraryDone>(),
    );
    expect(session.source?.path, at('repertoires/Modern Benoni/Main.pgn'));
    session.playMove('d2d4');
    await saver.flush();
    expect(
      File(at('repertoires/Modern Benoni/Main.pgn')).readAsStringSync(),
      contains('d4'),
    );
  });

  test('a repertoire whose name is taken is refused', () async {
    await library.createRepertoire('Benoni', Side.white);
    expect(
      await library.createRepertoire('Benoni', Side.white),
      isA<LibraryNameTaken>(),
    );
    expect(Directory(at('repertoires')).listSync(), hasLength(1));
  });
}
