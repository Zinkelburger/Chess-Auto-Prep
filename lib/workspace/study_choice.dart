import '../storage/chapter_files.dart';

/// Where chapters going into a study land: one of the studies, or a new
/// one made for them.
sealed class StudyChoice {
  const StudyChoice();
}

final class IntoStudy extends StudyChoice {
  const IntoStudy(this.study);

  final ChapterRef study;
}

final class NewStudy extends StudyChoice {
  const NewStudy(this.name);

  final String name;
}
