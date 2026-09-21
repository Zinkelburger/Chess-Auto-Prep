import 'package:dartchess/dartchess.dart' show Side;

import '../../chess/fen.dart';
import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/study.dart';
import '../../chess/pgn/study_edits.dart';
import '../../workspace/document_session.dart';

/// The chapter operations of a study, as commands over the open document.
///
/// A study's chapters are the games of one file, and that file is what the
/// session already holds, so these need no state of their own: each works
/// out the new chapter with a pure edit from `chess/pgn/study_edits.dart`,
/// hands it to the session with what the edit says it changed, and answers
/// the sentence to show when it could not. Null means it happened.
///
/// The study's name in the tags is the one the file already claims, falling
/// back to what the file is called: renaming a chapter must not quietly
/// rename the study in every `Event` tag it rewrites.

/// A new chapter at the end, which the session then shows.
String? addStudyChapter(
  DocumentSession session, {
  required String name,
  required Side orientation,
  Fen root = Fen.initial,
}) => _apply(
  session,
  (chapter) => addChapter(
    chapter,
    study: studyNameOf(chapter),
    name: name.isEmpty ? nextChapterName(studyChapters(chapter.lines)) : name,
    orientation: orientation,
    root: root,
  ),
);

String? renameStudyChapter(
  DocumentSession session, {
  required int index,
  required String name,
}) => _apply(
  session,
  (chapter) => renameChapter(
    chapter,
    study: studyNameOf(chapter),
    index: index,
    name: name,
  ),
);

String? setStudyChapterOrientation(
  DocumentSession session, {
  required int index,
  required Side orientation,
}) => _apply(
  session,
  (chapter) => setChapterOrientation(
    chapter,
    study: studyNameOf(chapter),
    index: index,
    orientation: orientation,
  ),
);

/// Moves the chapter at [index] one place up ([by] of -1) or down (1).
String? moveStudyChapter(
  DocumentSession session, {
  required int index,
  required int by,
}) => _apply(session, (chapter) => moveChapter(chapter, index: index, by: by));

String? deleteStudyChapter(DocumentSession session, {required int index}) =>
    _apply(session, (chapter) => deleteChapter(chapter, index: index));

/// The name the file's own tags give the study, or what the file is called
/// when they give none.
String studyNameOf(Chapter chapter) =>
    studyNameIn(chapter.lines) ?? chapter.name;

/// Runs [edit] over the open chapter through the session, which is the one
/// place an edit becomes a file. Answers the sentence to show, or null.
String? _apply(DocumentSession session, ChapterEdit Function(Chapter) edit) {
  if (session.chapter?.game == null) return 'Open a study chapter first.';
  return session.apply(edit);
}
