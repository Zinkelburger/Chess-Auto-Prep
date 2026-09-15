/// The tactics set file: a multi-game puzzle PGN with the analyzed-game
/// checkpoint committed in a leading comment line, so puzzles and the games
/// they were mined from are always written together.
library;

import 'dart:convert';

/// A PGN-compatible leading comment commits completion markers with puzzles.
/// Legacy analyzed_games.txt is read only until this marker is first written.
const _prefix = '; ChessAutoPrep-Analyzed-v1: ';

/// A set file split into its puzzle PGN and the checkpoint of analyzed game
/// IDs; [analyzed] is null for a file written before checkpoints existed.
typedef TacticsDocument = ({String pgn, Set<String>? analyzed});

/// Split [text] into puzzle PGN and checkpoint. Throws [FormatException]
/// on a truncated or malformed checkpoint line.
TacticsDocument readTacticsDocument(String text) {
  if (!text.startsWith(_prefix)) return (pgn: text, analyzed: null);
  final newline = text.indexOf('\n');
  if (newline < 0) throw const FormatException('Incomplete tactics checkpoint');
  final value = jsonDecode(
    utf8.decode(base64Url.decode(text.substring(_prefix.length, newline))),
  );
  if (value is! List || value.any((id) => id is! String)) {
    throw const FormatException('Invalid tactics checkpoint');
  }
  return (
    pgn: text.substring(newline + 1),
    analyzed: value.cast<String>().toSet(),
  );
}

/// The set file text for [pgn] with [analyzed] checkpointed ahead of it.
String writeTacticsDocument(String pgn, Set<String> analyzed) {
  final ids = analyzed.toList()..sort();
  return '$_prefix${base64Url.encode(utf8.encode(jsonEncode(ids)))}\n$pgn';
}
