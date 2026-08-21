/// Build a PGN string for a tactic with its solution as the mainline.
library;

import '../../models/tactics_position.dart';
import '../../utils/pgn_utils.dart';
import 'tactics_pgn_codec.dart' show encodePuzzlePgn;

/// PGN from the tactic FEN with [solutionSan] as the mainline, carrying the
/// source-game headers so the analysis tab shows meaningful context.
///
/// Delegates to the shared puzzle-PGN codec; the note comment is omitted
/// here because the analysis tab shows the mistake analysis separately.
String buildSolutionPgn(TacticsPosition tactic, List<String> solutionSan) {
  return encodePuzzlePgn(tactic, solutionSan, includeNote: false).trim();
}

/// The full source game as a standalone PGN, reconstructed from the tactic's
/// stored [TacticsPosition.sourceMovetext] plus its game headers. Starts from
/// the standard position (mined movetext is only stored for standard starts),
/// so the analysis tab can load the whole game and jump to the tactic via its
/// FEN. Returns an empty string when no source game was captured (legacy or
/// custom puzzles) — callers then fall back to [buildSolutionPgn].
String buildSourceGamePgn(TacticsPosition tactic) {
  final movetext = tactic.sourceMovetext.trim();
  if (movetext.isEmpty) return '';

  final white = tactic.gameWhite.isNotEmpty ? tactic.gameWhite : '?';
  final black = tactic.gameBlack.isNotEmpty ? tactic.gameBlack : '?';
  final result = tactic.gameResult.isNotEmpty ? tactic.gameResult : '*';

  final buf = StringBuffer();
  buf.writeln('[Event "Source game"]');
  buf.writeln('[White "${escapeHeaderValue(white)}"]');
  buf.writeln('[Black "${escapeHeaderValue(black)}"]');
  if (tactic.gameDate.isNotEmpty) {
    buf.writeln('[Date "${escapeHeaderValue(tactic.gameDate)}"]');
  }
  if (tactic.gameUrl.isNotEmpty) {
    buf.writeln('[Site "${escapeHeaderValue(tactic.gameUrl)}"]');
  }
  buf.writeln('[Result "$result"]');
  buf.writeln();
  buf.writeln('$movetext $result');
  return buf.toString().trim();
}
