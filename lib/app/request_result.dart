/// What came of a request to put something on the board.
sealed class RequestResult {
  const RequestResult();
}

/// It is on the board, or it was already.
final class RequestDone extends RequestResult {
  const RequestDone();
}

/// It could not be done, and [sentence] — also in [WorkspaceRequests.status]
/// — says why.
final class RequestRefused extends RequestResult {
  const RequestRefused(this.sentence);

  final String sentence;
}

/// Nothing happened and nothing needs saying: the user stayed or closed a
/// dialog, a later request overtook this one, or the list that asked says
/// why itself.
final class RequestDropped extends RequestResult {
  const RequestDropped();
}
