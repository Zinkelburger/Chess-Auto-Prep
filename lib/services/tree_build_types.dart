/// Standalone exception types for the tree-build service.
library;

/// Thrown when a build is cancelled before it can produce a usable tree
/// (e.g. during PGN parsing).  Callers treat this as a normal cancellation,
/// not a failure.
class BuildCancelledException implements Exception {
  final String message;
  const BuildCancelledException(this.message);

  @override
  String toString() => message;
}
