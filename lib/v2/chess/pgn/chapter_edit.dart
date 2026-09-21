import 'chapter.dart';
import 'games_written.dart';

/// What an edit that may move, remove or rewrite whole games did.
///
/// Typed rather than thrown, and never a chapter on its own: the games the
/// edit wrote are half of the answer, because the store refuses a save that
/// cannot say what it is changing.
sealed class ChapterEdit {
  const ChapterEdit();
}

/// The chapter after the edit, and where each of its games came from.
final class ChapterEdited extends ChapterEdit {
  const ChapterEdited(this.chapter, this.games);

  final Chapter chapter;
  final GamesArranged games;
}

/// The edit would leave the file as it is, so nothing is written.
final class ChapterUnchanged extends ChapterEdit {
  const ChapterUnchanged();
}

/// The edit cannot be made without losing something the file holds.
/// [reason] is one plain English sentence fragment for the user.
final class ChapterEditRefused extends ChapterEdit {
  const ChapterEditRefused(this.reason);

  final String reason;
}

/// What a game that reading could not take whole refuses with. It keeps its
/// own bytes, so an edit that would have to write it again does not happen.
const lineNotWholeReason = 'a line in the way could not be read in full';
