/// Single numbered-movetext serializer shared by all PGN emitters.
///
/// Callers: `pgn_comment_utils.buildMovetext` (annotated full games),
/// `tactics_pgn_codec.buildSolutionMovetext` (puzzle solutions from a FEN),
/// `pgn_export.movesToPgnMoveText` (generated repertoire lines), and
/// `RepertoireController` (root-position move text).
library;

import 'chess_utils.dart' show isNullMoveSan;

/// Serialize [sanMoves] into numbered PGN movetext.
///
/// [startMoveNumber] and [whiteToMoveFirst] describe the position *before*
/// the first ply — for a FEN start, pass `Setup.parseFen(fen).fullmoves` and
/// `turn == Side.white`. When the first ply is a Black move it is prefixed
/// with `N...` (e.g. `4... Qh4#`); subsequent Black moves carry no number.
///
/// Null-move tokens (`--` / `Z0`) are omitted from the text but still pass
/// the turn, so `1. d4 Z0 2. Nf3` serializes as `1. d4 2. Nf3`.
///
/// [compact] drops the space after the move number — `1.e4 e5 2.Nf3` rather
/// than `1. e4 e5 2. Nf3`. Both spellings are legal PGN; the compact one is
/// what the app's short labels and search text use, and it is a parameter
/// here so there is still exactly one serializer rather than one per style.
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
  bool compact = false,
  String? Function(int index)? suffix,
}) {
  final gap = compact ? '' : ' ';
  final buf = StringBuffer();
  var moveNum = startMoveNumber;
  var isWhite = whiteToMoveFirst;
  var emitted = 0;
  for (var i = 0; i < sanMoves.length; i++) {
    if (isNullMoveSan(sanMoves[i])) {
      if (!isWhite) moveNum++;
      isWhite = !isWhite;
      continue;
    }
    if (isWhite) {
      buf.write('$moveNum.$gap');
    } else if (emitted == 0) {
      buf.write('$moveNum...$gap');
    }
    buf.write(sanMoves[i]);
    final extra = suffix?.call(i);
    if (extra != null && extra.isNotEmpty) buf.write(extra);
    buf.write(' ');
    emitted++;
    if (!isWhite) moveNum++;
    isWhite = !isWhite;
  }
  return buf.toString().trim();
}

/// The move number a **0-based** [ply] belongs to: plies 0 and 1 are move 1.
///
/// [startMoveNumber] is the number of the move the sequence begins on, for a
/// line that does not start at move 1.
int moveNumberAtPly(int ply, {int startMoveNumber = 1}) =>
    startMoveNumber + ply ~/ 2;

/// Just the number prefix of a move: `3.` for White, `3...` for Black.
///
/// The single home of the dot rule. Everything that numbers a move — the
/// serializer, the standalone labels, the widget rows that render the prefix
/// in its own `Text` — goes through here, so a `3.` and a `3...` can never
/// disagree about whose move it is.
String moveNumberLabel({required int moveNumber, required bool isWhite}) =>
    '$moveNumber${isWhite ? '.' : '...'}';

/// One move with its number: `3. Nf3` / `3... Nf6`.
///
/// Takes the move number and side directly, for callers that already hold
/// them authoritatively (a parsed FEN, an `isWhiteMove` flag) rather than
/// deriving them from a ply index. [compact] drops the space, matching
/// [buildNumberedMovetext]'s compact style: `3.Nf3` / `3...Nf6`.
String formatNumberedMove(
  String san, {
  required int moveNumber,
  required bool isWhite,
  bool compact = false,
}) =>
    '${moveNumberLabel(moveNumber: moveNumber, isWhite: isWhite)}'
    '${compact ? '' : ' '}$san';

/// One move with its number, from a **0-based** ply index: ply 0 is White's
/// first move.
///
/// Matches [plyFromFen]'s convention and the numbering [buildNumberedMovetext]
/// gives the same sequence.
///
/// Pass a 1-based ply as `ply - 1`. The two conventions are the standing
/// off-by-one hazard around move numbering, so the conversion is made at the
/// call site — where what the caller's index means is obvious — rather than
/// hidden behind a flag here.
String formatMoveAtPly(
  int ply,
  String san, {
  bool compact = false,
  int startMoveNumber = 1,
}) => formatNumberedMove(
  san,
  moveNumber: moveNumberAtPly(ply, startMoveNumber: startMoveNumber),
  isWhite: ply.isEven,
  compact: compact,
);
