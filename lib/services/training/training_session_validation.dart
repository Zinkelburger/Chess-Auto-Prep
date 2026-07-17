part of 'training_session_controller.dart';

// ---------------------------------------------------------------------------
// MOVE VALIDATION
// ---------------------------------------------------------------------------

/// Move-correctness checking for [TrainingSessionController]. Shared fields are
/// provided by the host class.
mixin _MoveValidationMixin on ChangeNotifier {
  RepertoireController get session;

  bool isCorrectUserMove(CompletedMove move, String expectedSan) {
    final expectedMove = session.position.parseSan(expectedSan);
    if (expectedMove == null) return false;

    try {
      final expectedPos = session.position.play(expectedMove);
      final userMove = Move.parse(move.uci);
      if (userMove == null) return false;
      final userPos = session.position.play(userMove);
      if (userPos.fen == expectedPos.fen) return true;
    } catch (_) {
      // invalid FEN — fall through to SAN comparison
    }

    String normalizeSan(String san) =>
        san.replaceAll(RegExp(r'[+#?!]'), '').trim().toLowerCase();
    return normalizeSan(move.san) == normalizeSan(expectedSan);
  }
}
