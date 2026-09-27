/// Analysis lifecycle commands used by the document host. The application
/// supplies the engine owner; reader state never constructs engine services.
abstract interface class ViewerAnalysisPort {
  void cancel();
  void clearEvals();
  Future<bool> tryLoadFromPgn(String pgnText);
  Future<void> fillMissingBestLines(
    String pgnText, {
    required void Function(String movetext) onAnnotatedMovetext,
  });
}
