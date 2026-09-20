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
  const LibraryLoaded(this.repertoires);

  final List<RepertoireFolder> repertoires;
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

/// Something of that name is already there. Nothing was written.
final class LibraryNameTaken extends LibraryResult {
  const LibraryNameTaken();
}

/// The file is not what the list said it was: it changed on disk, or it is
/// gone. Nothing was written, and the list is read again.
final class LibraryStale extends LibraryResult {
  const LibraryStale();
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
