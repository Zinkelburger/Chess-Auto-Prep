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
/// the edit never touched. Nothing is taken away: the words are still on the
/// screen, where Save a copy can have them, the file is as it was, and
/// nothing more goes to disk until the user reloads or saves a copy.
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

/// The file is not one this app may write at all. Nothing was edited and
/// nothing will be: the document opened to read.
final class DocumentReadOnly extends SaveState {
  const DocumentReadOnly(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// What a state means for the words still to be written.
extension WordsIn on SaveState {
  /// Whether the saver is still writing this document at all. A stopped save
  /// freezes it: the words stay on the screen, where Save a copy can have
  /// them, and nothing else goes to disk under a scope that does not name
  /// their games. A conflicted file and one this app may not write are the
  /// same to whoever is about to tell the user that waiting will help.
  bool get takesWords =>
      this is! SaveConflict &&
      this is! SaveStopped &&
      this is! DocumentReadOnly;

  /// Whether a write may go out now: a failed file is written again with the
  /// next edit, and [takesWords] covers the rest.
  bool get writable => takesWords && this is! SaveFailed;
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

/// An undo asked for a version this store never kept. The file was not
/// touched, so the document is no less saved than it was.
const undoNotKept = UndoRefused(
  'Could not go back: that version is not among the ones kept for this file.',
);

/// Nothing goes back while a stopped save is waiting to be dealt with: the
/// file holds a version the words on screen were never written over.
const undoFrozen = UndoRefused(
  'The last save was stopped, so there is nothing to take back yet. Save a '
  'copy or reload first.',
);
