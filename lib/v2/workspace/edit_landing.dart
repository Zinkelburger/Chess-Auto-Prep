import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/games_written.dart';
import '../chess/pgn/line_id_pins.dart';
import '../storage/edit_scope.dart';

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
