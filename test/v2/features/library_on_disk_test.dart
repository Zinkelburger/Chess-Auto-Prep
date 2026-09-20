import 'dart:io';

import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

  /// One review row naming [chapter], as the trainer would leave it.
  void trainOn(String chapter) =>
      File(at('repertoire_reviews.csv')).writeAsStringSync(
        'repertoire_id,line_id,due\n'
        '"${at(chapter)}","line_1","2026-09-20"\n',
      );

  RepertoireFolder named(String name) =>
      library.repertoires.firstWhere((folder) => folder.name == name);

  ChapterRef chapter(String repertoire, String name) =>
      named(repertoire).chapters.firstWhere((c) => c.name == name);

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('v2-library-');
    support = await Directory.systemTemp.createTemp('v2-library-support-');
    final root = p.join(documents.path, 'repertoires');
    final store = PgnFileStore(documents: documents, support: support);
    saver = DocumentSaver(store);
    session = DocumentSession(store, saver);
    library = Library(
      files: ChapterDirectory(Directory(root)),
      documents: store,
      session: session,
      saver: saver,
      root: root,
    );
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
      isA<LibraryDone>(),
    );
    expect(
      File(at('repertoires/Benoni/Main.pgn')).readAsStringSync(),
      startsWith('// Benoni\n// Color: Black\n'),
    );
    expect(named('Benoni').chapters.single.name, 'Main');
  });

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

  test('a repertoire whose name is taken is refused', () async {
    await library.createRepertoire('Benoni', Side.white);
    expect(
      await library.createRepertoire('Benoni', Side.white),
      isA<LibraryNameTaken>(),
    );
    expect(Directory(at('repertoires')).listSync(), hasLength(1));
  });
}
