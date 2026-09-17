/// Which slice of a line one training session drills.
///
/// Pure functions of the line and the settings, pulled out of
/// `TrainingSessionController.startLine` so the marker and depth rules can be
/// tested without a board or a notifier.
library;

import '../../../models/repertoire_line.dart';
import 'training_settings.dart';
import '../../../utils/pgn_comment_utils.dart' show filterDisplayComment;

/// How much of a line is trained and where the quiz starts.
///
/// [length] is the number of plies that count as the line; [startIndex] is
/// the first quizzed ply. Plies before [startIndex] are an intro that
/// auto-plays on the board.
typedef TrainingWindow = ({int length, int startIndex});

/// Resolve the window for [line].
///
/// The length is [TrainingSettings.trainingDepth] clamped to the line, then
/// cut at a `[%tend]` marker: anything past the marked move is post-mortem
/// context, not solution. A marker that would leave nothing to train (end
/// marked before the start) is ignored.
///
/// A `[%tstart]` marker pins where the quiz begins: moves before it are
/// prelude that auto-plays in every mode. Without a marker, tactics mode never
/// auto-plays intro moves — they *are* the solution — and repertoire mode
/// optionally skips to the first annotated move.
TrainingWindow resolveTrainingWindow(
  RepertoireLine line, {
  required TrainingSettings settings,
  required TrainingMode mode,
}) {
  final depth = settings.trainingDepth;
  var length = depth != null
      ? depth.clamp(1, line.moves.length)
      : line.moves.length;
  final markerEnd = line.puzzleEndIndex;
  if (markerEnd != null && markerEnd >= (line.puzzleStartIndex ?? 0)) {
    length = (markerEnd + 1).clamp(1, length);
  }

  final markerStart = line.puzzleStartIndex;
  final int startIndex;
  if (markerStart != null && markerStart < length) {
    startIndex = markerStart;
  } else if (mode == TrainingMode.repertoire && settings.skipToFirstComment) {
    startIndex = firstCommentIndex(line, length);
  } else {
    startIndex = 0;
  }
  return (length: length, startIndex: startIndex);
}

/// First move index below [length] whose comment has displayable prose, or 0
/// when no move qualifies so the whole line is trained.
int firstCommentIndex(RepertoireLine line, int length) {
  for (var i = 0; i < length; i++) {
    final comment = line.comments[i.toString()];
    if (comment != null && filterDisplayComment(comment).isNotEmpty) {
      return i;
    }
  }
  return 0;
}
