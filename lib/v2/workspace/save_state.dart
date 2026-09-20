/// What a document's file is doing, and what an undo did to it.
///
/// The words the workspace reads off the saver: its widgets switch on these
/// and write the sentences, and nothing here knows how a file is written.
library;

/// What the file on disk is doing. Only [Saved] says it holds what the
/// screen shows.
sealed class SaveState {
  const SaveState();
}

final class Saved extends SaveState {
  const Saved();
}

final class Saving extends SaveState {
  const Saving();
}

/// Edited and not written yet, either waiting for a save in flight or on its
/// way out this instant.
final class Unsaved extends SaveState {
  const Unsaved();
}

final class SaveFailed extends SaveState {
  const SaveFailed(this.detail);

  /// The operating system's words; the widget writes the sentence.
  final String detail;
}

/// The store stopped the save because the text would have changed a game
/// the edit never touched. The words are still on the screen and the file is
/// as it was.
///
/// A conflict for the user's purposes — reload or save a copy — but it is
/// the app's mistake, not another writer's, so it says something else. The
/// store has already put the game it would have changed in the log.
final class SaveStopped extends SaveState {
  const SaveStopped();
}

/// Someone else wrote the file. The draft is kept and nothing more is
/// written until the user chooses what to do with it.
final class SaveConflict extends SaveState {
  const SaveConflict();
}

/// An undo asked for a version the store never kept, so nothing went back.
/// The file and the document are as they were.
final class RestoreStopped extends SaveState {
  const RestoreStopped();
}

/// The file is not one this app may write at all. Nothing was edited and
/// nothing will be: the document opened to read.
final class DocumentReadOnly extends SaveState {
  const DocumentReadOnly(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

sealed class UndoResult {
  const UndoResult();
}

/// The file is back at [text]; the caller reads its document from it again.
final class Restored extends UndoResult {
  const Restored(this.text);

  final String text;
}

/// Nothing was undone, and the history is as it was. [reason] is a sentence
/// for the user when there is more to say than "not now".
final class UndoRefused extends UndoResult {
  const UndoRefused([this.reason]);

  final String? reason;
}

/// Nothing goes back while a stopped save is waiting to be dealt with: the
/// file holds a version the words on screen were never written over.
const undoFrozen = UndoRefused(
  'The last save was stopped, so there is nothing to take back yet. Save a '
  'copy or reload first.',
);
