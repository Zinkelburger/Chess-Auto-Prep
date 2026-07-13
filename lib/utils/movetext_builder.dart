/// Single numbered-movetext serializer shared by all PGN emitters.
///
/// Callers: `pgn_comment_utils.buildMovetext` (annotated full games),
/// `tactics_pgn_codec.buildSolutionMovetext` (puzzle solutions from a FEN),
/// `pgn_export.movesToPgnMoveText` (generated repertoire lines), and
/// `RepertoireController` (root-position move text).
library;

/// Serialize [sanMoves] into numbered PGN movetext.
///
/// [startMoveNumber] and [whiteToMoveFirst] describe the position *before*
/// the first ply — for a FEN start, pass `Setup.parseFen(fen).fullmoves` and
/// `turn == Side.white`. When the first ply is a Black move it is prefixed
/// with `N...` (e.g. `4... Qh4#`); subsequent Black moves carry no number.
///
/// [suffix] can append per-move text after the SAN (NAGs, `{comments}`,
/// probability tags). The returned string must include its own leading space
/// (e.g. `' {[%maiaProbability 0.5]}'`); empty/null means no suffix.
///
/// The result is trimmed and carries no game-result token — callers append
/// `1-0` / `*` themselves because their policies differ.
String buildNumberedMovetext(
  List<String> sanMoves, {
  int startMoveNumber = 1,
  bool whiteToMoveFirst = true,
  String? Function(int index)? suffix,
}) {
  final buf = StringBuffer();
  var moveNum = startMoveNumber;
  var isWhite = whiteToMoveFirst;
  for (var i = 0; i < sanMoves.length; i++) {
    if (isWhite) {
      buf.write('$moveNum. ');
    } else if (i == 0) {
      buf.write('$moveNum... ');
    }
    buf.write(sanMoves[i]);
    final extra = suffix?.call(i);
    if (extra != null && extra.isNotEmpty) buf.write(extra);
    buf.write(' ');
    if (!isWhite) moveNum++;
    isWhite = !isWhite;
  }
  return buf.toString().trim();
}
