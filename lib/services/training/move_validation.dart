/// Whether a played move matches the repertoire's expected move.
///
/// Extracted from `TrainingSessionController`, where it lived as the
/// `_MoveValidationMixin` part-mixin and could only be exercised through a
/// fully-built controller. It depends on nothing but its arguments, so it is a
/// plain function.
library;

import 'package:dartchess/dartchess.dart';

import '../../models/completed_move.dart';

/// True when [move], played from [position], is the move [expectedSan] denotes.
///
/// Compares *positions* rather than move text, so transpositions and notation
/// differences (`exd5` vs `e4xd5`, a trailing `+`/`!?`) still count as correct.
/// Falls back to normalised SAN comparison when either move cannot be played —
/// a corrupt position should not silently mark a right answer wrong.
bool isCorrectUserMove(
  Position position,
  CompletedMove move,
  String expectedSan,
) {
  final expectedMove = position.parseSan(expectedSan);
  if (expectedMove == null) return false;

  try {
    final expectedPos = position.play(expectedMove);
    final userMove = Move.parse(move.uci);
    if (userMove == null) return false;
    final userPos = position.play(userMove);
    if (userPos.fen == expectedPos.fen) return true;
  } catch (_) {
    // Unplayable move or invalid FEN — fall through to SAN comparison.
  }

  return _normalizeSan(move.san) == _normalizeSan(expectedSan);
}

/// Strip check/mate markers and annotation glyphs, and case-fold, so that
/// `E4+` and `e4!?` both compare equal to `e4`.
String _normalizeSan(String san) =>
    san.replaceAll(RegExp(r'[+#?!]'), '').trim().toLowerCase();
