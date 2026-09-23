import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_picker.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:path/path.dart' as p;

import 'scripted_files.dart';
import 'scripted_store.dart';
import 'viewer_fixture.dart';

/// A library over scripted files and a scripted store, with the workspace
/// owners it changes documents through. Nothing here touches a real file.
final class LibraryFixture {
  LibraryFixture._(
    this.files,
    this.store,
    this.picker,
    this.saver,
    this.session,
    this.library,
  );

  final ScriptedFiles files;
  final ScriptedDocumentStore store;

  /// What the file dialog answers when the library asks for a file.
  final ScriptedPicker picker;
  final DocumentSaver saver;
  final DocumentSession session;
  final Library library;

  /// What the scripted store holds for the document at [path].
  String? textAt(String path) => switch (store.documents[DocumentRef(path)]) {
    Opened(:final text) => text,
    _ => null,
  };

  void dispose() {
    library.dispose();
    session.dispose();
    saver.dispose();
  }
}

/// A loaded library holding [folders], with every chapter in the store as
/// [text] and, when [open] is given, that chapter open in the workspace.
///
/// [delay] is how long the saver waits after an edit. Zero, unless the test
/// is about a draft that is still waiting when the library changes the file
/// underneath it.
Future<LibraryFixture> openLibrary(
  List<RepertoireFolder> folders, {
  String text = '// Main\n// Color: White\n\n',
  ChapterRef? open,
  Duration delay = Duration.zero,
}) async {
  final store = ScriptedDocumentStore();
  // A folder is empty when the store holds no document inside it, so
  // "the folder went too" is an assertion about what was written rather than
  // about which calls were made.
  final files = ScriptedFiles(
    listing: Repertoires(folders),
    isEmpty: (folder) =>
        !store.documents.keys.any((ref) => p.isWithin(folder, ref.path)),
  );
  for (final folder in folders) {
    for (final chapter in folder.chapters) {
      store.documents[chapter.wholeFile] = Opened(text, scriptedRevision(text));
    }
  }
  final saver = DocumentSaver(store, delay: delay);
  final session = DocumentSession(store, saver);
  final picker = ScriptedPicker();
  final library = libraryOver(files, store, session, saver, picker: picker);
  await library.refresh();
  if (open != null) await session.open(open);
  return LibraryFixture._(files, store, picker, saver, session, library);
}

/// A library over [files] and [documents] under [root], changing documents
/// through [session] and [saver] as the app wires it.
Library libraryOver(
  ChapterFiles files,
  PgnDocumentStore documents,
  DocumentSession session,
  DocumentSaver saver, {
  PgnFilePicker? picker,
  String root = '/repertoires',
}) => Library(
  files: files,
  documents: documents,
  saver: saver,
  session: session,
  picker: picker ?? ScriptedPicker(),
  root: root,
);
