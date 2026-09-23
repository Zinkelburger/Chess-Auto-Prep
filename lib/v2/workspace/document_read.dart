import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../storage/chapter_files.dart';
import '../storage/document_ref.dart';
import '../storage/pgn_document_store.dart' as store;

/// What reading a document for the workspace came to: the chapter to show,
/// or the sentence saying why there is none.
sealed class DocumentRead {
  const DocumentRead();
}

final class DocumentShown extends DocumentRead {
  const DocumentShown({
    required this.chapter,
    required this.view,
    required this.revision,
    required this.readOnly,
  });

  /// What goes on the board: the file, one game of it, or one chapter of a
  /// course file.
  final Chapter chapter;

  /// Where that chapter sits in its file, for one chapter of a course file;
  /// null when the chapter is the whole file or one game of it.
  final SectionView? view;

  /// The revision every later save is checked against.
  final Revision revision;

  /// Why this app may not write the file, or null when it may.
  final String? readOnly;
}

final class DocumentUnread extends DocumentRead {
  const DocumentUnread(this.reason);

  final String reason;
}

/// Reads [ref] through [documents] as the chapter the workspace shows.
/// [game] reads one game of the file as the whole document, which is what a
/// study chapter is; null merges its games, or takes the chapter [ref]
/// names in a course file.
Future<DocumentRead> readDocument(
  store.PgnDocumentStore documents,
  ChapterRef ref, {
  int? game,
}) async {
  switch (await documents.open(ref)) {
    case store.Opened(:final text, :final revision, :final readOnly):
      final (:file, :view) = await readShown(ref, text, game: game);
      // A chapter the file does not have would otherwise open as every
      // game merged, which looks like a chapter and is not one.
      if (game != null && game >= file.lines.length) {
        return DocumentUnread('${ref.name} has no chapter ${game + 1}');
      }
      if (view != null && view.places.isEmpty) {
        return DocumentUnread('${ref.name} is no longer in its file');
      }
      return DocumentShown(
        chapter: view?.chapter ?? file,
        view: view,
        revision: revision,
        readOnly: readOnly,
      );
    case store.Absent():
      return DocumentUnread('${ref.name} is no longer on disk');
    case store.Unreadable(:final detail):
      return DocumentUnread('Could not read ${ref.name}: $detail');
  }
}

/// [text], the file [ref] names, as read for the workspace: the whole file
/// or the one [game] of it, and — for one chapter of a course file — where
/// that chapter sits in it.
Future<({Chapter file, SectionView? view})> readShown(
  ChapterRef ref,
  String text, {
  int? game,
}) async {
  final file = await readChapter(name: ref.fileName, text: text, game: game);
  return (file: file, view: game == null ? partOf(file, ref.section) : null);
}
