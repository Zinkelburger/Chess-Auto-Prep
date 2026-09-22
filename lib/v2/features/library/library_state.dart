/// What the library shows and what its commands answer.
///
/// These are values, so they live apart from the owner that produces them and
/// a widget can be written against them alone.
library;

import '../../storage/chapter_files.dart';
import '../../storage/training_records.dart' as records;

sealed class LibraryState {
  const LibraryState();
}

final class LibraryLoading extends LibraryState {
  const LibraryLoading();
}

final class LibraryLoaded extends LibraryState {
  const LibraryLoaded(this.repertoires, {this.unreadable = const []});

  final List<RepertoireFolder> repertoires;

  /// The folders the listing had to pass over. They are not in
  /// [repertoires], so without naming them a repertoire the operating system
  /// will not open would look like one the user never made.
  final List<UnreadableFolder> unreadable;
}

final class LibraryLoadFailed extends LibraryState {
  const LibraryLoadFailed(this.detail);

  /// The operating system's words, for the log; the widget writes the
  /// sentence.
  final String detail;
}

/// What became of a change to the catalog. Every command answers one of
/// these, and the panel turns it into a sentence.
sealed class LibraryResult {
  const LibraryResult();
}

/// The change was made.
final class LibraryDone extends LibraryResult {
  const LibraryDone({this.training = const records.NothingToRepoint()});

  /// Whether the training rows that named the old path followed it. A
  /// repertoire's chapters are folded into one answer: any problem wins over
  /// a count, because a user whose schedule was left behind needs telling.
  final records.RepointResult training;
}

/// A repertoire was made — created empty, or imported from a file or the
/// clipboard — and this is its first chapter, which is what the host opens.
final class LibraryAdded extends LibraryResult {
  const LibraryAdded(this.first, {required this.chapters, required this.lines});

  final ChapterRef first;

  final int chapters;

  /// Lines over every chapter, each variation counted as its own; zero for
  /// a repertoire created empty.
  final int lines;
}

/// The file or text had no game with a move in it. Nothing was written.
final class LibraryNothingToImport extends LibraryResult {
  const LibraryNothingToImport();
}

/// The file the user chose could not be read. Nothing was written.
final class LibraryFileUnreadable extends LibraryResult {
  const LibraryFileUnreadable(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// Something of that name is already there. Nothing was written.
final class LibraryNameTaken extends LibraryResult {
  const LibraryNameTaken();
}

/// The file is not what the list said it was: it changed on disk, or it is
/// gone. Nothing was written, and the list is read again, so asking again
/// works.
final class LibraryStale extends LibraryResult {
  const LibraryStale();
}

/// The chapter open in the workspace changed on disk under it. Nothing was
/// written, and nothing can be until the workspace reads the file again: the
/// revision every change is checked against is the one it holds, so asking
/// again would refuse the same way. The way out is to reload the chapter.
final class LibraryConflicted extends LibraryResult {
  const LibraryConflicted();
}

/// The change could not be carried out. The library is as it was.
final class LibraryFailure extends LibraryResult {
  const LibraryFailure(this.detail);

  /// For the log; the widget writes the sentence.
  final String detail;
}

/// Another change was still running, so this one was not started.
final class LibraryBusy extends LibraryResult {
  const LibraryBusy();
}

/// A change over a whole repertoire stopped part way. The chapters before
/// [chapter] were changed and the rest were not.
final class LibraryStoppedAt extends LibraryResult {
  const LibraryStoppedAt(this.chapter, this.cause);

  /// The chapter that refused, by name.
  final String chapter;

  final LibraryResult cause;
}

/// Every repoint folded into one answer: a problem if any chapter had one,
/// otherwise the rows that followed. A user whose schedule was left behind
/// needs telling, and a count they cannot act on does not outrank that.
records.RepointResult foldedRepoint(List<records.RepointResult> results) {
  var rows = 0;
  for (final result in results) {
    switch (result) {
      case records.Repointed(:final rowsChanged):
        rows += rowsChanged;
      case records.NothingToRepoint():
        continue;
      case records.Malformed() || records.IoFailure():
        return result;
    }
  }
  return rows == 0 ? const records.NothingToRepoint() : records.Repointed(rows);
}

/// Whether [state] already lists a chapter at [path].
///
/// A workspace that opened a chapter this list does not hold means the disk
/// changed under it — a copy written a moment ago — and the list has to be
/// read again before it can show or select it.
bool listsChapter(LibraryState state, String path) {
  if (state is! LibraryLoaded) return false;
  for (final folder in state.repertoires) {
    if (folder.chapters.any((chapter) => chapter.path == path)) return true;
  }
  return false;
}
