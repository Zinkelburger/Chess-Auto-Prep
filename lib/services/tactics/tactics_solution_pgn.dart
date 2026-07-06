/// Build a PGN string for a tactic with its solution as the mainline.
library;

import '../../models/tactics_position.dart';
import '../tactics_pgn_codec.dart' show encodePuzzlePgn;

/// PGN from the tactic FEN with [solutionSan] as the mainline, carrying the
/// source-game headers so the analysis tab shows meaningful context.
///
/// Delegates to the shared puzzle-PGN codec; the note comment is omitted
/// here because the analysis tab shows the mistake analysis separately.
String buildSolutionPgn(TacticsPosition tactic, List<String> solutionSan) {
  return encodePuzzlePgn(tactic, solutionSan, includeNote: false).trim();
}
