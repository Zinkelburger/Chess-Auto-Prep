enum StudySourceFailure {
  offline,
  loginRequired,
  scopeRequired,
  rejected,
  userMissing,
  http,
  empty,
}

/// Transport failure data; presentation chooses localized guidance.
class StudyImportException implements Exception {
  const StudyImportException(this.failure, {this.username, this.statusCode});
  final StudySourceFailure failure;
  final String? username;
  final int? statusCode;
}
