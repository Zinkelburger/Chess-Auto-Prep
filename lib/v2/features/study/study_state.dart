import '../../storage/chapter_files.dart';

/// What the studies panel is showing.
sealed class StudiesState {
  const StudiesState();
}

/// The folder is being read for the first time.
final class StudiesLoading extends StudiesState {
  const StudiesLoading();
}

final class StudiesLoaded extends StudiesState {
  const StudiesLoaded(this.studies);

  /// In name order. Empty means the folder holds no studies, which is
  /// different from not having been able to read it.
  final List<ChapterRef> studies;
}

/// The folder is there but could not be read. The panel says so and offers
/// to try again; it never shows an empty list instead.
final class StudiesLoadFailed extends StudiesState {
  const StudiesLoadFailed(this.detail);

  /// The operating system's message, for the log; the panel writes the
  /// sentence.
  final String detail;
}

/// What became of a change to the studies folder.
sealed class StudyResult {
  const StudyResult();
}

/// It happened. [opened] is the study the change produced, when it produced
/// one, so the panel can open it at once.
final class StudyDone extends StudyResult {
  const StudyDone({this.opened});

  final ChapterRef? opened;
}

/// It did not happen. [sentence] is plain English for the screen; the owner
/// has already put the same thing in the log with the action it belongs to.
final class StudyProblem extends StudyResult {
  const StudyProblem(this.sentence);

  final String sentence;
}
