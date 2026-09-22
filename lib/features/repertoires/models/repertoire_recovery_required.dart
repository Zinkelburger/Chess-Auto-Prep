/// A journal remains authoritative until recovery confirms the move's outcome.
/// Retrying the original rename is not equivalent to recovering this operation.
class RepertoireRecoveryRequired implements Exception {
  const RepertoireRecoveryRequired(this.operationId, this.cause);
  final String operationId;
  final Object cause;
  @override
  String toString() =>
      'The folder may have moved, but its references could not be confirmed. '
      'Reload the library to recover this operation before making another change.';
}
