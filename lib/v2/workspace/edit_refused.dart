/// Why an edit to the open document did not happen.
///
/// The session answers with one of these rather than doing nothing quietly:
/// an edit that silently fails reads as a lost one. The header turns each
/// into a sentence.
library;

import '../chess/pgn/comment_edits.dart';

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

/// The change could not be made to the file without losing something it
/// holds; [reason] says what stood in the way. The document is as it was.
final class EditNotWritten extends EditRefused {
  const EditNotWritten(this.reason);

  final String reason;
}

/// The chapter came back without the move that was played, so nothing was
/// written. Nothing should ever produce this.
final class MoveLost extends EditRefused {
  const MoveLost();
}

/// What a refused note is, for the screen.
EditRefused refusalOf(CommentRefused refusal) => switch (refusal) {
  GameNotWhole() => const LineNotWhole(),
  CommentUnwritable(:final reason) => WordsRefused(reason),
};

/// What the log should say about one; the screen says its own version of the
/// same thing.
String refusalDetail(CommentRefused refusal) => switch (refusal) {
  GameNotWhole() => 'the game holding that move was not read whole',
  CommentUnwritable(:final reason) => reason,
};
