import '../chess/pgn/comment_edits.dart' as edits;

/// Why an edit to the open document did not happen.
///
/// The session answers with one of these rather than doing nothing quietly:
/// an edit that silently fails reads as a lost one. The header turns each
/// into a sentence.

sealed class EditRefused {
  const EditRefused();
}

/// The document opened to read; [detail] says why the file cannot be
/// written.
final class NotEditable extends EditRefused {
  const NotEditable(this.detail);

  final String detail;
}

/// The game holding that move was not read whole, so writing it again would
/// delete the moves reading dropped.
final class LineNotWhole extends EditRefused {
  const LineNotWhole();
}

/// The words themselves cannot go into a PGN file; [reason] says which of
/// them.
final class WordsRefused extends EditRefused {
  const WordsRefused(this.reason);

  final String reason;
}

/// The chapter came back without the move that was played, so nothing was
/// written. Nothing should ever produce this.
final class MoveLost extends EditRefused {
  const MoveLost();
}

/// What the log should say about a refused comment edit; the screen says
/// its own version of the same thing through [refusalOf].
String refusalDetail(edits.CommentRefused refusal) => switch (refusal) {
  edits.GameNotWhole() => 'the game holding that move was not read whole',
  edits.CommentUnwritable(:final reason) => reason,
};

EditRefused refusalOf(edits.CommentRefused refusal) => switch (refusal) {
  edits.GameNotWhole() => const LineNotWhole(),
  edits.CommentUnwritable(:final reason) => WordsRefused(reason),
};
