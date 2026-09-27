/// Ids of the ask-once questions. Keep them here so the file stays readable
/// and two features can never collide on a key.
abstract final class AskedQuestion {
  /// "Looks like a course export — sort it into chapters?", per repertoire
  /// or study file.
  static const chapterLayout = 'chapterLayout';

  /// "Which side does this file train?", per repertoire file. `true` means
  /// White. Only ever recorded when the user sets it by hand — a file that
  /// declares `// Color:` or whose move tree answers the question needs no
  /// entry here, and the absence of one is what lets those keep winning.
  static const trainingColor = 'trainingColor';
}

abstract interface class TrainingAnswers {
  Future<bool?> boolAnswerFor(String questionId, {String subject = '*'});
  Future<void> record(
    String questionId, {
    String subject = '*',
    required bool answer,
    String? note,
    DateTime? askedUtc,
  });
  Future<void> forget(String questionId, {String? subject});
}
