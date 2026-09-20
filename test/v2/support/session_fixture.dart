import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';

import 'scripted_store.dart';

/// A session and its saver over a scripted store, with one chapter already
/// open. Every test that edits a document starts here; nothing touches a
/// real file.
final class SessionFixture {
  SessionFixture._(this.store, this.saver, this.session, this.ref);

  final ScriptedDocumentStore store;
  final DocumentSaver saver;
  final DocumentSession session;
  final ChapterRef ref;

  /// What the scripted store holds for [ref] now.
  String get onDisk => switch (store.documents[ref]) {
    Opened(:final text) => text,
    _ => '',
  };

  /// Puts [text] on disk behind the session's back, as another writer would.
  void externalEdit(String text) =>
      store.documents[ref] = Opened(text, scriptedRevision(text));

  void dispose() {
    session.dispose();
    saver.dispose();
  }
}

ChapterRef chapterRef(String repertoire, String name) => ChapterRef(
  repertoire: repertoire,
  name: name,
  path: '/repertoires/$repertoire/$name.pgn',
);

/// Opens [text] as chapter [name] and returns everything a test needs to
/// drive it. [readOnly] opens it the way the store opens a file this app
/// may not write.
Future<SessionFixture> openSession(
  String text, {
  String name = 'Main',
  String repertoire = 'KID',
  String? readOnly,
}) async {
  final ref = chapterRef(repertoire, name);
  final store = ScriptedDocumentStore()
    ..documents[ref] = Opened(text, scriptedRevision(text), readOnly: readOnly);
  final saver = DocumentSaver(store);
  final session = DocumentSession(store, saver);
  final fixture = SessionFixture._(store, saver, session, ref);
  await session.open(ref);
  return fixture;
}
