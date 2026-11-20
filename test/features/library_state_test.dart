// What the library's list does when the workspace opens a chapter it does
// not hold.

import 'package:chess_auto_prep/features/library/library_state.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

void main() {
  test('a list that could not be read is read again when a chapter '
      'opens', () async {
    const text = '// Main\n// Color: White\n\n';
    final files = ScriptedFiles(
      listing: const RepertoiresUnreadable('Permission denied'),
    );
    final store = ScriptedDocumentStore();
    store.documents[ref('KID', 'Main').wholeFile] = Opened(
      text,
      scriptedRevision(text),
    );
    final saver = DocumentSaver(store, delay: Duration.zero);
    final session = DocumentSession(store, saver);
    final library = libraryOver(files, store, session, saver);
    addTearDown(() {
      library.dispose();
      session.dispose();
      saver.dispose();
    });
    await library.refresh();
    expect(library.state, isA<LibraryLoadFailed>());

    // The folder can be read again, and the user opens a chapter from
    // somewhere else: the list does not stay on its failure.
    files.listing = Repertoires([
      folder('KID', ['Main']),
    ]);
    await session.open(ref('KID', 'Main'));
    await pumpEventQueue();

    expect(library.state, isA<LibraryLoaded>());
    expect(library.repertoires.map((f) => f.name), ['KID']);
  });
}
