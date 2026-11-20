import 'dart:io';

import 'package:chess_auto_prep/features/library/library.dart';
import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/storage/chapter_directory.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';

/// Lines moved between chapter files on disk, and the training rows that
/// name them: a line keeps its schedule wherever it goes, and one that has a
/// schedule is never folded away into another line.
void main() {
  late Directory documents;
  late Directory support;
  late Library library;
  late DocumentSession session;
  late DocumentSaver saver;

  String at(String relative) => p.join(documents.path, relative);

  String text(String relative) => File(at(relative)).readAsStringSync();

  String reviews() => text('repertoire_reviews.csv');

  const reviewsHeader =
      'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,'
      'last_rating,last_reviewed_utc,pass_count,fail_count,excluded';

  /// One review row for the line [id] of [chapter], as the trainer writes it.
  void trainOn(String chapter, String id) =>
      File(at('repertoire_reviews.csv')).writeAsStringSync(
        '$reviewsHeader\n'
        '"${at(chapter)}",$id,Indian,2.50,1.00,2026-09-20T00:00:00.000Z,'
        'good,,1,0,false\n',
      );

  const main = '''
// Main
// Color: White

[Event "Queen's"]
[LineID "queens"]

1. d4 d5 2. c4 e6 *

[Event "Indian"]
[LineID "indian"]

1. d4 Nf6 2. c4 g6 *
''';
  const sidelines = '''
// Sidelines
// Color: White

[Event "Catalan"]
[LineID "catalan"]

1. d4 Nf6 2. c4 e6 3. g3 *
''';

  ChapterRef chapter(String name) => library.repertoires
      .firstWhere((folder) => folder.name == 'KID')
      .chapters
      .firstWhere((c) => c.name == name);

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('v2-line-moves-');
    support = await Directory.systemTemp.createTemp('v2-line-moves-support-');
    final root = p.join(documents.path, 'repertoires');
    final store = PgnFileStore(documents: documents, support: support);
    saver = DocumentSaver(store, delay: Duration.zero);
    session = DocumentSession(store, saver);
    final files = ChapterDirectory(Directory(root), recovery: store.recovery);
    library = libraryOver(files, store, session, saver, root: root);
    File(at('repertoires/KID/Main.pgn'))
      ..createSync(recursive: true)
      ..writeAsStringSync(main);
    File(at('repertoires/KID/Sidelines.pgn')).writeAsStringSync(sidelines);
    await library.refresh();
    await session.open(chapter('Main'));
  });

  tearDown(() async {
    library.dispose();
    session.dispose();
    saver.dispose();
    await documents.delete(recursive: true);
    await support.delete(recursive: true);
  });

  test('a line moved to another chapter takes its training rows', () async {
    trainOn('repertoires/KID/Main.pgn', 'indian');

    expect(
      await library.moveLines(games: {1}, to: chapter('Sidelines')),
      isA<LibraryDone>(),
    );

    expect(text('repertoires/KID/Sidelines.pgn'), contains('1. d4 Nf6 2. c4 g6'));
    expect(text('repertoires/KID/Main.pgn'), isNot(contains('Indian')));
    expect(reviews(), contains("${at('repertoires/KID/Sidelines.pgn')},indian,"));
    expect(reviews(), isNot(contains(at('repertoires/KID/Main.pgn'))));
  });

  test('a line with a schedule is not folded into another line', () async {
    trainOn('repertoires/KID/Main.pgn', 'indian');

    final folded = await library.moveLines(
      games: {1},
      to: chapter('Sidelines'),
      asSidelineOf: 0,
    );

    expect(folded, isA<LibraryFailure>());
    expect((folded as LibraryFailure).detail, contains('training history'));
    expect(text('repertoires/KID/Main.pgn'), main);
    expect(text('repertoires/KID/Sidelines.pgn'), sidelines);
    expect(reviews(), contains('"${at('repertoires/KID/Main.pgn')}",indian'));
  });

  test('a line past the end of the chapter is left out of a move', () async {
    expect(
      await library.moveLines(games: {1, 2}, to: chapter('Sidelines')),
      isA<LibraryDone>(),
    );

    expect(text('repertoires/KID/Sidelines.pgn'), contains('1. d4 Nf6 2. c4 g6'));
    expect(text('repertoires/KID/Main.pgn'), isNot(contains('Indian')));
  });
}
