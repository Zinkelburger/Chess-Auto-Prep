import 'dart:convert';

/// A PGN-compatible leading comment commits completion markers with puzzles.
/// Legacy analyzed_games.txt is read only until this marker is first written.
const _prefix = '; ChessAutoPrep-Analyzed-v1: ';

({String pgn, Set<String>? analyzed}) readTacticsDocument(String text) {
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

String writeTacticsDocument(String pgn, Set<String> analyzed) {
  final ids = analyzed.toList()..sort();
  return '$_prefix${base64Url.encode(utf8.encode(jsonEncode(ids)))}\n$pgn';
}
