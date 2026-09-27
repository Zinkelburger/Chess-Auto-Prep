import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/games_written.dart';
import '../chess/pgn/line_id_pins.dart';
import '../storage/chapter_files.dart';
import '../storage/document_ref.dart';
import '../storage/edit_scope.dart';
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

// An undo meets what [readDocument] refuses to open — a game the file does
// not have, a chapter no game is called by — whenever it takes back the
// edit that made them. The version it put back is already the file, so it
// cannot refuse: it shows the nearest thing to where the user was.

/// [file], the version an undo put back, on the game whose text [showing]
/// is ([showingGame]); when the file does not hold it, on the game at the
/// same index, or its last game when the undo took back the one added there.
Chapter gameAfterUndo(Chapter file, String? showing) {
  final shown = showingGame(file, showing);
  final game = shown.game;
  final last = shown.lines.length - 1;
  if (game == null || game <= last || last < 0) return shown;
  return withGame(shown, last);
}

/// The chapter [view] of a course [file], the version an undo put back —
/// unless the undo took back the name its games were given, which leaves no
/// game called by it. Then it is the chapter those games, at [places] before
/// the undo, are called now; the file's first when none of them is left.
({Chapter chapter, SectionView? view}) chapterAfterUndo(
  Chapter file,
  SectionView view,
  List<int> places,
) {
  if (view.places.isNotEmpty) return (chapter: view.chapter, view: view);
  final kept = [
    for (final at in places)
      if (at < file.lines.length) at,
  ];
  final named = kept.isEmpty ? view.section : sectionOf(file.lines[kept.first]);
  final shown = partOf(file, sectionAfter(file, named));
  return (chapter: shown?.chapter ?? file, view: shown);
}

/// An edit of the chapter on the board as its file takes it: the file's
/// text, the scope the store checks that text against, and the chapter to
/// show afterwards — with its [SectionView] when it is one chapter of a
/// course file.
typedef Landing = ({
  String text,
  EditScope scope,
  Chapter chapter,
  SectionView? view,
});

/// [edited], an edit of [before] placed by [games], as its file writes it.
///
/// A chapter that is its whole file is written as it is, with the ids the
/// edit would change pinned ([withIdsPinned]); [written], when the edit said
/// only which games it wrote, is the scope, which the pins do not widen —
/// they land on games the edit wrote anyway. A chapter of a course file
/// ([view]) goes back into its file ([spliced]) and the file is written.
///
/// Null when a game the edit added could not be given its chapter's name.
Landing? landing(
  Chapter before,
  SectionView? view,
  Chapter edited,
  GamesArranged games, {
  GamesWritten? written,
}) {
  if (view == null) {
    final pinned = withIdsPinned(before, edited, games);
    return (
      text: writeChapter(pinned.chapter),
      scope: written == null
          ? GamesRearranged(pinned.games)
          : GamesEdited(written),
      chapter: pinned.chapter,
      view: null,
    );
  }
  final back = spliced(view, edited, games);
  if (back == null) return null;
  return fileLanding(view.file, back.file, back.games, view.section);
}

/// [edited], an edit of the whole course [file] placed by [games], showing
/// its chapter [section] afterwards — or its first, when the edit left none
/// of that chapter's games.
Landing fileLanding(
  Chapter file,
  Chapter edited,
  GamesArranged games,
  String? section,
) {
  final edit = fileEdit(file, edited, games, section);
  return (
    text: writeChapter(edit.file),
    scope: GamesRearranged(edit.games),
    chapter: edit.shown.chapter,
    view: edit.shown,
  );
}
