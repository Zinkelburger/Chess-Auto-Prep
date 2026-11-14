// The library's smaller promises: a new repertoire is one chapter of no
// lines, a file holding two chapters by tag is shared, the list hears a
// command start and end, a catalog it was given is not its to take down,
// and a command that ends after the library is gone says nothing.
import 'dart:async';

import 'package:chess_auto_prep/features/library/library.dart';
import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/workspace/book/repertoire_catalog.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

void main() {
  test('a new repertoire is one chapter of no lines', () async {
    final fixture = await openLibrary(const []);
    addTearDown(fixture.dispose);
    final made = await fixture.library.createRepertoire('Najdorf');
    expect(made, isA<LibraryAdded>());
    final added = made as LibraryAdded;
    expect((added.chapters, added.lines), (1, 0));
  });

  test('a file holding two chapters by tag is shared by both', () async {
    const path = '/repertoires/KID/Course.pgn';
    final fixture = await openLibrary([
      RepertoireFolder(
        name: 'KID',
        path: '/repertoires/KID',
        modified: DateTime(2026),
        chapters: [
          ChapterRef.at(path, section: 'A'),
          ChapterRef.at(path, section: 'B'),
        ],
      ),
    ]);
    addTearDown(fixture.dispose);
    expect(fixture.library.sharesFile(ChapterRef.at(path)), isTrue);
    expect(
      fixture.library.sharesFile(ref('KID', 'Main')),
      isFalse,
      reason: 'a file of its own',
    );
  });

  test('the list hears a command start and end', () async {
    final fixture = await openLibrary(const []);
    addTearDown(fixture.dispose);
    final busy = <bool>[];
    fixture.library.addListener(() => busy.add(fixture.library.busy));
    await fixture.library.createRepertoire('Najdorf');
    expect(busy, contains(true));
    expect(fixture.library.busy, isFalse);
    expect(busy.last, isFalse);
  });

  group('taken down', () {
    late ScriptedDocumentStore store;
    late DocumentSaver saver;
    late DocumentSession session;
    late ScriptedFiles files;

    setUp(() {
      store = ScriptedDocumentStore();
      saver = DocumentSaver(store);
      session = DocumentSession(store, saver);
      files = ScriptedFiles();
      addTearDown(() {
        session.dispose();
        saver.dispose();
      });
    });

    Library library({RepertoireCatalog? catalog}) => Library(
      files: files,
      documents: store,
      saver: saver,
      session: session,
      picker: ScriptedPicker(),
      root: '/repertoires',
      catalog: catalog,
    );

    test('it leaves a catalog it was given to its owner', () {
      final catalog = RepertoireCatalog(files: files, root: '/repertoires');
      addTearDown(catalog.dispose);
      library(catalog: catalog).dispose();
      expect(() => catalog.addListener(() {}), returnsNormally);
    });

    test('a command that ends after it is gone says nothing', () async {
      final gone = library();
      final gate = Completer<void>();
      store.createGate = gate;
      final making = gone.createRepertoire('Najdorf');
      await pumpEventQueue();
      gone.dispose();
      gate.complete();
      await expectLater(making, completes);
    });
  });
}
