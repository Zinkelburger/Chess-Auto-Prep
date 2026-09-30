import 'dart:convert';

import 'game_ids.dart' show GameSite;

/// The games a tactics set's puzzles were mined from, kept in the set file
/// itself so the puzzles and the record of which games are done are always
/// written together.
///
/// The old app's format, which both apps read: the first line of the file
/// is a `;` comment, `; ChessAutoPrep-Analyzed-v1: ` and then the game ids
/// as a sorted JSON list, UTF-8, base64url. A file written before the line
/// existed has none; the old app then also keeps ids in a separate
/// `analyzed_games.txt`, which it goes on reading beside the line.
const analyzedGamesPrefix = '; ChessAutoPrep-Analyzed-v1: ';

/// The ids the line at the top of [preamble] names, or an empty set when
/// there is no line. Throws [FormatException] when the line is there and
/// cannot be read, as the old app does: a set whose record of analysed
/// games is unknown must not be mined into, or every game would be mined
/// again.
Set<String> analyzedIn(String preamble) {
  if (!preamble.startsWith(analyzedGamesPrefix)) return {};
  final end = preamble.indexOf('\n');
  if (end < 0) throw const FormatException('the analysed-games line is cut');
  final encoded = preamble.substring(analyzedGamesPrefix.length, end).trim();
  final Object? ids;
  try {
    ids = jsonDecode(utf8.decode(base64Url.decode(encoded)));
  } on Object {
    throw const FormatException('the analysed-games line is not readable');
  }
  if (ids is! List || ids.any((id) => id is! String)) {
    throw const FormatException('the analysed-games line is not a list');
  }
  return ids.cast<String>().toSet();
}

/// Whether [done] names the game [id]. Old app builds filed a Lichess game
/// under the bare id of its `GameId` header, without `lichess_`; both apps
/// still count those as done, and the ids stay as they were written.
bool isAnalyzed(Set<String> done, String id) {
  if (id.isEmpty) return false;
  if (done.contains(id)) return true;
  final lichess = '${GameSite.lichess.name}_';
  return id.startsWith(lichess) && done.contains(id.substring(lichess.length));
}

/// [preamble] with its analysed-games line naming [ids]: the line replaced
/// where it is, or put first when there was none, since the old app reads
/// it only at the very top of the file.
String withAnalyzed(String preamble, Set<String> ids) {
  final sorted = ids.toList()..sort();
  final line =
      '$analyzedGamesPrefix'
      '${base64Url.encode(utf8.encode(jsonEncode(sorted)))}\n';
  if (!preamble.startsWith(analyzedGamesPrefix)) return '$line$preamble';
  final end = preamble.indexOf('\n');
  return end < 0 ? line : '$line${preamble.substring(end + 1)}';
}
