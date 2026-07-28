/// Failure of a study download that the UI should show verbatim.
///
/// Every [message] is written for a SnackBar: plain language, and where the
/// user can do something about it (log in, slow down, paste the ids by hand),
/// it says so.
library;

class StudyImportException implements Exception {
  const StudyImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
